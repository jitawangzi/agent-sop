#requires -Version 7.0
# Root entry point (DC-014): the only installer invocation surface in the
# host project root. It locates the external SOP checkout and delegates to
# distribution/bootstrap/install-ai-sop.ps1 inside it. Fixed CLI:
#   Mode=Auto|Git|Svn, Action=Install|Verify, WorkspaceRoot, SourceUrl,
#   OutputFormat=Text|Json, GitTimeoutSeconds=300 (1..3600 seconds per command)
# JSON result fields: schemaVersion/action/mode/sourceUrl/commit/result/
#                     changedProjections/errorCode/errorMessage
#
# Usage:
#   pwsh -NoProfile -File ./tools/ai-sop/install-ai-sop.ps1 `
#     -Mode Auto -Action Verify -WorkspaceRoot . -OutputFormat Json

[CmdletBinding()]
param(
    [ValidateSet("Auto", "Git", "Svn")]
    [string]$Mode = "Auto",

    [ValidateSet("Install", "Verify")]
    [string]$Action = "Verify",

    [string]$WorkspaceRoot = ".",

    [string]$SourceUrl = "",

    [ValidateSet("Text", "Json")]
    [string]$OutputFormat = "Text",

    [ValidateRange(1,3600)]
    [int]$GitTimeoutSeconds = 300
)

$ErrorActionPreference = "Stop"
$WorkspaceRoot = [System.IO.Path]::GetFullPath($WorkspaceRoot)
$SopRoot = Join-Path $WorkspaceRoot ".ai-sop"
$ExternalBootstrap = Join-Path $SopRoot "distribution\bootstrap\install-ai-sop.ps1"

if (-not (Test-Path -LiteralPath $ExternalBootstrap)) {
    $r = [ordered]@{
        schemaVersion="1.0"; action=$Action; mode=$Mode; sourceUrl=$SourceUrl; commit=""
        result="BOOTSTRAP_MISSING"; changedProjections=@(); errorCode="AI_SOP_BOOTSTRAP_MISSING"
        errorMessage=$ExternalBootstrap
    }
    if ($OutputFormat -eq "Json") { $r | ConvertTo-Json -Compress } else { Write-Host "result=BOOTSTRAP_MISSING" }
    exit 1
}

& pwsh -NoProfile -File $ExternalBootstrap `
    -Mode $Mode -Action $Action -WorkspaceRoot $WorkspaceRoot `
    -SourceUrl $SourceUrl -OutputFormat $OutputFormat -GitTimeoutSeconds $GitTimeoutSeconds
exit $LASTEXITCODE
