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

# Install path: if lock is missing, auto-bootstrap it from .ai-sop submodule HEAD
$lockPath = Join-Path $WorkspaceRoot "tools\ai-sop\ai-sop.lock.json"
if (-not (Test-Path -LiteralPath $lockPath)) {
    $headCommit = ""
    if (Test-Path -LiteralPath (Join-Path $SopRoot ".git")) {
        try { $headCommit = [string](& git -C $SopRoot rev-parse HEAD 2>$null) } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($headCommit) -or $headCommit.Trim().Length -ne 40) {
        $result = New-AiSopInstallResult -Action "Install" -Mode $resolvedMode -SourceUrl $SourceUrl `
            -Commit "" -Result "LOCK_MISSING" -ErrorCode "AI_SOP_LOCK_MISSING"
        Write-AiSopInstallResult -Result $result -OutputFormat $OutputFormat
        exit 1
    }
    $headCommit = $headCommit.Trim()
    $resolvedSourceUrl = if (-not [string]::IsNullOrWhiteSpace($SourceUrl)) { $SourceUrl } else { "https://github.com/jitawangzi/agent-sop.git" }
    
    $manifestFile = Join-Path $SopRoot "distribution\project-manifest.json"
    $manifestSha = if (Test-Path -LiteralPath $manifestFile) { Get-AiSopSha256 -Path $manifestFile } else { "" }
    $coreFile = Join-Path $SopRoot "distribution\install-ai-sop-core.ps1"
    $coreSha = if (Test-Path -LiteralPath $coreFile) { Get-AiSopSha256 -Path $coreFile } else { "" }
    $bootstrapFile = Join-Path $SopRoot "distribution\bootstrap\install-ai-sop.ps1"
    $bootstrapSha = if (Test-Path -LiteralPath $bootstrapFile) { Get-AiSopSha256 -Path $bootstrapFile } else { "" }
    $certFile = Join-Path $SopRoot "distribution\harness-certification.json"
    $certSha = if (Test-Path -LiteralPath $certFile) { Get-AiSopSha256 -Path $certFile } else { "" }

    $lockDir = Split-Path -Parent $lockPath
    if (-not (Test-Path -LiteralPath $lockDir)) {
        New-Item -ItemType Directory -Path $lockDir -Force | Out-Null
    }
    $initialLock = [ordered]@{
        schemaVersion = "1.0"
        sourceUrl = $resolvedSourceUrl
        commit = $headCommit
        manifest = [ordered]@{
            path = "distribution/project-manifest.json"
            blobSha256 = $manifestSha
        }
        core = [ordered]@{
            path = "distribution/install-ai-sop-core.ps1"
            blobSha256 = $coreSha
        }
        bootstrap = [ordered]@{
            path = "distribution/bootstrap/install-ai-sop.ps1"
            blobSha256 = $bootstrapSha
        }
        certification = [ordered]@{
            path = "distribution/harness-certification.json"
            blobSha256 = $certSha
        }
    }
    $initialLock | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $lockPath -Encoding utf8
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
