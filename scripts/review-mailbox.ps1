#requires -Version 7.0

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet(
        "Init",
        "DevSubmit",
        "ReviewSubmit",
        "GetStatus",
        "Reset"
    )]
    [string]$Operation,

    [string]$Feature,
    [string]$SpecDirectory,
    [string]$MailboxPath,

    [ValidateSet("ANTIGRAVITY", "CLAUDE_CODE", "COPILOT", "CURSOR", "AIDER", "CUSTOM")]
    [string]$DevAgent = "ANTIGRAVITY",

    [ValidateSet("COPILOT", "CLAUDE_CODE", "ANTIGRAVITY", "CURSOR", "GPT_4O", "CUSTOM")]
    [string]$ReviewerAgent = "COPILOT",

    [int]$MaxRounds = 4,

    # Dev submission parameters
    [string]$Summary,
    [string[]]$ChangedFiles,
    [ValidateSet("PASS", "FAIL", "SKIPPED")]
    [string]$TestGateStatus,
    [string]$TestOutput = "",
    [string]$RunVerifyCommand,

    # Reviewer submission parameters
    [ValidateSet("APPROVED", "REJECTED")]
    [string]$Verdict,
    [ValidateSet("NONE", "LOW", "MEDIUM", "HIGH", "CRITICAL")]
    [string]$HighestSeverity,
    [string]$IssuesJson = "[]",
    [string]$NextPromptForDev = "",

    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-MailboxSchemaPath {
    $root = Split-Path -Parent $PSScriptRoot
    return (Join-Path $root "schemas\review-mailbox.schema.json")
}

function Resolve-MailboxFilePath {
    param(
        [string]$CustomPath,
        [string]$SpecDir,
        [string]$FeatureName
    )

    if (-not [string]::IsNullOrWhiteSpace($CustomPath)) {
        if ([System.IO.Path]::IsPathRooted($CustomPath)) {
            return $CustomPath
        }
        return [System.IO.Path]::GetFullPath((Join-Path $PWD $CustomPath))
    }

    if (-not [string]::IsNullOrWhiteSpace($SpecDir)) {
        $resolvedSpec = if ([System.IO.Path]::IsPathRooted($SpecDir)) { $SpecDir } else { Join-Path $PWD $SpecDir }
        return (Join-Path $resolvedSpec "review-mailbox.json")
    }

    if (-not [string]::IsNullOrWhiteSpace($FeatureName)) {
        $featureDir = Join-Path $PWD ".ai-workspace\specs\features\$FeatureName"
        if (Test-Path -LiteralPath $featureDir) {
            return (Join-Path $featureDir "review-mailbox.json")
        }
    }

    $sopDir = Join-Path $PWD ".ai-sop"
    if (Test-Path -LiteralPath $sopDir) {
        return (Join-Path $sopDir "review-mailbox.json")
    }

    return (Join-Path $PWD "review-mailbox.json")
}

function Write-AtomicUtf8File {
    param(
        [Parameter(Mandatory = $true)] [string]$FilePath,
        [Parameter(Mandatory = $true)] [string]$Content
    )

    $parent = Split-Path -Parent $FilePath
    if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
        [System.IO.Directory]::CreateDirectory($parent) | Out-Null
    }

    $tempFile = [System.IO.Path]::Combine(
        [System.IO.Path]::GetDirectoryName($FilePath),
        ".tmp_" + [System.IO.Path]::GetFileName($FilePath) + "_" + [System.Guid]::NewGuid().ToString("N")
    )

    $encoding = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($tempFile, $Content, $encoding)

    [System.IO.File]::Move($tempFile, $FilePath, $true)
}

function Validate-MailboxSchema {
    param([Parameter(Mandatory = $true)] [string]$Json)

    $schemaPath = Get-MailboxSchemaPath
    if (-not (Test-Path -LiteralPath $schemaPath)) {
        throw "Schema file not found at: $schemaPath"
    }

    $isValid = $Json | Test-Json -SchemaFile $schemaPath
    if (-not $isValid) {
        throw "Review mailbox JSON failed schema validation ($schemaPath)"
    }
}

function ConvertTo-MailboxJson {
    param([Parameter(Mandatory = $true)] $MailboxObject)

    $historyArr = @(
        if ($MailboxObject.history) {
            foreach ($h in $MailboxObject.history) {
                $hDevSub = if ($null -ne $h.devSubmission) {
                    $hFiles = @(if ($h.devSubmission.changedFiles) { foreach ($f in $h.devSubmission.changedFiles) { [string]$f } })
                    [ordered]@{
                        submittedAt = [string]$h.devSubmission.submittedAt
                        summary = [string]$h.devSubmission.summary
                        changedFiles = $hFiles
                        testGateStatus = [string]$h.devSubmission.testGateStatus
                        testOutput = [string]$h.devSubmission.testOutput
                        gitDiffDigest = [string]$h.devSubmission.gitDiffDigest
                    }
                } else { $null }

                $hRevVer = if ($null -ne $h.reviewVerdict) {
                    $hIssues = @(if ($h.reviewVerdict.issues) {
                        foreach ($iss in $h.reviewVerdict.issues) {
                            [ordered]@{
                                file = [string]$iss.file
                                lineRange = if ($iss.lineRange) { [string]$iss.lineRange } else { "" }
                                severity = [string]$iss.severity
                                problem = [string]$iss.problem
                                fixSuggestion = [string]$iss.fixSuggestion
                            }
                        }
                    })
                    [ordered]@{
                        reviewedAt = [string]$h.reviewVerdict.reviewedAt
                        verdict = [string]$h.reviewVerdict.verdict
                        highestSeverity = [string]$h.reviewVerdict.highestSeverity
                        summary = [string]$h.reviewVerdict.summary
                        issues = $hIssues
                        nextPromptForDev = [string]$h.reviewVerdict.nextPromptForDev
                    }
                } else { $null }

                [ordered]@{
                    round = [int]$h.round
                    devSubmission = $hDevSub
                    reviewVerdict = $hRevVer
                }
            }
        }
    )

    $devSub = if ($null -ne $MailboxObject.currentDevSubmission) {
        $cf = @(if ($MailboxObject.currentDevSubmission.changedFiles) { foreach ($f in $MailboxObject.currentDevSubmission.changedFiles) { [string]$f } })
        [ordered]@{
            submittedAt = [string]$MailboxObject.currentDevSubmission.submittedAt
            summary = [string]$MailboxObject.currentDevSubmission.summary
            changedFiles = $cf
            testGateStatus = [string]$MailboxObject.currentDevSubmission.testGateStatus
            testOutput = [string]$MailboxObject.currentDevSubmission.testOutput
            gitDiffDigest = [string]$MailboxObject.currentDevSubmission.gitDiffDigest
        }
    } else { $null }

    $revVerdict = if ($null -ne $MailboxObject.currentReviewVerdict) {
        $issues = @(if ($MailboxObject.currentReviewVerdict.issues) {
            foreach ($iss in $MailboxObject.currentReviewVerdict.issues) {
                [ordered]@{
                    file = [string]$iss.file
                    lineRange = if ($iss.lineRange) { [string]$iss.lineRange } else { "" }
                    severity = [string]$iss.severity
                    problem = [string]$iss.problem
                    fixSuggestion = [string]$iss.fixSuggestion
                }
            }
        })
        [ordered]@{
            reviewedAt = [string]$MailboxObject.currentReviewVerdict.reviewedAt
            verdict = [string]$MailboxObject.currentReviewVerdict.verdict
            highestSeverity = [string]$MailboxObject.currentReviewVerdict.highestSeverity
            summary = [string]$MailboxObject.currentReviewVerdict.summary
            issues = $issues
            nextPromptForDev = [string]$MailboxObject.currentReviewVerdict.nextPromptForDev
        }
    } else { $null }

    $canonicalObj = [ordered]@{
        schemaVersion = "1.0"
        feature = [string]$MailboxObject.feature
        round = [int]$MailboxObject.round
        maxRounds = [int]$MailboxObject.maxRounds
        status = [string]$MailboxObject.status
        devAgent = [string]$MailboxObject.devAgent
        reviewerAgent = [string]$MailboxObject.reviewerAgent
        updatedAt = [string]$MailboxObject.updatedAt
        currentDevSubmission = $devSub
        currentReviewVerdict = $revVerdict
        history = $historyArr
    }

    return ($canonicalObj | ConvertTo-Json -Depth 100)
}

$targetMailbox = Resolve-MailboxFilePath -CustomPath $MailboxPath -SpecDir $SpecDirectory -FeatureName $Feature

switch ($Operation) {
    "Init" {
        $effectiveFeature = if (-not [string]::IsNullOrWhiteSpace($Feature)) { $Feature } else { "DefaultTask" }
        $now = [DateTime]::UtcNow.ToString("o")

        $mailboxObj = [ordered]@{
            schemaVersion = "1.0"
            feature = $effectiveFeature
            round = 1
            maxRounds = $MaxRounds
            status = "INITIALIZED"
            devAgent = $DevAgent
            reviewerAgent = $ReviewerAgent
            updatedAt = $now
            currentDevSubmission = $null
            currentReviewVerdict = $null
            history = @()
        }

        $jsonStr = ConvertTo-MailboxJson -MailboxObject $mailboxObj
        Validate-MailboxSchema -Json $jsonStr
        Write-AtomicUtf8File -FilePath $targetMailbox -Content $jsonStr

        Write-Host "✅ Review Mailbox initialized for [$effectiveFeature] at: $targetMailbox" -ForegroundColor Green
        if ($PassThru) { return $mailboxObj }
    }

    "DevSubmit" {
        if (-not (Test-Path -LiteralPath $targetMailbox)) {
            throw "Review Mailbox not found at $targetMailbox. Please run Init first."
        }

        $rawJson = [System.IO.File]::ReadAllText($targetMailbox, [System.Text.Encoding]::UTF8)
        $mailbox = ConvertFrom-Json $rawJson -Depth 100

        if ($mailbox.status -ne "INITIALIZED" -and $mailbox.status -ne "WAITING_DEV") {
            throw "Cannot submit dev changes when mailbox status is '$($mailbox.status)'. Expected INITIALIZED or WAITING_DEV."
        }

        if ([string]::IsNullOrWhiteSpace($Summary)) {
            throw "Parameter -Summary is required for DevSubmit."
        }

        $gateStatus = $TestGateStatus
        $testLog = $TestOutput

        # Run verification command if requested
        if (-not [string]::IsNullOrWhiteSpace($RunVerifyCommand)) {
            Write-Host "⚙️ Running verification command: $RunVerifyCommand ..." -ForegroundColor Gray
            $verifyOutput = & pwsh -NoProfile -Command $RunVerifyCommand 2>&1 | Out-String
            if ($LASTEXITCODE -eq 0) {
                $gateStatus = "PASS"
                Write-Host "✅ Verification passed!" -ForegroundColor Green
            } else {
                $gateStatus = "FAIL"
                Write-Host "❌ Verification failed!" -ForegroundColor Red
            }
            $testLog = $verifyOutput
        } elseif ([string]::IsNullOrWhiteSpace($gateStatus)) {
            $gateStatus = "SKIPPED"
        }

        # Resolve changed files if not provided
        $files = if ($ChangedFiles -and $ChangedFiles.Count -gt 0) {
            @($ChangedFiles)
        } else {
            try {
                $gitStatus = git status --porcelain 2>$null
                if ($gitStatus) {
                    @($gitStatus | ForEach-Object { ($_ -split '\s+', 2)[-1].Trim() } | Where-Object { $_ -ne "" })
                } else {
                    @()
                }
            } catch {
                @()
            }
        }

        # Generate Git Diff Digest
        $diffDigest = try {
            $diffStat = git diff --stat 2>$null | Out-String
            if ([string]::IsNullOrWhiteSpace($diffStat)) { "No working directory git diff detected" } else { $diffStat.Trim() }
        } catch {
            "Git diff unavailable"
        }

        $now = [DateTime]::UtcNow.ToString("o")

        $submission = [ordered]@{
            submittedAt = $now
            summary = $Summary
            changedFiles = @($files)
            testGateStatus = $gateStatus
            testOutput = $testLog
            gitDiffDigest = $diffDigest
        }

        $mailbox.currentDevSubmission = $submission
        $mailbox.status = "WAITING_REVIEW"
        $mailbox.updatedAt = $now

        $jsonStr = ConvertTo-MailboxJson -MailboxObject $mailbox
        Validate-MailboxSchema -Json $jsonStr
        Write-AtomicUtf8File -FilePath $targetMailbox -Content $jsonStr

        Write-Host "✅ Dev submission recorded for round $($mailbox.round). Status transitioned to WAITING_REVIEW." -ForegroundColor Green
        if ($PassThru) { return $mailbox }
    }

    "ReviewSubmit" {
        if (-not (Test-Path -LiteralPath $targetMailbox)) {
            throw "Review Mailbox not found at $targetMailbox."
        }

        $rawJson = [System.IO.File]::ReadAllText($targetMailbox, [System.Text.Encoding]::UTF8)
        $mailbox = ConvertFrom-Json $rawJson -Depth 100

        if ($mailbox.status -ne "WAITING_REVIEW") {
            throw "Cannot submit review when mailbox status is '$($mailbox.status)'. Expected WAITING_REVIEW."
        }

        if ([string]::IsNullOrWhiteSpace($Verdict)) {
            throw "Parameter -Verdict is required for ReviewSubmit."
        }
        if ([string]::IsNullOrWhiteSpace($Summary)) {
            throw "Parameter -Summary is required for ReviewSubmit."
        }

        $parsedIssues = @()
        if (-not [string]::IsNullOrWhiteSpace($IssuesJson)) {
            try {
                $parsed = ConvertFrom-Json $IssuesJson -Depth 100
                if ($parsed -is [System.Collections.IEnumerable] -and $parsed -isnot [string]) {
                    $parsedIssues = @($parsed)
                } else {
                    $parsedIssues = @($parsed)
                }
            } catch {
                throw "Failed to parse -IssuesJson as valid JSON: $_"
            }
        }

        $effectiveSeverity = if (-not [string]::IsNullOrWhiteSpace($HighestSeverity)) {
            $HighestSeverity
        } else {
            if ($Verdict -eq "APPROVED") { "NONE" } else { "MEDIUM" }
        }

        $now = [DateTime]::UtcNow.ToString("o")

        $verdictObj = [ordered]@{
            reviewedAt = $now
            verdict = $Verdict
            highestSeverity = $effectiveSeverity
            summary = $Summary
            issues = @($parsedIssues)
            nextPromptForDev = $NextPromptForDev
        }

        $mailbox.currentReviewVerdict = $verdictObj
        $mailbox.updatedAt = $now

        # Archive round into history
        $roundRecord = [ordered]@{
            round = [int]$mailbox.round
            devSubmission = $mailbox.currentDevSubmission
            reviewVerdict = $verdictObj
        }
        $newHistory = [System.Collections.Generic.List[object]]::new()
        if ($mailbox.history) {
            foreach ($item in $mailbox.history) {
                $newHistory.Add($item)
            }
        }
        $newHistory.Add($roundRecord)
        $mailbox.history = $newHistory.ToArray()

        if ($Verdict -eq "APPROVED") {
            $mailbox.status = "APPROVED"
            Write-Host "🎉 Review VERDICT is APPROVED! Loop successfully completed at round $($mailbox.round)." -ForegroundColor Green
        } else {
            if ($mailbox.round -ge $mailbox.maxRounds) {
                $mailbox.status = "REJECTED_MAX_ROUNDS"
                Write-Host "🛑 Review VERDICT is REJECTED and max rounds ($($mailbox.maxRounds)) reached. Status set to REJECTED_MAX_ROUNDS." -ForegroundColor Red
            } else {
                $mailbox.round = [int]$mailbox.round + 1
                $mailbox.status = "WAITING_DEV"
                $mailbox.currentDevSubmission = $null
                $mailbox.currentReviewVerdict = $null
                Write-Host "⚠️ Review VERDICT is REJECTED. Moving to round $($mailbox.round). Status set to WAITING_DEV." -ForegroundColor Yellow
            }
        }

        $jsonStr = ConvertTo-MailboxJson -MailboxObject $mailbox
        Validate-MailboxSchema -Json $jsonStr
        Write-AtomicUtf8File -FilePath $targetMailbox -Content $jsonStr

        if ($PassThru) { return $mailbox }
    }

    "GetStatus" {
        if (-not (Test-Path -LiteralPath $targetMailbox)) {
            Write-Host "Review Mailbox does not exist at: $targetMailbox" -ForegroundColor Gray
            return $null
        }

        $rawJson = [System.IO.File]::ReadAllText($targetMailbox, [System.Text.Encoding]::UTF8)
        $mailbox = ConvertFrom-Json $rawJson -Depth 100

        Write-Host "================ Dual-Agent Review Mailbox Status ================" -ForegroundColor Cyan
        Write-Host " Feature      : $($mailbox.feature)"
        Write-Host " Mailbox Path : $targetMailbox"
        Write-Host " Status       : $($mailbox.status)" -ForegroundColor $(
            switch ($mailbox.status) {
                "APPROVED" { "Green" }
                "WAITING_REVIEW" { "Yellow" }
                "WAITING_DEV" { "Magenta" }
                "REJECTED_MAX_ROUNDS" { "Red" }
                default { "White" }
            }
        )
        Write-Host " Current Round: $($mailbox.round) / $($mailbox.maxRounds)"
        Write-Host " Dev Agent    : $($mailbox.devAgent)"
        Write-Host " Review Agent : $($mailbox.reviewerAgent)"
        Write-Host " Updated At   : $($mailbox.updatedAt)"
        Write-Host " History Count: $($mailbox.history.Count)"
        Write-Host "==================================================================" -ForegroundColor Cyan

        if ($PassThru) { return $mailbox }
    }

    "Reset" {
        if (Test-Path -LiteralPath $targetMailbox) {
            Remove-Item -LiteralPath $targetMailbox -Force
            Write-Host "🧹 Review Mailbox removed at: $targetMailbox" -ForegroundColor Yellow
        } else {
            Write-Host "Review Mailbox was not present at: $targetMailbox" -ForegroundColor Gray
        }
    }
}
