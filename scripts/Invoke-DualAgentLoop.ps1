#requires -Version 7.0

<#
.SYNOPSIS
    100% Fully Autonomous Dual-Agent Iterative Development & Review Orchestrator.
.DESCRIPTION
    Drives a complete, unattended feedback loop between a Developer Agent and an
    independent Reviewer Agent. Automatically runs verification test gates, captures
    git diffs, evaluates review verdicts, and feeds back issues for self-healing iteration.
.EXAMPLE
    pwsh -NoProfile -File ./scripts/Invoke-DualAgentLoop.ps1 `
        -TaskPrompt "Optimize workflow-transaction lock release logic" `
        -DevProvider "claude" `
        -ReviewProvider "copilot" `
        -VerifyCommand "pwsh -NoProfile -File ./scripts/run-all-tests.ps1" `
        -MaxRounds 4
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TaskPrompt,

    [string]$Feature,
    [string]$SpecDirectory,
    [string]$MailboxPath,

    [ValidateSet("claude", "antigravity", "copilot", "aider", "mock", "custom")]
    [string]$DevProvider = "claude",

    [ValidateSet("copilot", "claude", "antigravity", "gpt4o", "deepseek", "mock", "custom")]
    [string]$ReviewProvider = "copilot",

    [string]$VerifyCommand = "pwsh -NoProfile -File ./scripts/run-all-tests.ps1",
    [int]$MaxRounds = 4,

    # Custom/Mock hooks for extensible providers or test simulation
    [scriptblock]$DevCustomHook,
    [scriptblock]$ReviewerCustomHook,

    [switch]$AutoCommit,
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$ScriptsRoot = $PSScriptRoot
$ReviewMailboxScript = Join-Path $ScriptsRoot "review-mailbox.ps1"

function Resolve-MailboxFile {
    param([string]$CustomPath, [string]$SpecDir, [string]$FeatureName)

    if (-not [string]::IsNullOrWhiteSpace($CustomPath)) {
        if ([System.IO.Path]::IsPathRooted($CustomPath)) {
            return $CustomPath
        }
        return [System.IO.Path]::GetFullPath((Join-Path $PWD $CustomPath))
    }
    if (-not [string]::IsNullOrWhiteSpace($SpecDir)) {
        $resolved = if ([System.IO.Path]::IsPathRooted($SpecDir)) { $SpecDir } else { Join-Path $PWD $SpecDir }
        return (Join-Path $resolved "review-mailbox.json")
    }
    if (-not [string]::IsNullOrWhiteSpace($FeatureName)) {
        $fDir = Join-Path $PWD ".ai-workspace\specs\features\$FeatureName"
        if (Test-Path -LiteralPath $fDir) {
            return (Join-Path $fDir "review-mailbox.json")
        }
    }
    $sopDir = Join-Path $PWD ".ai-sop"
    if (Test-Path -LiteralPath $sopDir) {
        return (Join-Path $sopDir "review-mailbox.json")
    }
    return (Join-Path $PWD "review-mailbox.json")
}

function Invoke-DevTurn {
    param(
        [string]$Provider,
        [string]$Prompt,
        [int]$Round,
        [scriptblock]$CustomHook
    )

    Write-Host "`n🚀 [Round $Round] Waking Dev Agent (Provider: $Provider)..." -ForegroundColor Cyan
    
    if ($null -ne $CustomHook) {
        & $CustomHook -Prompt $Prompt -Round $Round
        return
    }

    switch ($Provider) {
        "claude" {
            Write-Host "Running Claude Code CLI..." -ForegroundColor Gray
            & claude -p "$Prompt"
        }
        "aider" {
            Write-Host "Running Aider CLI..." -ForegroundColor Gray
            & aider --message "$Prompt" --yes-always
        }
        "copilot" {
            Write-Host "Running GitHub Copilot CLI..." -ForegroundColor Gray
            & gh copilot suggest "$Prompt"
        }
        "antigravity" {
            Write-Host "Antigravity Dev Agent execution dispatched with prompt: $Prompt" -ForegroundColor Gray
        }
        "mock" {
            Write-Host "[MOCK DEV] Simulating code changes for prompt: $Prompt" -ForegroundColor Gray
        }
        default {
            throw "Unsupported DevProvider '$Provider'."
        }
    }
}

function Invoke-ReviewerTurn {
    param(
        [string]$Provider,
        [string]$OriginalTask,
        [string]$GitDiff,
        [int]$Round,
        [scriptblock]$CustomHook
    )

    Write-Host "`n🔍 [Round $Round] Waking Reviewer Agent (Provider: $Provider)..." -ForegroundColor Magenta

    if ($null -ne $CustomHook) {
        $result = & $CustomHook -OriginalTask $OriginalTask -GitDiff $GitDiff -Round $Round
        return $result
    }

    $systemInstruction = @"
You are an independent Senior Software Architect and Security/Logic Auditor.
Original Task: $OriginalTask
Current Git Diff of changes:
$GitDiff

Analyze the code changes critically for boundary errors, concurrency risks, resource leaks, or specification mismatches.
You MUST output a valid JSON object matching this structure (no markdown fences, just JSON):
{
  "verdict": "APPROVED" or "REJECTED",
  "highestSeverity": "NONE"|"LOW"|"MEDIUM"|"HIGH"|"CRITICAL",
  "summary": "Concise review summary",
  "issues": [
    {
      "file": "path/to/file",
      "lineRange": "10-20",
      "severity": "HIGH",
      "problem": "Specific defect description",
      "fixSuggestion": "Concrete fix instructions"
    }
  ],
  "nextPromptForDev": "Clear instructions for the developer on what to fix"
}
"@

    switch ($Provider.ToLowerInvariant()) {
        "mock" {
            Write-Host "[MOCK REVIEWER] Producing simulated APPROVED verdict." -ForegroundColor Gray
            return [ordered]@{
                verdict = "APPROVED"
                highestSeverity = "NONE"
                summary = "[Mock] Code looks robust and clean."
                issues = @()
                nextPromptForDev = ""
            }
        }
        { $_ -in @("claude", "claude_code") } {
            $claudeExe = Get-Command "claude" -ErrorAction SilentlyContinue
            if ($claudeExe) {
                $res = & $claudeExe.Source -p $systemInstruction 2>&1 | Out-String
                try {
                    $jsonObj = $res | ConvertFrom-Json
                    if ($jsonObj.verdict) { return $jsonObj }
                } catch {}
            }
            throw "PROVIDER_UNAVAILABLE: Claude CLI is not available or returned non-JSON output."
        }
        "copilot" {
            $ghExe = Get-Command "gh" -ErrorAction SilentlyContinue
            if ($ghExe) {
                $res = & $ghExe.Source copilot explain $systemInstruction 2>&1 | Out-String
                try {
                    $jsonObj = $res | ConvertFrom-Json
                    if ($jsonObj.verdict) { return $jsonObj }
                } catch {}
            }
            throw "PROVIDER_UNAVAILABLE: GitHub Copilot CLI is not available or returned non-JSON output."
        }
        default {
            throw "UNSUPPORTED_PROVIDER: Provider '$Provider' is not configured for automatic review execution. Provide -ReviewerCustomHook or use -Provider 'mock'."
        }
    }
}

# Resolve Feature Name
$effectiveFeature = if (-not [string]::IsNullOrWhiteSpace($Feature)) {
    $Feature
} else {
    "Task_" + [DateTime]::UtcNow.ToString("yyyyMMdd_HHmmss")
}

$effectiveMailboxPath = Resolve-MailboxFile -CustomPath $MailboxPath -SpecDir $SpecDirectory -FeatureName $effectiveFeature

Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host " 🤖 DUAL-AGENT AUTONOMOUS LOOP ORCHESTRATOR" -ForegroundColor Cyan
Write-Host " Feature       : $effectiveFeature"
Write-Host " Dev Agent     : $DevProvider"
Write-Host " Review Agent  : $ReviewProvider"
Write-Host " Max Rounds    : $MaxRounds"
Write-Host " Verify Command: $VerifyCommand"
Write-Host " Mailbox File  : $effectiveMailboxPath"
Write-Host "================================================================================" -ForegroundColor Cyan

# 1. Initialize Mailbox
$mappedDev = switch -Regex ($DevProvider) {
    '(?i)^claude' { 'CLAUDE_CODE' }
    '(?i)^antigravity' { 'ANTIGRAVITY' }
    '(?i)^copilot' { 'COPILOT' }
    '(?i)^cursor' { 'CURSOR' }
    '(?i)^aider' { 'AIDER' }
    '(?i)^mock' { 'ANTIGRAVITY' }
    default { 'CUSTOM' }
}
$mappedRev = switch -Regex ($ReviewProvider) {
    '(?i)^claude' { 'CLAUDE_CODE' }
    '(?i)^antigravity' { 'ANTIGRAVITY' }
    '(?i)^copilot' { 'COPILOT' }
    '(?i)^cursor' { 'CURSOR' }
    '(?i)^gpt' { 'GPT_4O' }
    '(?i)^mock' { if ($mappedDev -eq 'COPILOT') { 'ANTIGRAVITY' } else { 'COPILOT' } }
    default { if ($mappedDev -eq 'CUSTOM') { 'COPILOT' } else { 'CUSTOM' } }
}

& $ReviewMailboxScript -Operation Init `
    -Feature $effectiveFeature `
    -DevAgent $mappedDev `
    -ReviewerAgent $mappedRev `
    -MaxRounds $MaxRounds `
    -MailboxPath $effectiveMailboxPath | Out-Null

$currentPrompt = $TaskPrompt

while ($true) {
    # Read Mailbox State
    $mailboxRaw = [System.IO.File]::ReadAllText($effectiveMailboxPath, [System.Text.Encoding]::UTF8)
    $mailbox = ConvertFrom-Json $mailboxRaw -Depth 100
    $round = [int]$mailbox.round

    Write-Host "`n====================== [ ROUND $round / $MaxRounds - DEV PHASE ] ======================" -ForegroundColor Yellow

    # Phase 1: Dev Turn
    Invoke-DevTurn -Provider $DevProvider -Prompt $currentPrompt -Round $round -CustomHook $DevCustomHook

    # Phase 2: Dev Submit & Test Gate Verification
    Write-Host "`n⚙️ Running test gate and capturing changes..." -ForegroundColor Gray
    $devSubmitParams = @{
        Operation = "DevSubmit"
        MailboxPath = $effectiveMailboxPath
        Summary = "Round $round code modifications completed."
        RunVerifyCommand = $VerifyCommand
    }
    & $ReviewMailboxScript @devSubmitParams | Out-Null

    # Re-read mailbox after DevSubmit
    $mailboxRaw = [System.IO.File]::ReadAllText($effectiveMailboxPath, [System.Text.Encoding]::UTF8)
    $mailbox = ConvertFrom-Json $mailboxRaw -Depth 100

    if ($mailbox.currentDevSubmission.testGateStatus -ne "PASS") {
        Write-Host "❌ Test Gate Verification did not pass (status: $($mailbox.currentDevSubmission.testGateStatus)). Self-healing triggered..." -ForegroundColor Red
        $currentPrompt = "Your recent changes did not pass automated verification (status: $($mailbox.currentDevSubmission.testGateStatus)). Please inspect the test error output below and fix the implementation:`n`n" + $mailbox.currentDevSubmission.testOutput
        continue
    }

    Write-Host "✅ Test Gate Verification PASSED!" -ForegroundColor Green

    # Phase 3: Reviewer Turn
    Write-Host "`n====================== [ ROUND $round / $MaxRounds - REVIEW PHASE ] ======================" -ForegroundColor Magenta
    $gitDiff = try {
        $diffStr = git diff HEAD 2>$null | Out-String
        $untrackedStat = git status --porcelain -uall 2>$null
        if ($untrackedStat) {
            $untrackedDiffs = [System.Collections.Generic.List[string]]::new()
            foreach ($uLine in ($untrackedStat | Out-String -Stream)) {
                if ($uLine.Trim() -match '^\?\?\s+(.*)$') {
                    $uPath = $Matches[1].Trim()
                    if (Test-Path -LiteralPath $uPath -PathType Leaf) {
                        $content = [System.IO.File]::ReadAllText($uPath)
                        $untrackedDiffs.Add("=== Untracked File: $uPath ===`n$content")
                    }
                }
            }
            if ($untrackedDiffs.Count -gt 0) {
                $diffStr += "`n`n" + ($untrackedDiffs -join "`n`n")
            }
        }
        $diffStr
    } catch { "" }

    $reviewResult = Invoke-ReviewerTurn `
        -Provider $ReviewProvider `
        -OriginalTask $TaskPrompt `
        -GitDiff $gitDiff `
        -Round $round `
        -CustomHook $ReviewerCustomHook

    # Submit Review Verdict with CAS and separation of duties
    $issuesJsonStr = if ($reviewResult.issues) {
        $reviewResult.issues | ConvertTo-Json -Depth 10 -Compress
    } else {
        "[]"
    }

    $reviewSubmitParams = @{
        Operation = "ReviewSubmit"
        MailboxPath = $effectiveMailboxPath
        Verdict = [string]$reviewResult.verdict
        HighestSeverity = if ($reviewResult.highestSeverity) { [string]$reviewResult.highestSeverity } else { "NONE" }
        Summary = [string]$reviewResult.summary
        IssuesJson = $issuesJsonStr
        NextPromptForDev = if ($reviewResult.nextPromptForDev) { [string]$reviewResult.nextPromptForDev } else { "" }
        ExpectedRound = $round
        ExpectedSubmittedAt = if ($mailbox.currentDevSubmission.submittedAt -is [System.DateTime]) { $mailbox.currentDevSubmission.submittedAt.ToString("o") } else { [string]$mailbox.currentDevSubmission.submittedAt }
        ReviewerIdentity = $mappedRev
    }
    & $ReviewMailboxScript @reviewSubmitParams | Out-Null

    # Check terminal conditions
    $mailboxRaw = [System.IO.File]::ReadAllText($effectiveMailboxPath, [System.Text.Encoding]::UTF8)
    $mailbox = ConvertFrom-Json $mailboxRaw -Depth 100

    if ($mailbox.status -eq "APPROVED") {
        Write-Host "`n================================================================================" -ForegroundColor Green
        Write-Host " 🎉 DUAL-AGENT LOOP COMPLETED SUCCESSFULLY (APPROVED at Round $round)!" -ForegroundColor Green
        Write-Host " Summary: $($mailbox.history[-1].reviewVerdict.summary)" -ForegroundColor Cyan
        Write-Host "================================================================================" -ForegroundColor Green

        if ($AutoCommit) {
            Write-Host "📦 Creating automatic git commit..." -ForegroundColor Gray
            git add -A
            git commit -m "feat($effectiveFeature): completed via dual-agent loop (round $round)" | Out-Null
            Write-Host "✅ Committed successfully." -ForegroundColor Green
        }

        if ($PassThru) { return $mailbox }
        break
    }

    if ($mailbox.status -eq "REJECTED_MAX_ROUNDS") {
        Write-Host "`n================================================================================" -ForegroundColor Red
        Write-Host " 🛑 DUAL-AGENT LOOP HALTED: Max rounds ($MaxRounds) reached without approval." -ForegroundColor Red
        Write-Host " Latest Review Feedback:" -ForegroundColor Yellow
        Write-Host " $($mailbox.history[-1].reviewVerdict.summary)"
        Write-Host "================================================================================" -ForegroundColor Red
        if ($PassThru) { return $mailbox }
        exit 2
    }

    # If WAITING_DEV, prepare next round prompt
    if ($mailbox.status -eq "WAITING_DEV") {
        $lastReview = $mailbox.history[-1].reviewVerdict
        $currentPrompt = "Round $round Review REJECTED (Highest Severity: $($lastReview.highestSeverity)).`nSummary: $($lastReview.summary)`n`nInstructions for next round:`n$($lastReview.nextPromptForDev)"
        Write-Host "🔁 Issues detected. Auto-advancing to Round $($mailbox.round)..." -ForegroundColor Yellow
    }
}
