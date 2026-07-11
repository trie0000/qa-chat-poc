# =============================================================================
# create-list.ps1  --  create the QA_PoC list (PnP.PowerShell)
# -----------------------------------------------------------------------------
# Usage (PnP.PowerShell required):
#   Install-Module PnP.PowerShell -Scope CurrentUser      # once
#   .\create-list.ps1 -SiteUrl "https://<tenant>.sharepoint.com/sites/<site>"
#
# If PnP is not available in your environment, create the list manually with the
# schema in setup/README-PA-flow.md / README.md (internal names must match).
# =============================================================================
param(
  [Parameter(Mandatory = $true)][string]$SiteUrl,
  [string]$ListTitle = "QA_PoC"
)
$ErrorActionPreference = "Stop"

Connect-PnPOnline -Url $SiteUrl -Interactive

if (-not (Get-PnPList -Identity $ListTitle -ErrorAction SilentlyContinue)) {
  New-PnPList -Title $ListTitle -Template GenericList -OnQuickLaunch | Out-Null
  Write-Host "created list: $ListTitle"
} else {
  Write-Host "list already exists: $ListTitle"
}

# Title already exists (built-in). Add the rest idempotently.
function Ensure-Field($internal, $type, $extra) {
  $f = Get-PnPField -List $ListTitle -Identity $internal -ErrorAction SilentlyContinue
  if ($f) { Write-Host "  field exists: $internal"; return }
  $xml = "<Field Type='$type' DisplayName='$internal' Name='$internal' StaticName='$internal' $extra />"
  Add-PnPFieldFromXml -List $ListTitle -FieldXml $xml | Out-Null
  Write-Host "  added field: $internal ($type)"
}

Ensure-Field "Question"    "Note"     "NumLines='6' RichText='FALSE'"
Ensure-Field "Answer"      "Note"     "NumLines='6' RichText='FALSE'"
Ensure-Field "SessionId"   "Text"     "Indexed='TRUE'"
Ensure-Field "Turn"        "Number"   ""
Ensure-Field "Status"      "Choice"   "><CHOICES><CHOICE>Pending</CHOICE><CHOICE>Detected</CHOICE><CHOICE>Answering</CHOICE><CHOICE>Answered</CHOICE><CHOICE>Error</CHOICE></CHOICES></Field"
Ensure-Field "DetectedAt"  "DateTime" "Format='DateTime'"
Ensure-Field "AnsweredAt"  "DateTime" "Format='DateTime'"
Ensure-Field "DisplayedAt" "DateTime" "Format='DateTime'"

Write-Host "done."
# NOTE: The Choice field XML above is a simplified inline form; if Add-PnPFieldFromXml
# rejects it, add "Status" via the UI (Choice: Pending/Detected/Answering/Answered/Error).
