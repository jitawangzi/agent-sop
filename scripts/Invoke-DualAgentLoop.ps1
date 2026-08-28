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
        -DevModel "claude-3-7-sonnet-20250219" `
        -DevReasoningEffort "high" `
        -ReviewProvider "copilot" `
        -ReviewModel "gpt-5.4" `
        -ReviewReasoningEffort "high" `
        -CopilotSessionId "9fa43261-d96c-430b-ac43-20e3035ec1bf" `
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
    [string]$ProjectRoot,

    [ValidateSet("claude", "antigravity", "copilot", "aider", "mock", "custom")]
    [string]$DevProvider = "claude",

    [ValidateSet("copilot", "claude", "antigravity", "gpt4o", "deepseek", "mock", "custom")]
    [string]$ReviewProvider = "copilot",

    # Model & Reasoning Effort Controls
    [string]$DevModel,
    [string]$ReviewModel,
    [string]$DevReasoningEffort,
    [string]$ReviewReasoningEffort,

    [string]$CopilotSessionId,

    [string]$VerifyCommand = "pwsh -NoProfile -File ./scripts/run-all-tests.ps1",
    [int]$MaxRounds = 4,
    [int]$MaxSelfHealAttempts = 3,

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
        [string]$SessionId,
        [string]$Model,
        [string]$ReasoningEffort,
        [scriptblock]$CustomHook
    )

    Write-Host "`n🛠️ [Round $Round] Waking Developer Agent (Provider: $Provider)..." -ForegroundColor Yellow

    if ($null -ne $CustomHook) {
        & $CustomHook -Prompt $Prompt -Round $Round -Model $Model -ReasoningEffort $ReasoningEffort
        return
    }

    switch ($Provider) {
        "claude" {
            Write-Host "Running Claude Code CLI..." -ForegroundColor Gray
            $claudeArgs = @("-p", "$Prompt")
            if (-not [string]::IsNullOrWhiteSpace($Model)) {
                $claudeArgs += @("--model", $Model)
            }
            if (-not [string]::IsNullOrWhiteSpace($ReasoningEffort)) {
                $env:MAX_THINKING_TOKENS = switch ($ReasoningEffort.ToLowerInvariant()) {
                    "high" { "16000" }
                    "medium" { "8000" }
                    "low" { "4000" }
                    default { $ReasoningEffort }
                }
            }
            & claude @claudeArgs
        }
        "aider" {
            Write-Host "Running Aider CLI..." -ForegroundColor Gray
            $aiderArgs = @("--message", "$Prompt", "--yes-always")
            if (-not [string]::IsNullOrWhiteSpace($Model)) {
                $aiderArgs += @("--model", $Model)
            }
            & aider @aiderArgs
        }
        "copilot" {
            Write-Host "Running GitHub Copilot CLI..." -ForegroundColor Gray
            $copilotCmd = Get-Command "copilot", "copilot.cmd", "copilot.ps1" -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($copilotCmd) {
                $argsList = @("-p", $Prompt, "--allow-all")
                if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
                    $argsList += "--resume=$SessionId"
                }
                if (-not [string]::IsNullOrWhiteSpace($Model)) {
                    $argsList += @("--model", $Model)
                }
                if (-not [string]::IsNullOrWhiteSpace($ReasoningEffort)) {
                    $argsList += @("--reasoning-effort", $ReasoningEffort)
                }
                & $copilotCmd.Source @argsList
            } else {
                throw "PROVIDER_UNAVAILABLE: GitHub Copilot CLI ('copilot') is not found in PATH."
            }
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
        [string]$SessionId,
        [string]$Model,
        [string]$ReasoningEffort,
        [scriptblock]$CustomHook
    )

    Write-Host "`n🔍 [Round $Round] Waking Reviewer Agent (Provider: $Provider)..." -ForegroundColor Magenta

    if ($null -ne $CustomHook) {
        $result = & $CustomHook -OriginalTask $OriginalTask -GitDiff $GitDiff -Round $Round -Model $Model -ReasoningEffort $ReasoningEffort
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
                $claudeArgs = @("-p", $systemInstruction)
                if (-not [string]::IsNullOrWhiteSpace($Model)) {
                    $claudeArgs += @("--model", $Model)
                }
                if (-not [string]::IsNullOrWhiteSpace($ReasoningEffort)) {
                    $env:MAX_THINKING_TOKENS = switch ($ReasoningEffort.ToLowerInvariant()) {
                        "high" { "16000" }
                        "medium" { "8000" }
                        "low" { "4000" }
                        default { $ReasoningEffort }
                    }
                }
                $res = & $claudeExe.Source @claudeArgs 2>&1 | Out-String
                try {
                    $jsonStr = if ($res -match '(?ms)\{.*\}') { $Matches[0] } else { $res }
                    $jsonObj = $jsonStr | ConvertFrom-Json
                    if ($null -ne $jsonObj -and -not [string]::IsNullOrWhiteSpace($jsonObj.verdict)) {
                        return $jsonObj
                    }
                } catch {}
                throw "PROVIDER_OUTPUT_INVALID: Claude CLI returned non-JSON review output: $res"
            }
            throw "PROVIDER_UNAVAILABLE: Claude CLI is not available in PATH."
        }
        "copilot" {
            $copilotCmd = Get-Command "copilot", "copilot.cmd", "copilot.ps1" -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $copilotCmd) {
                throw "PROVIDER_UNAVAILABLE: GitHub Copilot CLI ('copilot') is not found in PATH."
            }
            $argsList = @("-p", $systemInstruction, "-s", "--allow-all")
            if (-not [string]::IsNullOrWhiteSpace($SessionId)) {
                $argsList += "--resume=$SessionId"
            }
            if (-not [string]::IsNullOrWhiteSpace($Model)) {
                $argsList += @("--model", $Model)
            }
            if (-not [string]::IsNullOrWhiteSpace($ReasoningEffort)) {
                $argsList += @("--reasoning-effort", $ReasoningEffort)
            }
            $res = & $copilotCmd.Source @argsList 2>&1 | Out-String
            try {
                $jsonStr = if ($res -match '(?ms)\{.*\}') { $Matches[0] } else { $res }
                $jsonObj = $jsonStr | ConvertFrom-Json
                if ($null -ne $jsonObj -and -not [string]::IsNullOrWhiteSpace($jsonObj.verdict)) {
                    return $jsonObj
                }
            } catch {}
            throw "PROVIDER_OUTPUT_INVALID: GitHub Copilot CLI returned non-JSON review output: $res"
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

# Map Agents
$mappedDev = switch ($DevProvider.ToLowerInvariant()) {
    "claude" { "CLAUDE_CODE" }
    "aider" { "AIDER" }
    "copilot" { "COPILOT" }
    "antigravity" { "ANTIGRAVITY" }
    "mock" { "ANTIGRAVITY" }
    default { "CUSTOM" }
}
$mappedRev = switch ($ReviewProvider.ToLowerInvariant()) {
    "claude" { "CLAUDE_CODE" }
    "copilot" { "COPILOT" }
    "antigravity" { "ANTIGRAVITY" }
    "mock" { if ($mappedDev -eq "COPILOT") { "ANTIGRAVITY" } else { "COPILOT" } }
    default { if ($mappedDev -eq "CUSTOM") { "COPILOT" } else { "CUSTOM" } }
}

Write-Host "================================================================================" -ForegroundColor Cyan
Write-Host " 🤖 DUAL-AGENT AUTONOMOUS LOOP ORCHESTRATOR" -ForegroundColor Cyan
Write-Host " Feature       : $effectiveFeature" -ForegroundColor White
Write-Host " Dev Agent     : $DevProvider ($mappedDev) $(if ($DevModel) { "[Model: $DevModel, Effort: $DevReasoningEffort]" })" -ForegroundColor White
Write-Host " Review Agent  : $ReviewProvider ($mappedRev) $(if ($ReviewModel) { "[Model: $ReviewModel, Effort: $ReviewReasoningEffort]" })" -ForegroundColor White
Write-Host " Max Rounds    : $MaxRounds" -ForegroundColor White
Write-Host " Verify Command: $VerifyCommand" -ForegroundColor White
Write-Host " Mailbox File  : $effectiveMailboxPath" -ForegroundColor White
if (-not [string]::IsNullOrWhiteSpace($CopilotSessionId)) {
    Write-Host " Copilot Session: $CopilotSessionId" -ForegroundColor White
}
Write-Host "================================================================================" -ForegroundColor Cyan

# 1. Initialize Mailbox
& $ReviewMailboxScript -Operation Init `
    -Feature $effectiveFeature `
    -DevAgent $mappedDev `
    -ReviewerAgent $mappedRev `
    -MaxRounds $MaxRounds `
    -MailboxPath $effectiveMailboxPath `
    -ProjectRoot $ProjectRoot | Out-Null

$currentPrompt = $TaskPrompt
$selfHealAttempts = 0

while ($true) {
    # Read Mailbox State
    $mailboxRaw = [System.IO.File]::ReadAllText($effectiveMailboxPath, [System.Text.Encoding]::UTF8)
    $mailbox = ConvertFrom-Json $mailboxRaw -Depth 100
    $round = [int]$mailbox.round

    Write-Host "`n====================== [ ROUND $round / $MaxRounds - DEV PHASE ] ======================" -ForegroundColor Yellow

    # Phase 1: Dev Turn
    Invoke-DevTurn -Provider $DevProvider -Prompt $currentPrompt -Round $round -SessionId $CopilotSessionId -Model $DevModel -ReasoningEffort $DevReasoningEffort -CustomHook $DevCustomHook

    # Phase 2: Dev Submit & Test Gate Verification
    Write-Host "`n⚙️ Running test gate and capturing changes..." -ForegroundColor Gray
    $devSubmitParams = @{
        Operation = "DevSubmit"
        MailboxPath = $effectiveMailboxPath
        Summary = "Round $round code modifications completed."
        RunVerifyCommand = $VerifyCommand
        ProjectRoot = $ProjectRoot
    }
    & $ReviewMailboxScript @devSubmitParams | Out-Null

    # Re-read mailbox after DevSubmit
    $mailboxRaw = [System.IO.File]::ReadAllText($effectiveMailboxPath, [System.Text.Encoding]::UTF8)
    $mailbox = ConvertFrom-Json $mailboxRaw -Depth 100

    if ($mailbox.currentDevSubmission.testGateStatus -ne "PASS") {
        $selfHealAttempts++
        if ($selfHealAttempts -ge $MaxSelfHealAttempts) {
            throw "TEST_GATE_SELF_HEAL_EXCEEDED: Test verification failed $selfHealAttempts consecutive attempts in round $round. Halting loop to prevent infinite retry."
        }
        Write-Host "❌ Test Gate Verification did not pass (status: $($mailbox.currentDevSubmission.testGateStatus), attempt $selfHealAttempts/$MaxSelfHealAttempts). Self-healing triggered..." -ForegroundColor Red
        $currentPrompt = "Your recent changes did not pass automated verification (status: $($mailbox.currentDevSubmission.testGateStatus)). Please inspect the test error output below and fix the implementation:`n`n" + $mailbox.currentDevSubmission.testOutput
        continue
    }

    $selfHealAttempts = 0
    Write-Host "✅ Test Gate Verification PASSED!" -ForegroundColor Green

    # Phase 3: Reviewer Turn
    Write-Host "`n====================== [ ROUND $round / $MaxRounds - REVIEW PHASE ] ======================" -ForegroundColor Magenta
    $diffStr = git diff HEAD 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "DIFF_CAPTURE_FAILED: git diff HEAD failed with exit code $($LASTEXITCODE): $diffStr"
    }
    $untrackedStat = git status --porcelain -uall 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "STATUS_CAPTURE_FAILED: git status failed with exit code $($LASTEXITCODE): $untrackedStat"
    }
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
    $gitDiff = $diffStr

    $reviewResult = Invoke-ReviewerTurn `
        -Provider $ReviewProvider `
        -OriginalTask $TaskPrompt `
        -GitDiff $gitDiff `
        -Round $round `
        -SessionId $CopilotSessionId `
        -Model $ReviewModel `
        -ReasoningEffort $ReviewReasoningEffort `
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
        ProjectRoot = $ProjectRoot
    }
    & $ReviewMailboxScript @reviewSubmitParams | Out-Null

    # Check terminal conditions
    $mailboxRaw = [System.IO.File]::ReadAllText($effectiveMailboxPath, [System.Text.Encoding]::UTF8)
    $mailbox = ConvertFrom-Json $mailboxRaw -Depth 100

    if ($mailbox.status -eq "APPROVED") {
        Write-Host "`n================================================================================" -ForegroundColor Green
        Write-Host " 🏆 DUAL-AGENT LOOP COMPLETED SUCCESSFULLY (APPROVED at Round $round)!" -ForegroundColor Green
        Write-Host " Summary: $($mailbox.history[-1].reviewVerdict.summary)" -ForegroundColor Cyan
        Write-Host "================================================================================" -ForegroundColor Green

        if ($AutoCommit) {
            Write-Host "📦 Creating automatic git commit..." -ForegroundColor Gray
            git add -A
            if ($LASTEXITCODE -ne 0) {
                throw "AUTO_COMMIT_FAILED: git add -A failed with exit code $($LASTEXITCODE)."
            }
            $commitOut = git commit -m "feat($effectiveFeature): completed via dual-agent loop (round $round)" 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) {
                throw "AUTO_COMMIT_FAILED: git commit failed with exit code $($LASTEXITCODE): $commitOut"
            }
            Write-Host "✅ Committed successfully." -ForegroundColor Green
        }

        if ($PassThru) { return $mailbox }
        break
    }

    if ($mailbox.status -eq "REJECTED_MAX_ROUNDS") {
        Write-Host "`n================================================================================" -ForegroundColor Red
        Write-Host " 🚫 DUAL-AGENT LOOP HALTED: Max rounds ($MaxRounds) reached without approval." -ForegroundColor Red
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
        Write-Host "⚠️ Issues detected. Auto-advancing to Round $($mailbox.round)..." -ForegroundColor Yellow
    }
}