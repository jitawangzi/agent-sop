#requires -Version 7.0

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$ScriptsRoot = Split-Path -Parent $PSScriptRoot
$ReviewMailboxScript = Join-Path $ScriptsRoot "review-mailbox.ps1"
$MailboxSchema = Join-Path (Split-Path -Parent $ScriptsRoot) "schemas\review-mailbox.schema.json"

$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("review-mailbox-tests-" + [guid]::NewGuid().ToString("N"))
$TestMailboxPath = Join-Path $TestRoot "specs\features\TestDualAgent\review-mailbox.json"

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw "ASSERTION FAILED: $Message"
    }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -cne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

try {
    Write-Host "Running Dual-Agent Review Mailbox Tests..." -ForegroundColor Cyan

    # 1. Test Init
    pwsh -NoProfile -File $ReviewMailboxScript -Operation Init `
        -Feature "TestDualAgent" `
        -DevAgent "ANTIGRAVITY" `
        -ReviewerAgent "COPILOT" `
        -MaxRounds 3 `
        -MailboxPath $TestMailboxPath | Out-Null

    Assert-True (Test-Path -LiteralPath $TestMailboxPath) "Mailbox file should exist after Init"
    $rawJson = [System.IO.File]::ReadAllText($TestMailboxPath, [System.Text.Encoding]::UTF8)
    Assert-True ($rawJson | Test-Json -SchemaFile $MailboxSchema) "Initialized mailbox must satisfy schema"
    $data = ConvertFrom-Json $rawJson
    Assert-Equal $data.status "INITIALIZED" "Initial status must be INITIALIZED"
    Assert-Equal $data.round 1 "Initial round must be 1"
    Assert-Equal $data.maxRounds 3 "MaxRounds must be 3"
    Assert-Equal $data.devAgent "ANTIGRAVITY" "DevAgent should match"
    Assert-Equal $data.reviewerAgent "COPILOT" "ReviewerAgent should match"

    # 2. Test DevSubmit (Round 1)
    pwsh -NoProfile -File $ReviewMailboxScript -Operation DevSubmit `
        -MailboxPath $TestMailboxPath `
        -Summary "Added new cache lock mechanism" `
        -ChangedFiles @("scripts/test.ps1", "config/app.json") `
        -TestGateStatus "PASS" `
        -TestOutput "10 tests passed" | Out-Null

    $rawJson = [System.IO.File]::ReadAllText($TestMailboxPath, [System.Text.Encoding]::UTF8)
    Assert-True ($rawJson | Test-Json -SchemaFile $MailboxSchema) "Mailbox after DevSubmit must satisfy schema"
    $data = ConvertFrom-Json $rawJson
    Assert-Equal $data.status "WAITING_REVIEW" "Status after DevSubmit must be WAITING_REVIEW"
    Assert-Equal $data.currentDevSubmission.summary "Added new cache lock mechanism" "Dev summary should match"
    Assert-Equal $data.currentDevSubmission.testGateStatus "PASS" "Test gate status should match"

    # 3. Test Invalid DevSubmit in WAITING_REVIEW state
    $null = pwsh -NoProfile -File $ReviewMailboxScript -Operation DevSubmit `
        -MailboxPath $TestMailboxPath `
        -Summary "Second submit attempt" 2>$null
    Assert-True ($LASTEXITCODE -ne 0) "DevSubmit during WAITING_REVIEW must fail"

    # 4. Test ReviewSubmit - REJECTED (Round 1 -> 2)
    $sub1Time = if ($data.currentDevSubmission.submittedAt -is [System.DateTime]) { $data.currentDevSubmission.submittedAt.ToString("o") } else { [string]$data.currentDevSubmission.submittedAt }
    $issuesJson = @"
[
  {
    "file": "scripts/test.ps1",
    "lineRange": "10-20",
    "severity": "HIGH",
    "problem": "Lock timeout not configured",
    "fixSuggestion": "Add default 5s timeout"
  }
]
"@
    pwsh -NoProfile -File $ReviewMailboxScript -Operation ReviewSubmit `
        -MailboxPath $TestMailboxPath `
        -Verdict "REJECTED" `
        -HighestSeverity "HIGH" `
        -Summary "Found 1 high severity lock risk" `
        -IssuesJson $issuesJson `
        -NextPromptForDev "Please fix the lock timeout in scripts/test.ps1" `
        -ExpectedRound 1 `
        -ExpectedSubmittedAt $sub1Time `
        -ReviewerIdentity "COPILOT" | Out-Null

    $rawJson = [System.IO.File]::ReadAllText($TestMailboxPath, [System.Text.Encoding]::UTF8)
    Assert-True ($rawJson | Test-Json -SchemaFile $MailboxSchema) "Mailbox after ReviewSubmit (REJECT) must satisfy schema"
    $data = ConvertFrom-Json $rawJson
    Assert-Equal $data.status "WAITING_DEV" "Status after REJECTED should transition to WAITING_DEV"
    Assert-Equal $data.round 2 "Round should increment to 2"
    Assert-Equal $data.history.Count 1 "History should contain 1 archived round"
    Assert-Equal $data.history[0].reviewVerdict.verdict "REJECTED" "Archived verdict should be REJECTED"
    Assert-Equal $data.history[0].reviewVerdict.issues.Count 1 "Archived issues should be preserved"

    # 5. Test DevSubmit (Round 2)
    pwsh -NoProfile -File $ReviewMailboxScript -Operation DevSubmit `
        -MailboxPath $TestMailboxPath `
        -Summary "Fixed lock timeout issue as requested" `
        -ChangedFiles @("scripts/test.ps1") `
        -TestGateStatus "PASS" `
        -TestOutput "All tests green" | Out-Null

    $rawJson = [System.IO.File]::ReadAllText($TestMailboxPath, [System.Text.Encoding]::UTF8)
    $data = ConvertFrom-Json $rawJson
    Assert-Equal $data.status "WAITING_REVIEW" "Status after Round 2 DevSubmit must be WAITING_REVIEW"
    Assert-Equal $data.round 2 "Current round should be 2"

    # 6. Test ReviewSubmit - APPROVED (Round 2 Completion)
    $sub2Time = if ($data.currentDevSubmission.submittedAt -is [System.DateTime]) { $data.currentDevSubmission.submittedAt.ToString("o") } else { [string]$data.currentDevSubmission.submittedAt }
    pwsh -NoProfile -File $ReviewMailboxScript -Operation ReviewSubmit `
        -MailboxPath $TestMailboxPath `
        -Verdict "APPROVED" `
        -HighestSeverity "NONE" `
        -Summary "Lock timeout verified, all clear" `
        -ExpectedRound 2 `
        -ExpectedSubmittedAt $sub2Time `
        -ReviewerIdentity "COPILOT" | Out-Null

    $rawJson = [System.IO.File]::ReadAllText($TestMailboxPath, [System.Text.Encoding]::UTF8)
    Assert-True ($rawJson | Test-Json -SchemaFile $MailboxSchema) "Mailbox after APPROVED must satisfy schema"
    $data = ConvertFrom-Json $rawJson
    Assert-Equal $data.status "APPROVED" "Status must be APPROVED"
    Assert-Equal $data.history.Count 2 "History should contain 2 archived rounds"

    # 7. Test MaxRounds Reached -> REJECTED_MAX_ROUNDS
    $maxRoundMailbox = Join-Path $TestRoot "max-round-mailbox.json"
    pwsh -NoProfile -File $ReviewMailboxScript -Operation Init `
        -Feature "MaxRoundTest" `
        -MaxRounds 1 `
        -DevAgent "ANTIGRAVITY" `
        -ReviewerAgent "COPILOT" `
        -MailboxPath $maxRoundMailbox | Out-Null

    pwsh -NoProfile -File $ReviewMailboxScript -Operation DevSubmit `
        -MailboxPath $maxRoundMailbox `
        -Summary "Initial try" `
        -TestGateStatus "PASS" | Out-Null

    $maxRaw = [System.IO.File]::ReadAllText($maxRoundMailbox, [System.Text.Encoding]::UTF8)
    $maxData = ConvertFrom-Json $maxRaw
    $maxSubTime = if ($maxData.currentDevSubmission.submittedAt -is [System.DateTime]) { $maxData.currentDevSubmission.submittedAt.ToString("o") } else { [string]$maxData.currentDevSubmission.submittedAt }

    pwsh -NoProfile -File $ReviewMailboxScript -Operation ReviewSubmit `
        -MailboxPath $maxRoundMailbox `
        -Verdict "REJECTED" `
        -Summary "Still has bugs" `
        -ExpectedRound 1 `
        -ExpectedSubmittedAt $maxSubTime `
        -ReviewerIdentity "COPILOT" | Out-Null

    $rawJson = [System.IO.File]::ReadAllText($maxRoundMailbox, [System.Text.Encoding]::UTF8)
    $data = ConvertFrom-Json $rawJson
    Assert-Equal $data.status "REJECTED_MAX_ROUNDS" "Status must be REJECTED_MAX_ROUNDS when max round reached"

    # 8. Test Reset
    pwsh -NoProfile -File $ReviewMailboxScript -Operation Reset -MailboxPath $maxRoundMailbox | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $maxRoundMailbox)) "Mailbox file should be deleted on Reset"

    # 9. Negative Test: Path Traversal in FeatureName is rejected
    $traversalFailed = $false
    try {
        pwsh -NoProfile -File $ReviewMailboxScript -Operation Init -Feature "../../traversal" 2>$null
        if ($LASTEXITCODE -ne 0) { $traversalFailed = $true }
    } catch {
        $traversalFailed = $true
    }
    Assert-True $traversalFailed "Path traversal in Feature name must be rejected"

    # 10. Negative Test: Duty Separation (Developer reviewing own code is rejected)
    $dutyMb = Join-Path $TestRoot "duty-mailbox.json"
    pwsh -NoProfile -File $ReviewMailboxScript -Operation Init `
        -Feature "DutyTest" `
        -DevAgent "ANTIGRAVITY" `
        -ReviewerAgent "ANTIGRAVITY" `
        -MailboxPath $dutyMb 2>$null
    
    pwsh -NoProfile -File $ReviewMailboxScript -Operation DevSubmit `
        -MailboxPath $dutyMb `
        -Summary "Dev changes" `
        -TestGateStatus "PASS" 2>$null
    
    $dutyRaw = [System.IO.File]::ReadAllText($dutyMb, [System.Text.Encoding]::UTF8)
    $dutyData = ConvertFrom-Json $dutyRaw
    $dutySubTime = if ($dutyData.currentDevSubmission.submittedAt -is [System.DateTime]) { $dutyData.currentDevSubmission.submittedAt.ToString("o") } else { [string]$dutyData.currentDevSubmission.submittedAt }

    $dutyFailed = $false
    try {
        $resDuty = pwsh -NoProfile -File $ReviewMailboxScript -Operation ReviewSubmit `
            -MailboxPath $dutyMb `
            -Verdict "APPROVED" `
            -Summary "Self review" `
            -ExpectedRound 1 `
            -ExpectedSubmittedAt $dutySubTime `
            -ReviewerIdentity "ANTIGRAVITY" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0 -or $resDuty -match "SEPARATION_OF_DUTIES_VIOLATION") {
            $dutyFailed = $true
        }
    } catch {
        $dutyFailed = $true
    }
    Assert-True $dutyFailed "Developer reviewing their own submission must be rejected with SEPARATION_OF_DUTIES_VIOLATION"

    # 11. Test: DevSubmit on FAIL test gate stays in WAITING_DEV and allows resubmission without deadlock
    $selfHealMb = Join-Path $TestRoot "self-heal-mailbox.json"
    pwsh -NoProfile -File $ReviewMailboxScript -Operation Init `
        -Feature "SelfHealTest" `
        -DevAgent "ANTIGRAVITY" `
        -ReviewerAgent "COPILOT" `
        -MailboxPath $selfHealMb | Out-Null
    
    pwsh -NoProfile -File $ReviewMailboxScript -Operation DevSubmit `
        -MailboxPath $selfHealMb `
        -Summary "First try with broken code" `
        -TestGateStatus "FAIL" `
        -TestOutput "Assertion error in test 1" | Out-Null
    
    $healRaw1 = [System.IO.File]::ReadAllText($selfHealMb, [System.Text.Encoding]::UTF8)
    $healData1 = ConvertFrom-Json $healRaw1
    Assert-Equal $healData1.status "WAITING_DEV" "DevSubmit with FAIL gate must keep status in WAITING_DEV"

    # Resubmit fix on same round without deadlock
    pwsh -NoProfile -File $ReviewMailboxScript -Operation DevSubmit `
        -MailboxPath $selfHealMb `
        -Summary "Fixed assertion error" `
        -TestGateStatus "PASS" `
        -TestOutput "All tests green" | Out-Null
    
    $healRaw2 = [System.IO.File]::ReadAllText($selfHealMb, [System.Text.Encoding]::UTF8)
    $healData2 = ConvertFrom-Json $healRaw2
    Assert-Equal $healData2.status "WAITING_REVIEW" "DevSubmit with PASS gate transitions to WAITING_REVIEW"

    Write-Host "All review mailbox tests passed successfully." -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $TestRoot) {
        Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
