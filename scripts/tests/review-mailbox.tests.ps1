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
        -NextPromptForDev "Please fix the lock timeout in scripts/test.ps1" | Out-Null

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
    pwsh -NoProfile -File $ReviewMailboxScript -Operation ReviewSubmit `
        -MailboxPath $TestMailboxPath `
        -Verdict "APPROVED" `
        -HighestSeverity "NONE" `
        -Summary "Lock timeout verified, all clear" | Out-Null

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
        -MailboxPath $maxRoundMailbox | Out-Null

    pwsh -NoProfile -File $ReviewMailboxScript -Operation DevSubmit `
        -MailboxPath $maxRoundMailbox `
        -Summary "Initial try" `
        -TestGateStatus "PASS" | Out-Null

    pwsh -NoProfile -File $ReviewMailboxScript -Operation ReviewSubmit `
        -MailboxPath $maxRoundMailbox `
        -Verdict "REJECTED" `
        -Summary "Still has bugs" | Out-Null

    $rawJson = [System.IO.File]::ReadAllText($maxRoundMailbox, [System.Text.Encoding]::UTF8)
    $data = ConvertFrom-Json $rawJson
    Assert-Equal $data.status "REJECTED_MAX_ROUNDS" "Status must be REJECTED_MAX_ROUNDS when max round reached"

    # 8. Test Reset
    pwsh -NoProfile -File $ReviewMailboxScript -Operation Reset -MailboxPath $maxRoundMailbox | Out-Null
    Assert-True (-not (Test-Path -LiteralPath $maxRoundMailbox)) "Mailbox file should be deleted on Reset"

    Write-Host "All review mailbox tests passed successfully." -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $TestRoot) {
        Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
