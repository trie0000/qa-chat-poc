# =============================================================================
# build_index.ps1 -- offline: chunk knowledge/manual.md and pre-compute embeddings
# -----------------------------------------------------------------------------
# Splits the manual by '## ' sections (windowing long ones with overlap),
# embeds each chunk with Ollama, and writes knowledge/index.json which the
# broker loads for retrieval. Run this whenever the manual changes.
#   powershell -NoProfile -File build_index.ps1
# =============================================================================
$ErrorActionPreference = 'Stop'
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
$Manual = Join-Path $Here 'knowledge\manual.md'
$Out    = Join-Path $Here 'knowledge\index.json'
$MaxChars = 900
$Overlap  = 150

$cfg = if (Test-Path (Join-Path $Here 'config.json')) {
  [IO.File]::ReadAllText((Join-Path $Here 'config.json'), [Text.Encoding]::UTF8) | ConvertFrom-Json
} else { $null }
$Ollama     = if ($cfg -and $cfg.ollama_endpoint) { ($cfg.ollama_endpoint).TrimEnd('/') } else { 'http://localhost:11434' }
$EmbedModel = if ($cfg -and $cfg.embed_model) { $cfg.embed_model } else { 'nomic-embed-text' }

if (-not (Test-Path $Manual)) { Write-Host "manual not found: $Manual"; exit 1 }
# read as UTF-8 and normalize to LF so chunk text (and thus embeddings) is stable
$md = ([IO.File]::ReadAllText($Manual, [Text.Encoding]::UTF8)) -replace "`r`n", "`n"

# split on level-2 '## ' headings; keep the preamble as its own section
function Split-Sections($text) {
  $parts = [regex]::Split($text, '(?m)^(##\s+.*)$')
  $out = New-Object System.Collections.ArrayList
  $pre = $parts[0].Trim()
  if ($pre) { [void]$out.Add(@('はじめに', $pre)) }
  for ($i = 1; $i -lt $parts.Count; $i += 2) {
    $head = (($parts[$i].Trim()) -replace '^#+', '').Trim()
    $body = if ($i + 1 -lt $parts.Count) { $parts[$i + 1] } else { '' }
    $chunkText = ($parts[$i] + "`n" + $body).Trim()
    [void]$out.Add(@($head, $chunkText))
  }
  return $out
}

function Split-Windows($text, $size, $overlap) {
  if ($text.Length -le $size) { return @($text) }
  $res = New-Object System.Collections.ArrayList
  $i = 0
  while ($i -lt $text.Length) {
    $len = [Math]::Min($size, $text.Length - $i)
    [void]$res.Add($text.Substring($i, $len))
    if ($i + $size -ge $text.Length) { break }
    $i += ($size - $overlap)
  }
  return $res
}

function Embed($text) {
  $body = @{ model = $EmbedModel; prompt = $text } | ConvertTo-Json -Compress
  $r = Invoke-RestMethod "$Ollama/api/embeddings" -Method Post -ContentType 'application/json; charset=utf-8' `
       -Body ([Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 120
  return $r.embedding
}

$chunks = New-Object System.Collections.ArrayList
foreach ($sec in (Split-Sections $md)) {
  foreach ($w in (Split-Windows $sec[1] $MaxChars $Overlap)) {
    [void]$chunks.Add([ordered]@{ id = $chunks.Count; section = $sec[0]; text = $w })
  }
}

Write-Host "embedding $($chunks.Count) chunks with '$EmbedModel' ..."
# nomic models need a document prefix; bge-m3 and others use the raw text
$docPrefix = if ($EmbedModel -like 'nomic*') { 'search_document: ' } else { '' }
foreach ($c in $chunks) { $c['embedding'] = Embed ($docPrefix + $c['text']) }
$dim = if ($chunks.Count) { @($chunks[0]['embedding']).Count } else { 0 }

$obj = [ordered]@{ model = $EmbedModel; dim = $dim; chunks = $chunks }
$json = $obj | ConvertTo-Json -Depth 8 -Compress
[IO.File]::WriteAllText($Out, $json, (New-Object Text.UTF8Encoding($false)))
Write-Host "wrote $Out : $($chunks.Count) chunks, dim=$dim"
Write-Host ("sections: " + ((@($chunks | ForEach-Object { $_['section'] }) | Sort-Object -Unique) -join ', '))
