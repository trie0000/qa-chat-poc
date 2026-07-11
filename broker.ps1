# =============================================================================
# broker.ps1 -- QA chat broker (PowerShell only; no Python).
# Windows-standard: PowerShell 5.1 + Add-Type (built-in csc) + Edge. No install.
#   * launches Edge with a debug port, drives it over CDP (ClientWebSocket)
#   * auto-creates the QA_PoC list + columns, uploads chat-ui.js, injects the UI
#   * polls Detected items and answers them with local Ollama RAG (manual index)
# ASCII-only console output; all Japanese text is read from config.json (UTF-8).
# Corp-API search mode is Python-only for now (see corp.py); this port covers the
# local Ollama path.
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
$ProfileDir = Join-Path $Here '.edgeprofile'
$SessionId  = [guid]::NewGuid().ToString()
$ByList     = "/_api/web/lists/getbytitle('$ListTitle')"

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
function Launch-Edge {
  $exe = $Edge
  if (-not (Test-Path $exe)) { $exe = "C:\Program Files\Microsoft\Edge\Application\msedge.exe" }
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
function Retrieve($question) {
  if (-not $script:Index) { return @() }
  $q = Ollama-Embed $question
  $scored = foreach ($c in $script:Index.chunks) { [pscustomobject]@{ score = (Cosine $q $c.embedding); c = $c } }
  return @($scored | Sort-Object score -Descending | Select-Object -First $TopK | ForEach-Object { $_.c })
}

# ---- answer a Detected item ----
function Build-Messages($curTurn, $question) {
  $chunks = Retrieve $question
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
  $etag = $it.'odata.etag'; if (-not $etag) { $etag = '*' }
  $claim = Sp-Write "$ByList/items($id)" @{ Status = 'Answering' } @{ 'X-HTTP-Method' = 'MERGE'; 'If-Match' = $etag }
  if (-not $claim.ok) { if ($claim.status -ne 412) { Log "claim failed $id : $($claim.status)" }; return }
  $script:Picked[$id] = UtcNow
  Log "picked item $id (turn $($it.Turn))"
  try {
    $messages = Build-Messages $it.Turn ([string]$it.Question)
    $answer = Ollama-Chat $messages
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
Launch-Edge
$script:Cdp = Connect-Cdp
Log 'CDP connected'
Wait-Auth
Ensure-Setup
Inject-UI
Load-Index
if ($script:Index) { Log "local Ollama RAG: $($script:Index.chunks.Count) chunks (embed=$EmbedModel, chat=$ChatModel)" } else { Log 'no knowledge index (plain chat)' }
Log "monitoring list '$ListTitle' for Detected items"
while ($true) {
  try {
    $q = "$ByList/items?`$select=Id,Turn,Question,Status&`$filter=SessionId eq '$SessionId' and Status eq 'Detected'&`$orderby=Turn asc&`$top=50"
    foreach ($it in (SpReq $q 'GET' $null $null 'minimalmetadata').json.value) { Handle-Detected $it }
    Reap-Latency
  } catch { Log "monitor error: $($_.Exception.Message)" }
  Start-Sleep -Milliseconds $PollMs
}
