#requires -Version 7.0
# External SOP bootstrap entry (distribution/bootstrap/install-ai-sop.ps1).
# Fixed CLI per DC-014. Dispatches to the installer core library. This file
# performs no authorization and writes no secrets; it only parses parameters
# and routes to Verify (read-only) or Install (transactional).
#
# Usage:
#   pwsh -NoProfile -File ./.ai-sop/distribution/bootstrap/install-ai-sop.ps1 `
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
    [string]$OutputFormat = "Text"
)

$ErrorActionPreference = "Stop"
$WorkspaceRoot = [System.IO.Path]::GetFullPath($WorkspaceRoot)
$SopRoot = Join-Path $WorkspaceRoot ".ai-sop"
$CorePath = Join-Path $SopRoot "distribution\install-ai-sop-core.ps1"

if (-not (Test-Path -LiteralPath $CorePath)) {
    $r = [ordered]@{
        schemaVersion="1.0"; action=$Action; mode=$Mode; sourceUrl=$SourceUrl; commit=""
        result="CORE_MISSING"; changedProjections=@(); errorCode="AI_SOP_CORE_MISSING"
        errorMessage=$CorePath
    }
    if ($OutputFormat -eq "Json") { $r | ConvertTo-Json -Compress } else { Write-Host "result=CORE_MISSING" }
    exit 1
}

. $CorePath

$resolvedMode = Resolve-AiSopMode -Mode $Mode -WorkspaceRoot $WorkspaceRoot
Restore-AiSopInstallTransactions -WorkspaceRoot $WorkspaceRoot -ClaudeRoot $SopRoot

if ($Action -eq "Verify") {
    $result = Invoke-AiSopVerify -WorkspaceRoot $WorkspaceRoot -Mode $resolvedMode `
        -SourceUrl $SourceUrl -OutputFormat $OutputFormat
    Write-AiSopInstallResult -Result $result -OutputFormat $OutputFormat
    if ($result.result -eq "VERIFIED") { exit 0 } else { exit 1 }
}

# Install path requires a published lock commit; without it we cannot proceed.
$lockPath = Join-Path $WorkspaceRoot "tools\ai-sop\ai-sop.lock.json"
if (-not (Test-Path -LiteralPath $lockPath)) {
    $result = New-AiSopInstallResult -Action "Install" -Mode $resolvedMode -SourceUrl $SourceUrl `
        -Commit "" -Result "LOCK_MISSING" -ErrorCode "AI_SOP_LOCK_MISSING"
    Write-AiSopInstallResult -Result $result -OutputFormat $OutputFormat
    exit 1
}
$lock = Read-AiSopLock -WorkspaceRoot $WorkspaceRoot

# Git Install: regular submodule update/checkout, never swap .ai-sop (DC-016).
if ($resolvedMode -eq "Git") {
    $sopRoot = Join-Path $WorkspaceRoot ".ai-sop"
    if (Test-Path -LiteralPath (Join-Path $sopRoot ".git")) {
        & git -C $sopRoot fetch --quiet origin 2>&1 | Out-Null
        & git -C $sopRoot checkout $lock.commit 2>&1 | Out-Null
    }
} else {
    # SVN Install: independent clone + same-volume rename (DC-012).
    $txId = "svn-" + [guid]::NewGuid().ToString("N").Substring(0, 12)
    try {
        $journalPath = Invoke-AiSopSvnInstall -WorkspaceRoot $WorkspaceRoot `
            -Lock $lock -TransactionId $txId
    } catch {
        # On clone/checkout failure, attempt rollback before reporting.
        [void](Invoke-AiSopSvnRollback -WorkspaceRoot $WorkspaceRoot -TransactionId $txId)
        $result = New-AiSopInstallResult -Action "Install" -Mode $resolvedMode `
            -SourceUrl $lock.sourceUrl -Commit $lock.commit `
            -Result "INSTALL_FAILED" -ErrorCode "$_" -ErrorMessage "$($_.Exception.Message)"
        Write-AiSopInstallResult -Result $result -OutputFormat $OutputFormat
        exit 1
    }
}

# After checkout, generate projections (DC-019) then verify (DC-017).
$manifestPath = Join-Path $SopRoot $lock.manifest.path
if (Test-Path -LiteralPath $manifestPath) {
    $manifest = Get-Content -Raw -LiteralPath $manifestPath | ConvertFrom-Json
    try {
        $generated = Invoke-AiSopGenerateProjections -WorkspaceRoot $WorkspaceRoot `
            -Manifest $manifest -SopRoot $SopRoot
    } catch {
        $result = New-AiSopInstallResult -Action "Install" -Mode $resolvedMode `
            -SourceUrl $lock.sourceUrl -Commit $lock.commit `
            -Result "PROJECTION_GEN_FAILED" -ErrorCode "$($_.Exception.Message)"
        Write-AiSopInstallResult -Result $result -OutputFormat $OutputFormat
        exit 1
    }
}

# After install, verify projections + commit the transaction (DC-017).
$result = Invoke-AiSopVerify -WorkspaceRoot $WorkspaceRoot -Mode $resolvedMode `
    -SourceUrl $lock.sourceUrl -OutputFormat $OutputFormat
if ($result.result -eq "VERIFIED" -and $resolvedMode -eq "Svn") {
    $finalSha = (Get-AiSopSha256 -Path (Join-Path $WorkspaceRoot ".ai-sop"))
    Complete-AiSopSvnTransaction -JournalPath $journalPath -FinalStateSha256 $finalSha
}
if ($generated) { $result.changedProjections = @($generated) }
Write-AiSopInstallResult -Result $result -OutputFormat $OutputFormat
if ($result.result -eq "VERIFIED") { exit 0 } else { exit 1 }
