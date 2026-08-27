#requires -Version 7.0

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$ScriptsRoot = Split-Path -Parent $PSScriptRoot
$OrchestratorScript = Join-Path $ScriptsRoot "Invoke-DualAgentLoop.ps1"
$MailboxSchema = Join-Path (Split-Path -Parent $ScriptsRoot) "schemas\review-mailbox.schema.json"

$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("dual-agent-loop-tests-" + [guid]::NewGuid().ToString("N"))
[System.IO.Directory]::CreateDirectory($TestRoot) | Out-Null

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
    Write-Host "Running Autonomous Dual-Agent Loop Orchestrator Tests..." -ForegroundColor Cyan

    # 1. Test Single Round Immediate Approval
    $mb1 = Join-Path $TestRoot "mb1.json"
    $res1 = & $OrchestratorScript `
        -TaskPrompt "Implement fast token cache" `
        -Feature "FeatureFastCache" `
        -DevProvider "mock" `
        -ReviewProvider "mock" `
        -VerifyCommand "Write-Host 'Test OK'; exit 0" `
        -MaxRounds 3 `
        -MailboxPath $mb1 `
        -PassThru

    Assert-Equal $res1.status "APPROVED" "Single round should result in APPROVED"
    Assert-Equal $res1.round 1 "Should complete in round 1"
    Assert-Equal $res1.history.Count 1 "History should have 1 round"

    # 2. Test Multi-Round Feedback Loop (Round 1 REJECT -> Round 2 APPROVE)
    $mb2 = Join-Path $TestRoot "mb2.json"
    $reviewCallCount = 0

    $customReviewerHook = {
        param($OriginalTask, $GitDiff, $Round)
        if ($Round -eq 1) {
            return [ordered]@{
                verdict = "REJECTED"
                highestSeverity = "HIGH"
                summary = "Missing null check in token validator"
                issues = @(
                    [ordered]@{
                        file = "token.ps1"
                        lineRange = "10"
                        severity = "HIGH"
                        problem = "Null token causes crash"
                        fixSuggestion = "Add null assertion"
                    }
                )
                nextPromptForDev = "Please add null validation in token.ps1"
            }
        } else {
            return [ordered]@{
                verdict = "APPROVED"
                highestSeverity = "NONE"
                summary = "Null check is in place and verified."
                issues = @()
                nextPromptForDev = ""
            }
        }
    }

    $res2 = & $OrchestratorScript `
        -TaskPrompt "Implement token validation" `
        -Feature "FeatureTokenValidation" `
        -DevProvider "mock" `
        -ReviewProvider "custom" `
        -ReviewerCustomHook $customReviewerHook `
        -VerifyCommand "exit 0" `
        -MaxRounds 3 `
        -MailboxPath $mb2 `
        -PassThru

    Assert-Equal $res2.status "APPROVED" "Multi-round should eventually result in APPROVED"
    Assert-Equal $res2.round 2 "Should complete in round 2"
    Assert-Equal $res2.history.Count 2 "History should contain both round 1 and round 2"
    Assert-Equal $res2.history[0].reviewVerdict.verdict "REJECTED" "Round 1 verdict was REJECTED"
    Assert-Equal $res2.history[1].reviewVerdict.verdict "APPROVED" "Round 2 verdict was APPROVED"

    # 3. Test Max Rounds Reached (Halt & Escalate)
    $mb3 = Join-Path $TestRoot "mb3.json"
    $alwaysRejectHook = {
        param($OriginalTask, $GitDiff, $Round)
        return [ordered]@{
            verdict = "REJECTED"
            highestSeverity = "CRITICAL"
            summary = "Always buggy"
            issues = @()
            nextPromptForDev = "Fix it"
        }
    }

    $failedLoop = $false
    try {
        & $OrchestratorScript `
            -TaskPrompt "Complex Task" `
            -Feature "FeatureComplex" `
            -DevProvider "mock" `
            -ReviewProvider "custom" `
            -ReviewerCustomHook $alwaysRejectHook `
            -VerifyCommand "exit 0" `
            -MaxRounds 2 `
            -MailboxPath $mb3 | Out-Null
    } catch {
        $failedLoop = $true
    }

    $raw3 = [System.IO.File]::ReadAllText($mb3, [System.Text.Encoding]::UTF8)
    $data3 = ConvertFrom-Json $raw3
    Assert-Equal $data3.status "REJECTED_MAX_ROUNDS" "Should set status to REJECTED_MAX_ROUNDS upon reaching limit"

    Write-Host "All autonomous dual-agent loop tests passed successfully." -ForegroundColor Green
}
finally {
    if (Test-Path -LiteralPath $TestRoot) {
        Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
