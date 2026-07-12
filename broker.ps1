# =============================================================================
# broker.ps1 -- QA chat broker (PowerShell only; no Python).
# Windows-standard: PowerShell 5.1 + Add-Type (built-in csc) + Edge. No install.
#   * launches Edge with a debug port, drives it over CDP (ClientWebSocket)
#   * auto-creates the QA_PoC list + columns, uploads chat-ui.js, injects the UI
#   * polls Detected items and answers them with local Ollama RAG (manual index)
#     OR the corporate API (Azure OpenAI compatible) when config.json "corp" is set
# ASCII-only console output; all Japanese text is read from config.json (UTF-8).
# =============================================================================
$ErrorActionPreference = 'Stop'
# 'sp' is a built-in alias for Set-ItemProperty and would shadow our SpReqfunction.
Remove-Item Alias:sp -Force -ErrorAction SilentlyContinue
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---- config (read as UTF-8 so Japanese survives regardless of this file's encoding) ----
$cfgPath = Join-Path $Here 'config.json'
if (-not (Test-Path $cfgPath)) { Write-Host 'config.json not found. Copy config.example.json to config.json.'; exit 2 }
$cfg = [IO.File]::ReadAllText($cfgPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
$Site       = $cfg.site_url.TrimEnd('/')
$ListTitle  = $cfg.list_title
$UiUrl      = $cfg.ui_code_url
$Port       = if ($cfg.cdp_port) { [int]$cfg.cdp_port } else { 9222 }
$Edge       = $cfg.browser_path
$Ollama     = ($cfg.ollama_endpoint).TrimEnd('/')
$ChatModel  = $cfg.ollama_model
$EmbedModel = $cfg.embed_model
$TopK       = if ($cfg.top_k) { [int]$cfg.top_k } else { 4 }
$PollMs     = if ($cfg.poll_interval_ms) { [int]$cfg.poll_interval_ms } else { 2500 }
$HistMax    = if ($cfg.history_max_turns) { [int]$cfg.history_max_turns } else { 10 }
# pickup mode: 'detected' = broker waits for Power Automate to flip Pending->Detected;
# 'pending' = broker claims Pending directly (no PA needed, faster). 'pending' also
# accepts Detected so a still-running PA cannot strand a question.
$Pickup       = if ($cfg.pickup) { ([string]$cfg.pickup).ToLower() } else { 'detected' }
$StatusFilter = if ($Pickup -eq 'pending') { "(Status eq 'Pending' or Status eq 'Detected')" } else { "Status eq 'Detected'" }
$ProfileDir = Join-Path $Here '.edgeprofile'
$SessionId  = [guid]::NewGuid().ToString()
$ByList     = "/_api/web/lists/getbytitle('$ListTitle')"
$Corp       = $cfg.corp                                             # corp-API search config (may be $null / empty)
$Reasoning  = @('gpt-5', 'gpt-5-mini', 'gpt-5-nano', 'o3', 'o4-mini')  # reasoning models -> preview api-version
$script:Mode = 'local'   # 'local' (Ollama) | 'corp' (corporate API)
$script:CS = $null       # resolved corp settings
$script:Records = @()    # unified searchable records (corp segments or local chunks)
$script:Glossary = @()   # query-expansion dictionary [{canonical, aliases[]}]
# hybrid RAG: final = (1-w)*max(0,cosine) + w*bigram-coverage (tadori ragKeywordWeight, default 0.4; 0 = pure vector)
$RagKwWeight = if ($null -ne $cfg.rag_keyword_weight) { [double]$cfg.rag_keyword_weight } else { 0.4 }

function Log($m) { Write-Host "[broker] $m" }
function UtcNow { (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ") }

# ---- CDP client over ClientWebSocket (Add-Type; compiled by the in-box csc) ----
Add-Type -ReferencedAssemblies 'System' -TypeDefinition @'
using System; using System.Net.WebSockets; using System.Text; using System.Threading;
public class Cdp {
  ClientWebSocket ws; int id = 0;
  public void Connect(string url) { ws = new ClientWebSocket();
    ws.ConnectAsync(new Uri(url), CancellationToken.None).GetAwaiter().GetResult(); }
  string Recv() { var sb = new StringBuilder(); var buf = new byte[65536];
    var cts = new CancellationTokenSource(600000);
    while (true) { var r = ws.ReceiveAsync(new ArraySegment<byte>(buf), cts.Token).GetAwaiter().GetResult();
      sb.Append(Encoding.UTF8.GetString(buf, 0, r.Count)); if (r.EndOfMessage) break; } return sb.ToString(); }
  public string Send(string method, string prms) { int my = ++id;
    string msg = "{\"id\":" + my + ",\"method\":\"" + method + "\",\"params\":" + (prms == null ? "{}" : prms) + "}";
    byte[] b = Encoding.UTF8.GetBytes(msg);
    ws.SendAsync(new ArraySegment<byte>(b), WebSocketMessageType.Text, true, CancellationToken.None).GetAwaiter().GetResult();
    string w1 = "\"id\":" + my + ",\"result\""; string w2 = "\"id\":" + my + ",\"error\"";
    for (int k = 0; k < 100000; k++) { string resp = Recv(); if (resp.IndexOf(w1) >= 0 || resp.IndexOf(w2) >= 0) return resp; }
    return ""; }
  public string Eval(string expr, bool awaitPromise) {
    string p = "{\"expression\":" + JsonStr(expr) + ",\"returnByValue\":true,\"awaitPromise\":" + (awaitPromise ? "true" : "false") + "}";
    return Send("Runtime.evaluate", p); }
  public static string JsonStr(string s) { var sb = new StringBuilder(); sb.Append('"');
    for (int i = 0; i < s.Length; i++) { char c = s[i];
      if (c == '"') sb.Append("\\\""); else if (c == '\\') sb.Append("\\\\"); else if (c == '\n') sb.Append("\\n");
      else if (c == '\r') sb.Append("\\r"); else if (c == '\t') sb.Append("\\t");
      else if (c < 0x20) sb.Append("\\u" + ((int)c).ToString("x4")); else sb.Append(c); }
    sb.Append('"'); return sb.ToString(); } }
'@

# float16 (LE uint16, base64) -> double[]. PS 5.1 = .NET Framework 4.8 has no
# System.Half, so decode the IEEE-754 half bits by hand (matches the tadori contract).
Add-Type -TypeDefinition @'
using System;
public static class CorpF16 {
  static float H2F(ushort h) {
    uint sign = (uint)(h & 0x8000) << 16; int exp = (h & 0x7c00) >> 10; uint mant = (uint)(h & 0x03ff); uint bits;
    if (exp == 0) {
      if (mant == 0) { bits = sign; }
      else { int e = -1; uint m = mant; while ((m & 0x400) == 0) { e++; m <<= 1; } m &= 0x03ff;
             bits = sign | ((uint)(e + 127 - 15 + 1) << 23) | (m << 13); }
    } else if (exp == 0x1f) { bits = sign | 0x7f800000u | (mant << 13); }
    else { bits = sign | ((uint)(exp - 15 + 127) << 23) | (mant << 13); }
    return BitConverter.ToSingle(BitConverter.GetBytes(bits), 0);
  }
  public static double[] Decode(string b64) {
    byte[] raw = Convert.FromBase64String(b64); int n = raw.Length / 2; double[] o = new double[n];
    for (int i = 0; i < n; i++) { ushort h = (ushort)(raw[i*2] | (raw[i*2+1] << 8)); o[i] = (double)H2F(h); }
    return o;
  }
}
'@

# Char 2-gram keyword index (tadori parity: db.store bigrams/keywordCoverage). Japanese
# has no word breaks, so hybrid ranking uses char-bigram coverage alongside cosine.
Add-Type -ReferencedAssemblies 'System.Core' -TypeDefinition @'
using System; using System.Collections.Generic; using System.Text.RegularExpressions;
public static class Rag {
  public static HashSet<string> Bigrams(string text) {
    string t = Regex.Replace((text ?? "").ToLowerInvariant(), @"\s+", " ").Trim();
    var set = new HashSet<string>();
    for (int i = 0; i < t.Length - 1; i++) set.Add(t.Substring(i, 2));
    return set;
  }
  public static double Coverage(HashSet<string> q, HashSet<string> d) {   // |q b d| / |q|
    if (q.Count == 0) return 0.0;
    int hit = 0; foreach (var g in q) if (d.Contains(g)) hit++;
    return (double)hit / q.Count;
  }
}
'@

$script:Cdp = $null

function Eval-Value($js, $awaitPromise) {
  $resp = $script:Cdp.Eval($js, $awaitPromise)
  if (-not $resp) { throw 'cdp eval returned empty' }
  $p = $resp | ConvertFrom-Json
  if ($p.result.exceptionDetails) { throw ("JS exception: " + $p.result.exceptionDetails.exception.description) }
  return $p.result.result.value
}

function Connect-Cdp {
  $deadline = (Get-Date).AddSeconds(120)
  $lastErr = 'endpoint not up (debug port never opened?)'
  while ((Get-Date) -lt $deadline) {
    try {
      $targets = Invoke-RestMethod "http://127.0.0.1:$Port/json" -TimeoutSec 2
      $pages = @($targets | Where-Object { $_.type -eq 'page' -and $_.webSocketDebuggerUrl })
      $pref  = @($pages | Where-Object { $_.url -match 'sharepoint\.com|microsoftonline|/_forms/|login' })
      $pick  = if ($pref.Count) { $pref[0] } elseif ($pages.Count) { $pages[0] } else { $null }
      if ($pick) { $c = New-Object Cdp; $c.Connect($pick.webSocketDebuggerUrl); return $c }
      $lastErr = "no page target yet"
    } catch { $lastErr = $_.Exception.Message }
    Start-Sleep -Milliseconds 500
  }
  throw ("CDP not reachable on port $Port. last: $lastErr`n" +
         "  Fix: (1) close ALL Edge windows and retry  (2) after failure open http://127.0.0.1:$Port/json/version " +
         "(no JSON = debug port blocked, likely corp Edge policy)  (3) check proxy env for loopback.")
}

# ---- SPO REST over CDP browser-fetch ----
function SpReq($rel, $method = 'GET', $body = $null, $digest = $null, $odata = 'nometadata', $extra = $null) {
  $headers = @{ Accept = "application/json;odata=$odata" }
  if ($null -ne $body) { $headers['Content-Type'] = "application/json;odata=$odata" }
  if ($extra) { foreach ($k in $extra.Keys) { $headers[$k] = $extra[$k] } }
  if ($digest -and $method -ne 'GET') { $headers['X-RequestDigest'] = $digest }
  $opts = @{ url = ($Site + $rel); method = $method; headers = $headers; body = $body }
  $o = $opts | ConvertTo-Json -Depth 40 -Compress
  $js = "(async()=>{const o=$o;const r=await fetch(encodeURI(o.url),{method:o.method,headers:o.headers," +
        "credentials:'include',body:(o.body!=null?JSON.stringify(o.body):undefined)});" +
        "const t=await r.text();let j=null;try{j=JSON.parse(t)}catch(e){}" +
        # SP list items return both Id and ID; PowerShell ConvertFrom-Json is case-insensitive -> drop ID
        "if(j){const s=(o)=>{if(o&&typeof o==='object'&&('ID' in o)&&('Id' in o))delete o.ID;};" +
        "if(j.value&&Array.isArray(j.value))j.value.forEach(s);else s(j);}" +
        "return{status:r.status,ok:r.ok,etag:r.headers.get('etag'),json:j,text:t.slice(0,500)};})()"
  return Eval-Value $js $true
}

$script:Digest = $null; $script:DigestExp = [datetime]::MinValue
function Get-Digest {
  if ($script:Digest -and (Get-Date) -lt $script:DigestExp) { return $script:Digest }
  $r = SpReq '/_api/contextinfo' 'POST'
  $script:Digest = $r.json.FormDigestValue
  $to = if ($r.json.FormDigestTimeoutSeconds) { [int]$r.json.FormDigestTimeoutSeconds } else { 1800 }
  $script:DigestExp = (Get-Date).AddSeconds($to - 300)
  return $script:Digest
}
function Sp-Write($rel, $body, $extra = $null, $odata = 'nometadata') {
  $d = Get-Digest
  $res = SpReq $rel 'POST' $body $d $odata $extra
  if ($res.status -eq 403) { $script:Digest = $null; $d = Get-Digest; $res = SpReq $rel 'POST' $body $d $odata $extra }
  return $res
}

# ---- browser + auth ----
function Kill-ProfileEdge {
  # Kill ONLY msedge processes bound to our dedicated --user-data-dir (.edgeprofile), so a
  # restart opens the debug port cleanly and mounts the UI with THIS run's SessionId. The
  # user's normal Edge (default profile) is a separate process tree and is left untouched.
  # (Window-close does not guarantee the background msedge exits; a lingering one holds the
  # SingletonLock -> new instance gets absorbed / debug port never opens / stale SID stays.)
  $stale = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine.Contains($ProfileDir) })
  if ($stale.Count) {
    Log "closing $($stale.Count) stale Edge process(es) on the dedicated profile"
    foreach ($p in $stale) { try { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } catch {} }
    Start-Sleep -Milliseconds 1200   # let the profile SingletonLock release before relaunch
  }
}
function Launch-Edge {
  $exe = $Edge
  if (-not (Test-Path $exe)) { $exe = "C:\Program Files\Microsoft\Edge\Application\msedge.exe" }
  Kill-ProfileEdge
  Log "launching Edge (CDP port $Port, dedicated profile)"
  Start-Process -FilePath $exe -ArgumentList @(
    "--remote-debugging-port=$Port", "--remote-allow-origins=*",
    "--user-data-dir=$ProfileDir", "--no-first-run", "--no-default-browser-check", $Site) | Out-Null
}
function Wait-Auth {
  Log "Waiting for sign-in. Sign in to SharePoint in the Edge window..."
  $probe = "(async()=>{try{const r=await fetch(encodeURI('$Site/_api/web?`$select=Title')," +
           "{headers:{Accept:'application/json;odata=nometadata'},credentials:'include'});return r.ok;}catch(e){return false;}})()"
  while ($true) {
    try { if ((Eval-Value $probe $true) -eq $true) { Log 'authenticated'; return } } catch {}
    Start-Sleep -Seconds 2
  }
}

# ---- first-run setup: create list + columns + upload chat-ui.js (idempotent) ----
$FieldsXml = @(
  @('Question',    "<Field Type='Note' DisplayName='Question' Name='Question' StaticName='Question' NumLines='6' RichText='FALSE'/>"),
  @('Answer',      "<Field Type='Note' DisplayName='Answer' Name='Answer' StaticName='Answer' NumLines='6' RichText='FALSE'/>"),
  @('SessionId',   "<Field Type='Text' DisplayName='SessionId' Name='SessionId' StaticName='SessionId'/>"),
  @('Turn',        "<Field Type='Number' DisplayName='Turn' Name='Turn' StaticName='Turn'/>"),
  @('Status',      "<Field Type='Choice' DisplayName='Status' Name='Status' StaticName='Status'><CHOICES><CHOICE>Pending</CHOICE><CHOICE>Detected</CHOICE><CHOICE>Answering</CHOICE><CHOICE>Answered</CHOICE><CHOICE>Error</CHOICE></CHOICES></Field>"),
  @('DetectedAt',  "<Field Type='DateTime' DisplayName='DetectedAt' Name='DetectedAt' StaticName='DetectedAt' Format='DateTime'/>"),
  @('AnsweredAt',  "<Field Type='DateTime' DisplayName='AnsweredAt' Name='AnsweredAt' StaticName='AnsweredAt' Format='DateTime'/>"),
  @('DisplayedAt', "<Field Type='DateTime' DisplayName='DisplayedAt' Name='DisplayedAt' StaticName='DisplayedAt' Format='DateTime'/>")
)
function Ensure-Setup {
  if (-not (SpReq "$ByList`?`$select=Title").ok) {
    $cr = Sp-Write '/_api/web/lists' @{ BaseTemplate = 100; Title = $ListTitle; Description = 'QA chat PoC'; ContentTypesEnabled = $false }
    Log "created list '$ListTitle' ($($cr.status))"
  }
  $existing = @{}
  foreach ($f in (SpReq "$ByList/fields?`$select=InternalName&`$top=500").json.value) { $existing[$f.InternalName] = $true }
  $added = 0
  foreach ($fx in $FieldsXml) {
    if ($existing[$fx[0]]) { continue }
    $body = @{ parameters = @{ '__metadata' = @{ type = 'SP.XmlSchemaFieldCreationInformation' }; SchemaXml = $fx[1]; Options = 12 } }
    $res = Sp-Write "$ByList/fields/createfieldasxml" $body $null 'verbose'
    if ($res.ok) { $added++ } else { Log "  column $($fx[0]) failed: $($res.status)" }
  }
  if ($added) { Log "added $added columns" }

  # upload chat-ui.js from local copy to the ui_code_url library path
  $path = [Uri]::UnescapeDataString(([Uri]$UiUrl).AbsolutePath)   # /sites/x/Shared Documents/qa-chat-poc/chat-ui.js
  $folder = $path.Substring(0, $path.LastIndexOf('/'))
  $filename = $path.Substring($path.LastIndexOf('/') + 1)
  Sp-Write ("/_api/web/folders/addUsingPath(DecodedUrl='" + $folder + "')") $null | Out-Null
  $src = [IO.File]::ReadAllText((Join-Path $Here 'sharepoint\chat-ui.js'), [Text.Encoding]::UTF8)
  $d = Get-Digest
  $up = "$Site/_api/web/GetFolderByServerRelativeUrl('$folder')/Files/add(url='$filename',overwrite=true)"
  $js = "(async()=>{const r=await fetch(encodeURI($($up | ConvertTo-Json)),{method:'POST'," +
        "headers:{'X-RequestDigest':$($d | ConvertTo-Json),'Accept':'application/json;odata=nometadata'}," +
        "credentials:'include',body:$($src | ConvertTo-Json)});return{status:r.status,ok:r.ok};})()"
  $r = Eval-Value $js $true
  Log ("chat-ui.js uploaded (" + $(if ($r.ok) { 'ok' } else { $r.status }) + ")")
}

function Inject-UI {
  $webRel = ([Uri]$Site).AbsolutePath
  Eval-Value ("window._spPageContextInfo=Object.assign({},window._spPageContextInfo,{webServerRelativeUrl:'$webRel'});true") $false | Out-Null
  $src = Eval-Value ("(async()=>{const r=await fetch(encodeURI($($UiUrl | ConvertTo-Json))+'?_='+Date.now()," +
                     "{cache:'no-cache',credentials:'include'});if(!r.ok)throw new Error('ui '+r.status);return await r.text();})()") $true
  Log "UI code fetched: $($src.Length) chars"
  $qa = @{ listTitle = $ListTitle; sessionId = $SessionId; pollIntervalMs = $PollMs; webUrl = $Site } | ConvertTo-Json -Compress
  Eval-Value ("window.__QA_CONFIG__=$qa;true") $false | Out-Null
  Eval-Value $src $false | Out-Null
  # Re-inject on every new document: SP redirects/SPA navigations after auth would
  # otherwise wipe the one-shot injected panel (this is why it "injects" but nothing shows).
  $boot = "window._spPageContextInfo=Object.assign({},window._spPageContextInfo,{webServerRelativeUrl:'$webRel'});" +
          "window.__QA_CONFIG__=$qa;" +
          "(async()=>{try{const r=await fetch(encodeURI($($UiUrl | ConvertTo-Json))+'?_='+Date.now()," +
          "{cache:'no-cache',credentials:'include'});const t=await r.text();(0,eval)(t);}catch(e){console.warn('QA reinject',e);}})();"
  try {
    $script:Cdp.Send('Page.enable', '{}') | Out-Null
    $script:Cdp.Send('Page.addScriptToEvaluateOnNewDocument', (@{ source = $boot } | ConvertTo-Json -Compress)) | Out-Null
  } catch { Log "(reload persistence not set: $($_.Exception.Message))" }
  Log 'UI injected'
}

# ---- Ollama (loopback; WinHTTP bypasses proxy for localhost) ----
function Ollama-Post($rel, $obj) {
  $json = $obj | ConvertTo-Json -Depth 20 -Compress
  return Invoke-RestMethod "$Ollama$rel" -Method Post -ContentType 'application/json; charset=utf-8' `
         -Body ([Text.Encoding]::UTF8.GetBytes($json)) -TimeoutSec 600
}
function Ollama-Embed($text) {
  $prompt = if ($EmbedModel -like 'nomic*') { "search_query: $text" } else { $text }
  return (Ollama-Post '/api/embeddings' @{ model = $EmbedModel; prompt = $prompt }).embedding
}
function Ollama-Chat($messages) {
  return (Ollama-Post '/api/chat' @{ model = $ChatModel; messages = $messages; stream = $false }).message.content
}

# ---- local RAG (manual index) ----
$script:Index = $null
function Load-Index {
  $p = Join-Path $Here $cfg.knowledge_index
  if (Test-Path $p) { $script:Index = [IO.File]::ReadAllText($p, [Text.Encoding]::UTF8) | ConvertFrom-Json }
}
function Cosine($a, $b) {
  $dot = 0.0; $na = 0.0; $nb = 0.0; $n = $a.Count
  for ($i = 0; $i -lt $n; $i++) { $x = $a[$i]; $y = $b[$i]; $dot += $x * $y; $na += $x * $x; $nb += $y * $y }
  if ($na -eq 0 -or $nb -eq 0) { return 0.0 }
  return $dot / ([Math]::Sqrt($na) * [Math]::Sqrt($nb))
}
# retrieval is unified in the hybrid RAG section (Rag-Retrieve), used by both modes.

# ---- corp-API search (Azure OpenAI compatible; tadori segments in SPO) --------
# Config lives in config.json "corp"; the browser UI holds none of it. Azure
# deployment name = deploy_prefix + model (dots removed). base_url may be the corp
# gateway directly or a loopback relay -- .NET DefaultWebProxy bypasses loopback
# and routes remote hosts through the system proxy, so Invoke-RestMethod "just works".
function Corp-Enabled { return [bool]($Corp -and $Corp.base_url -and $Corp.api_key -and $Corp.seg_url -and $Corp.embed_model) }
function Corp-Deploy($model) { if (-not $model) { return '' }; return ($Corp.deploy_prefix + ($model -replace '\.', '')) }
function Corp-Settings {
  $chat = [string]$Corp.chat_model
  [pscustomobject]@{
    base              = ($Corp.base_url).TrimEnd('/')
    seg_url           = ($Corp.seg_url).TrimEnd('/')
    api_key           = [string]$Corp.api_key
    chat_deploy       = (Corp-Deploy $chat)
    embed_deploy      = (Corp-Deploy ([string]$Corp.embed_model))
    dimensions        = if ($Corp.dimensions) { [int]$Corp.dimensions } else { $null }
    embed_api_version = if ($Corp.embed_api_version) { [string]$Corp.embed_api_version } else { '2024-02-01' }
    chat_api_version  = if ($Reasoning -contains $chat) { '2024-12-01-preview' } else { '2024-06-01' }
    # Optional explicit proxy for DIRECT-to-gateway calls. Leave empty when base_url
    # is tadori's loopback relay (127.0.0.1:PORT) -- the relay handles the on-prem
    # proxy (TADORI_AI_PROXY) itself, and loopback bypasses the system proxy anyway.
    proxy             = [string]$Corp.proxy_url
  }
}
function Corp-Http($url, $bodyObj) {
  $json = $bodyObj | ConvertTo-Json -Depth 20 -Compress
  $p = @{ Uri = $url; Method = 'Post'; Headers = @{ 'api-key' = $script:CS.api_key }
          ContentType = 'application/json; charset=utf-8'; Body = [Text.Encoding]::UTF8.GetBytes($json)
          TimeoutSec = 300; UseBasicParsing = $true }
  if ($script:CS.proxy) { $p.Proxy = $script:CS.proxy; $p.ProxyUseDefaultCredentials = $true }
  # PS 5.1 Invoke-RestMethod decodes bodies as ISO-8859-1 when the response
  # Content-Type omits charset, mangling UTF-8 (Japanese). Decode raw bytes as UTF-8.
  $resp = Invoke-WebRequest @p
  return [Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json
}
function Corp-Embed($text) {
  $s = $script:CS
  $url = "$($s.base)/openai/deployments/$($s.embed_deploy)/embeddings?api-version=$($s.embed_api_version)"
  $body = @{ input = @($text) }
  if ($s.dimensions) { $body.dimensions = $s.dimensions }
  return (Corp-Http $url $body).data[0].embedding
}
function Corp-Chat($messages) {
  $s = $script:CS
  $url = "$($s.base)/openai/deployments/$($s.chat_deploy)/chat/completions?api-version=$($s.chat_api_version)"
  return (Corp-Http $url @{ messages = $messages }).choices[0].message.content
}
# Read a JSON file from SPO like tadori's SharePointClient.readFileText:
#   {web}/_api/web/GetFileByServerRelativeUrl('<encodeURIComponent(path)>')/$value
# (a plain GET of the file's web URL returns the online viewer/redirect, not the bytes).
function Corp-ReadJson($web, $serverRelPath) {
  $webJs = $web | ConvertTo-Json
  $pathJs = $serverRelPath | ConvertTo-Json
  $js = @'
(async()=>{const web=__WEB__;const p=__PATH__;
const u=web+"/_api/web/GetFileByServerRelativeUrl('"+encodeURIComponent(p)+"')/$value";
const r=await fetch(u+(u.indexOf('?')>=0?'&':'?')+'_='+Date.now(),{credentials:'include',cache:'no-cache',headers:{Accept:'application/json;odata=nometadata'}});
if(!r.ok)throw new Error('HTTP '+r.status+' '+p);return await r.text();})()
'@
  $js = $js.Replace('__WEB__', $webJs).Replace('__PATH__', $pathJs)
  return (Eval-Value $js $true) | ConvertFrom-Json
}
# Resolve config.corp.seg_url into { web base, server-relative folder }. Accepts a
# plain folder URL, a SharePoint sharing/redirect link (https://host/:f:/r/sites/..),
# the AllItems.aspx?id=<server-rel> address-bar form, or a server-relative path.
# Segments may live in a different site than site_url (same tenant = same cookies),
# so the API web base is derived from seg_url itself.
function Corp-SegLocation {
  $u = [string]$script:CS.seg_url
  if ($u -notlike 'http*') {
    $folder = $u.TrimEnd('/')
    $origin = "$(([Uri]$Site).Scheme)://$(([Uri]$Site).Authority)"
  } else {
    $uri = [Uri]$u
    $origin = "$($uri.Scheme)://$($uri.Authority)"
    if ($uri.Query -match '[?&]id=([^&]+)') {
      $folder = ([Uri]::UnescapeDataString($matches[1])).TrimEnd('/')
    } else {
      # strip a sharing/redirect prefix like /:f:/r/ or /:w:/s/ down to /sites/...
      $folder = (([Uri]::UnescapeDataString($uri.AbsolutePath)) -replace '^/:[a-z]:/[a-z]+/', '/').TrimEnd('/')
    }
  }
  $sitePfx = if ($folder -match '^(/(?:sites|teams|personal)/[^/]+)') { $matches[1] } else { '' }
  return [pscustomobject]@{ web = "$origin$sitePfx"; folder = $folder }
}
function Corp-LoadSegments {
  $loc = Corp-SegLocation
  $web = $loc.web; $folder = $loc.folder
  Log "corp seg location: web=$web folder=$folder"
  $manifest = Corp-ReadJson $web "$folder/manifest.json"      # { version, generation, maxSeq, sealed[], open, updatedAt }
  if (-not $manifest -or -not (@($manifest.sealed).Count -or $manifest.open)) {
    throw "manifest invalid (no sealed/open): $folder/manifest.json"
  }
  $ids = @(); if ($manifest.sealed) { $ids += @($manifest.sealed) }
  if ($manifest.open -and $manifest.open.id) { $ids += [string]$manifest.open.id }  # open seg holds newest records
  Log "corp manifest: sealed=$(@($manifest.sealed).Count) open=$(if ($manifest.open) { $manifest.open.id } else { '-' })"
  # tadori segments are append-only with upsert/delete tombstones; resolve to
  # last-writer-wins per messageId(+chunkIdx) across segments (sealed in order, then open).
  $map = [ordered]@{}; $mid4key = @{}
  foreach ($id in $ids) {
    $seg = Corp-ReadJson $web "$folder/$id.json"              # { id, generation, records[] }
    foreach ($r in (@($seg.records) | Sort-Object { [int]$_.seq })) {
      $mid = [string]$r.messageId
      if ($r.op -eq 'delete') {                                # tombstone: drop all chunks of this message
        foreach ($k in @($map.Keys)) { if ($mid4key[$k] -eq $mid) { $map.Remove($k); $mid4key.Remove($k) } }
        continue
      }
      $key = "$mid#$($r.chunkIdx)"
      $map[$key] = $r; $mid4key[$key] = $mid
    }
  }
  $out = New-Object System.Collections.ArrayList
  foreach ($r in $map.Values) {
    if (-not $r.emb) { continue }                              # emb = base64 Float16 embedding field
    $emb = [CorpF16]::Decode([string]$r.emb)
    if (-not $emb -or $emb.Count -eq 0) { continue }
    $section = if ($r.subject) { $r.subject } elseif ($r.slideTitle) { $r.slideTitle } elseif ($r.label) { $r.label } elseif ($r.from) { $r.from } else { [string]$r.kind }
    [void]$out.Add([pscustomobject]@{ section = [string]$section; text = [string]$r.body; embedding = $emb; kind = [string]$r.kind; conv = [string]$r.conversationId })
  }
  return $out
}
# ---- hybrid RAG: vector cosine + char-bigram keyword coverage + glossary query
#      expansion + mustContain + onenote dedup (tadori src/search parity) -----------
# Attach a char-bigram index (kwbi) and a mustContain haystack (hay) to each record.
function Rag-Prep($records) {
  foreach ($r in $records) {
    $src = ("{0} {1}" -f [string]$r.section, [string]$r.text)
    Add-Member -InputObject $r -NotePropertyName kwbi -NotePropertyValue ([Rag]::Bigrams($src)) -Force
    Add-Member -InputObject $r -NotePropertyName hay  -NotePropertyValue ($src.ToLowerInvariant()) -Force
  }
  return $records
}
# Query expansion: fold glossary synonyms/abbreviations (max 8) into the query
# (tadori expandQueryTerms). glossary = [{canonical, aliases[]}].
function Load-Glossary {
  $g = @()
  if ($cfg.glossary) { $g = @($cfg.glossary) }
  elseif ($script:Mode -eq 'corp') {
    try { $loc = Corp-SegLocation; $g = @(Corp-ReadJson $loc.web "$($loc.folder)/glossary.json") } catch { $g = @() }
  } else {
    $gp = Join-Path $Here 'knowledge\glossary.json'
    if (Test-Path $gp) { try { $g = @([IO.File]::ReadAllText($gp, [Text.Encoding]::UTF8) | ConvertFrom-Json) } catch { $g = @() } }
  }
  $script:Glossary = @($g | Where-Object { $_ -and ($_.canonical -or $_.aliases) })
  if ($script:Glossary.Count) { Log "glossary: $($script:Glossary.Count) entries" }
}
function Expand-Query($query) {
  $q = ([string]$query).ToLowerInvariant().Trim()
  if (-not $q -or -not $script:Glossary.Count) { return @() }
  $added = New-Object System.Collections.Generic.List[string]
  foreach ($e in $script:Glossary) {
    $group = @(); if ($e.canonical) { $group += [string]$e.canonical }; if ($e.aliases) { $group += @($e.aliases | ForEach-Object { [string]$_ }) }
    $group = @($group | Where-Object { $_ -and $_.Length -ge 2 })
    $hit = $false; foreach ($f in $group) { if ($q.Contains($f.ToLowerInvariant())) { $hit = $true; break } }
    if (-not $hit) { continue }
    foreach ($f in $group) {
      if ($q.Contains($f.ToLowerInvariant()) -or $added.Contains($f)) { continue }
      $added.Add($f); if ($added.Count -ge 8) { return @($added) }
    }
  }
  return @($added)
}
# mustContain: terms the user quoted with japanese or ascii quotes must appear verbatim.
function Extract-Must($question) {
  $must = New-Object System.Collections.Generic.List[string]
  $o = [char]0x300C; $c = [char]0x300D   # Japanese corner brackets, built from code points to keep this file ASCII-only
  foreach ($pat in @("$o([^$c]{2,})$c", '"([^"]{2,})"')) {
    foreach ($m in [regex]::Matches([string]$question, $pat)) { [void]$must.Add($m.Groups[1].Value.ToLowerInvariant()) }
  }
  return @($must)
}
function Rag-Walk($sorted, $must, $applyMust) {
  $out = New-Object System.Collections.ArrayList; $seenConv = @{}
  foreach ($e in $sorted) {
    $r = $e.r
    if ($applyMust -and $must.Count) {
      $ok = $true; foreach ($k in $must) { if (-not $r.hay.Contains($k)) { $ok = $false; break } }
      if (-not $ok) { continue }
    }
    if ($r.kind -eq 'onenote' -and $r.conv) { if ($seenConv[$r.conv]) { continue }; $seenConv[$r.conv] = $true }
    [void]$out.Add($r); if ($out.Count -ge $TopK) { break }
  }
  return @($out)
}
function Rag-Retrieve($question) {
  if (-not $script:Records.Count) { return @() }
  $extra = Expand-Query $question
  $vecQ = ((([string]$question) + ' ' + ($extra -join ' ')).Trim())
  if ($extra.Count) { Log ("query expanded +[" + ($extra -join ', ') + "]") }
  $qvec = if ($script:Mode -eq 'corp') { Corp-Embed $vecQ } else { Ollama-Embed $vecQ }
  $qbi = [Rag]::Bigrams($vecQ)
  $w = [Math]::Min(1.0, [Math]::Max(0.0, $RagKwWeight))
  $useKw = ($w -gt 0 -and $qbi.Count -gt 0)
  $scored = New-Object System.Collections.ArrayList
  foreach ($r in $script:Records) {
    if ($r.embedding.Count -ne $qvec.Count) { continue }
    $vcos = [Math]::Max(0.0, (Cosine $qvec $r.embedding))
    $s = if ($useKw) { (1 - $w) * $vcos + $w * ([Rag]::Coverage($qbi, $r.kwbi)) } else { $vcos }
    [void]$scored.Add([pscustomobject]@{ r = $r; s = $s })
  }
  if (-not $scored.Count) {
    Log "WARNING: query dim=$($qvec.Count) != record dim=$(@($script:Records[0].embedding).Count) (align corp.dimensions / embed_model)"
    return @()
  }
  $sorted = @($scored | Sort-Object s -Descending)
  $must = Extract-Must $question
  $pick = @(Rag-Walk $sorted $must $true)                                          # @() : PS unwraps 1-elem returns
  if ($must.Count -and $pick.Count -eq 0) { $pick = @(Rag-Walk $sorted @() $false) }   # mustContain fallback
  return @($pick)
}

# ---- answer a Detected item ----
function Build-Messages($curTurn, $question) {
  $chunks = @(Rag-Retrieve $question)   # @() : PS unwraps a single-hit return to a scalar otherwise
  if ($chunks.Count) { Log ("retrieved: " + (($chunks | ForEach-Object { $_.section }) -join ', ')) }
  $system = $cfg.system_prompt
  if ($chunks.Count) {
    $ctx = ($chunks | ForEach-Object { "[$($_.section)]`n$($_.text)" }) -join "`n`n"
    $system = $system + $cfg.grounding_prompt + $ctx
  }
  $messages = @( @{ role = 'system'; content = $system } )
  $hq = "$ByList/items?`$select=Turn,Question,Answer&`$filter=SessionId eq '$SessionId' and Status eq 'Answered'&`$orderby=Turn asc&`$top=200"
  $rows = @((SpReq $hq).json.value | Where-Object { [int]$_.Turn -lt [int]$curTurn })
  if ($rows.Count -gt $HistMax) { $rows = $rows[($rows.Count - $HistMax)..($rows.Count - 1)] }
  foreach ($r in $rows) {
    $messages += @{ role = 'user'; content = [string]$r.Question }
    $messages += @{ role = 'assistant'; content = [string]$r.Answer }
  }
  $messages += @{ role = 'user'; content = $question }
  return $messages
}

$script:Picked = @{}
$script:Logged = @{}
function Handle-Detected($it) {
  $id = [int]$it.Id
  if ($script:Picked.ContainsKey($id)) { return }   # already handled this session (guards vs PA re-flipping an answered item)
  $etag = $it.'odata.etag'; if (-not $etag) { $etag = '*' }
  $claimBody = @{ Status = 'Answering' }
  if ($Pickup -eq 'pending') { $claimBody.DetectedAt = (UtcNow) }   # no PA to stamp DetectedAt in pending mode
  $claim = Sp-Write "$ByList/items($id)" $claimBody @{ 'X-HTTP-Method' = 'MERGE'; 'If-Match' = $etag }
  if (-not $claim.ok) { if ($claim.status -ne 412) { Log "claim failed $id : $($claim.status)" }; return }
  $script:Picked[$id] = UtcNow
  Log "picked item $id (turn $($it.Turn))"
  try {
    $messages = Build-Messages $it.Turn ([string]$it.Question)
    $answer = if ($script:Mode -eq 'corp') { Corp-Chat $messages } else { Ollama-Chat $messages }
    Sp-Write "$ByList/items($id)" @{ Answer = $answer; Status = 'Answered'; AnsweredAt = (UtcNow) } @{ 'X-HTTP-Method' = 'MERGE'; 'If-Match' = '*' } | Out-Null
    Log "answered item $id ($($answer.Length) chars)"
  } catch {
    $msg = $_.Exception.Message; if ($msg.Length -gt 1900) { $msg = $msg.Substring(0, 1900) }
    try { Sp-Write "$ByList/items($id)" @{ Answer = "[error] $msg"; Status = 'Error' } @{ 'X-HTTP-Method' = 'MERGE'; 'If-Match' = '*' } | Out-Null } catch {}
    Log "handle error on $id : $msg"
  }
}

$LatHeader = 'SessionId,Turn,CreatedAt,PA_DetectedAt,Broker_PickedAt,AnsweredAt,DisplayedAt'
function Reap-Latency {
  $q = "$ByList/items?`$select=Id,Turn,Created,DetectedAt,AnsweredAt,DisplayedAt&`$filter=SessionId eq '$SessionId' and Status eq 'Answered'&`$orderby=Turn asc&`$top=200"
  foreach ($it in (SpReq $q).json.value) {
    $id = [int]$it.Id
    if ($script:Logged[$id] -or -not $it.DisplayedAt) { continue }
    $dir = Join-Path $Here 'logs'; if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $file = Join-Path $dir 'latency.csv'
    if (-not (Test-Path $file)) { $LatHeader | Out-File $file -Encoding utf8 }
    $row = @($SessionId, $it.Turn, $it.Created, $it.DetectedAt, $script:Picked[$id], $it.AnsweredAt, $it.DisplayedAt) -join ','
    $row | Out-File $file -Encoding utf8 -Append
    $script:Logged[$id] = $true
  }
}

# ---- main ----
Log "session $SessionId"
Log "pickup mode: $Pickup$(if ($Pickup -eq 'pending') { ' (broker claims Pending directly; Power Automate NOT required)' } else { ' (waits for Power Automate to set Pending->Detected)' })"
Launch-Edge
$script:Cdp = Connect-Cdp
Log 'CDP connected'
Wait-Auth
Ensure-Setup
Inject-UI
# Retrieval backend: corp API (if config.json "corp" is filled in) else local Ollama index.
if (Corp-Enabled) {
  $script:CS = Corp-Settings
  try {
    $script:Mode = 'corp'
    $script:Records = @(Rag-Prep (Corp-LoadSegments))
    $segDim = if ($script:Records.Count) { @($script:Records[0].embedding).Count } else { 0 }
    Log "corp search ON: $($script:Records.Count) records dim=$segDim (base=$($script:CS.base) embed=$($script:CS.embed_deploy) chat=$($script:CS.chat_deploy))"
    if ($script:Records.Count -eq 0) { Log "WARNING: 0 records loaded - check seg_url points at the Tadori folder (<site>/Shared Documents/Tadori)" }
  } catch {
    $script:Mode = 'local'
    Log "corp segments load failed ($($_.Exception.Message)) -> falling back to local Ollama"
  }
}
if ($script:Mode -ne 'corp') {
  Load-Index
  if ($script:Index) {
    $script:Records = @(Rag-Prep (@($script:Index.chunks | ForEach-Object {
      [pscustomobject]@{ section = [string]$_.section; text = [string]$_.text; embedding = $_.embedding; kind = ''; conv = '' } })))
    Log "local Ollama RAG: $($script:Records.Count) chunks (embed=$EmbedModel, chat=$ChatModel)"
  } else { Log 'no knowledge index (plain chat)' }
}
Load-Glossary
Log "hybrid RAG: keyword_weight=$RagKwWeight (0=pure vector)"
Log "monitoring list '$ListTitle' every $($PollMs)ms (pickup=$Pickup, filter: $StatusFilter)"
while ($true) {
  try {
    $q = "$ByList/items?`$select=Id,Turn,Question,Status&`$filter=SessionId eq '$SessionId' and $StatusFilter&`$orderby=Turn asc&`$top=50"
    $items = @((SpReq $q 'GET' $null $null 'minimalmetadata').json.value)
    foreach ($it in $items) {
      if (-not $script:Picked.ContainsKey([int]$it.Id)) {
        Log "detected new item $($it.Id) (turn $($it.Turn), status=$($it.Status), qlen=$(([string]$it.Question).Length))"
      }
      Handle-Detected $it
    }
    Reap-Latency
  } catch { Log "monitor error: $($_.Exception.Message)" }
  Start-Sleep -Milliseconds $PollMs
}
