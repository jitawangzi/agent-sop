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
    [string]$ProjectRoot,

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
    [int]$ExpectedRound = 0,
    [string]$ExpectedSubmittedAt = "",
    [string]$ReviewerIdentity = "",
    [switch]$StrictDutySeparation,

    # Quality Rubric parameters (mandatory when Verdict=APPROVED)
    [string]$QualityRubricJson = "",
    [string]$SpecAlignment = "",
    [string]$PersistenceSafety = "",
    [string]$BackwardCompatibility = "",
    [string]$PerformanceResource = "",
    [string]$EdgeCaseHandling = "",
    [string]$TestOracleIntegrity = "",

    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$pathIdentityScript = Join-Path $PSScriptRoot "path-identity.ps1"
if (Test-Path -LiteralPath $pathIdentityScript) {
    . $pathIdentityScript
}

function Get-MailboxSchemaPath {
    $root = Split-Path -Parent $PSScriptRoot
    return (Join-Path $root "schemas\review-mailbox.schema.json")
}

function Resolve-AiSopWorkspaceRoot {
    param([string]$StartPath)
    if ([string]::IsNullOrWhiteSpace($StartPath)) { return $null }
    $curDir = if (Test-Path -LiteralPath $StartPath -PathType Container) {
        [System.IO.Path]::GetFullPath($StartPath)
    } else {
        Split-Path -Parent ([System.IO.Path]::GetFullPath($StartPath))
    }
    while (-not [string]::IsNullOrWhiteSpace($curDir)) {
        if ((Test-Path -LiteralPath (Join-Path $curDir ".ai-workspace")) -or 
            (Test-Path -LiteralPath (Join-Path $curDir ".ai-sop")) -or 
            (Test-Path -LiteralPath (Join-Path $curDir ".git")) -or 
            (Test-Path -LiteralPath (Join-Path $curDir ".svn"))) {
            return $curDir
        }
        $parent = Split-Path -Parent $curDir
        if ($parent -eq $curDir) { break }
        $curDir = $parent
    }
    return $null
}

function Resolve-MailboxFilePath {
    param(
        [string]$CustomPath,
        [string]$SpecDir,
        [string]$FeatureName,
        [string]$ExplicitProjectRoot = $null
    )

    $resolvedPath = if (-not [string]::IsNullOrWhiteSpace($CustomPath)) {
        if ([System.IO.Path]::IsPathRooted($CustomPath)) {
            [System.IO.Path]::GetFullPath($CustomPath)
        } else {
            [System.IO.Path]::GetFullPath((Join-Path $PWD $CustomPath))
        }
    } elseif (-not [string]::IsNullOrWhiteSpace($SpecDir)) {
        $resolvedSpec = if ([System.IO.Path]::IsPathRooted($SpecDir)) { [System.IO.Path]::GetFullPath($SpecDir) } else { [System.IO.Path]::GetFullPath((Join-Path $PWD $SpecDir)) }
        Join-Path $resolvedSpec "review-mailbox.json"
    } elseif (-not [string]::IsNullOrWhiteSpace($FeatureName)) {
        if ($FeatureName -match '[\.\/\\:\*\?"<>\|]') {
            throw "INVALID_FEATURE_NAME: Feature name '$FeatureName' contains illegal characters or path traversal elements."
        }
        $featureDir = [System.IO.Path]::GetFullPath((Join-Path $PWD ".ai-workspace\specs\features\$FeatureName"))
        if (Test-Path -LiteralPath $featureDir) {
            Join-Path $featureDir "review-mailbox.json"
        } else {
            $sopDir = Join-Path $PWD ".ai-sop"
            if (Test-Path -LiteralPath $sopDir) {
                [System.IO.Path]::GetFullPath((Join-Path $sopDir "review-mailbox.json"))
            } else {
                [System.IO.Path]::GetFullPath((Join-Path $PWD "review-mailbox.json"))
            }
        }
    } else {
        $sopDir = Join-Path $PWD ".ai-sop"
        if (Test-Path -LiteralPath $sopDir) {
            [System.IO.Path]::GetFullPath((Join-Path $sopDir "review-mailbox.json"))
        } else {
            [System.IO.Path]::GetFullPath((Join-Path $PWD "review-mailbox.json"))
        }
    }

    # Confinement: target must be inside effective project workspace root
    $currentWs = if (-not [string]::IsNullOrWhiteSpace($ExplicitProjectRoot)) {
        [System.IO.Path]::GetFullPath($ExplicitProjectRoot)
    } elseif (-not [string]::IsNullOrWhiteSpace($SpecDir)) {
        Resolve-AiSopWorkspaceRoot -StartPath $SpecDir
    } else {
        Resolve-AiSopWorkspaceRoot -StartPath $PWD
    }
    if ([string]::IsNullOrWhiteSpace($currentWs)) {
        $currentWs = [System.IO.Path]::GetFullPath($PWD)
    }
    $physicalCurrentWs = if (Get-Command "Resolve-PhysicalPathIdentity" -ErrorAction SilentlyContinue) {
        Resolve-PhysicalPathIdentity -Path $currentWs
    } else {
        [System.IO.Path]::GetFullPath($currentWs)
    }

    $physicalTarget = if (Get-Command "Resolve-PhysicalPathIdentity" -ErrorAction SilentlyContinue) {
        Resolve-PhysicalPathIdentity -Path $resolvedPath
    } else {
        [System.IO.Path]::GetFullPath($resolvedPath)
    }

    $normWs = $physicalCurrentWs.TrimEnd('/', '\') + [System.IO.Path]::DirectorySeparatorChar
    if (-not $physicalTarget.Equals($physicalCurrentWs, [System.StringComparison]::OrdinalIgnoreCase) -and
        -not $physicalTarget.StartsWith($normWs, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "PATH_TRAVERSAL_DETECTED: Target mailbox path '$resolvedPath' (physical: '$physicalTarget') escapes the project workspace root '$physicalCurrentWs'."
    }

    return $resolvedPath
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

function Get-SafeProp {
    param($Obj, [string]$PropName, $Default = $null)
    if ($null -eq $Obj) { return $Default }
    if ($Obj -is [System.Collections.IDictionary]) {
        if ($Obj.Contains($PropName)) {
            $val = $Obj[$PropName]
            if ($null -ne $val) { return $val }
        }
        return $Default
    }
    if ($Obj.PSObject.Properties.Match($PropName).Count -gt 0) {
        $val = $Obj.$PropName
        if ($null -ne $val) { return $val }
    }
    return $Default
}

function ConvertTo-MailboxJson {
    param([Parameter(Mandatory = $true)] $MailboxObject)

    $historyArr = @(
        if ($MailboxObject.history) {
            foreach ($h in $MailboxObject.history) {
                $hDevSub = if ($null -ne (Get-SafeProp $h 'devSubmission')) {
                    $devSubVal = $h.devSubmission
                    $hFiles = @(if (Get-SafeProp $devSubVal 'changedFiles') { foreach ($f in $devSubVal.changedFiles) { [string]$f } })
                    $d = [ordered]@{
                        submittedAt = [string](Get-SafeProp $devSubVal 'submittedAt' '')
                        summary = [string](Get-SafeProp $devSubVal 'summary' '')
                        changedFiles = $hFiles
                        testGateStatus = [string](Get-SafeProp $devSubVal 'testGateStatus' '')
                        testOutput = [string](Get-SafeProp $devSubVal 'testOutput' '')
                        gitDiffDigest = [string](Get-SafeProp $devSubVal 'gitDiffDigest' '')
                    }
                    $cqs = Get-SafeProp $devSubVal 'codeQualityStatus'
                    if (-not [string]::IsNullOrWhiteSpace($cqs)) {
                        $d["codeQualityStatus"] = [string]$cqs
                    }
                    $cqr = Get-SafeProp $devSubVal 'codeQualityReport'
                    if (-not [string]::IsNullOrWhiteSpace($cqr)) {
                        $d["codeQualityReport"] = [string]$cqr
                    }
                    $d
                } else { $null }

                $hRevVer = if ($null -ne (Get-SafeProp $h 'reviewVerdict')) {
                    $revVerVal = $h.reviewVerdict
                    $hIssues = @(if (Get-SafeProp $revVerVal 'issues') {
                        foreach ($iss in $revVerVal.issues) {
                            [ordered]@{
                                file = [string](Get-SafeProp $iss 'file' '')
                                lineRange = [string](Get-SafeProp $iss 'lineRange' '')
                                severity = [string](Get-SafeProp $iss 'severity' '')
                                problem = [string](Get-SafeProp $iss 'problem' '')
                                fixSuggestion = [string](Get-SafeProp $iss 'fixSuggestion' '')
                            }
                        }
                    })
                    $r = [ordered]@{
                        reviewedAt = [string](Get-SafeProp $revVerVal 'reviewedAt' '')
                        verdict = [string](Get-SafeProp $revVerVal 'verdict' '')
                        highestSeverity = [string](Get-SafeProp $revVerVal 'highestSeverity' '')
                        summary = [string](Get-SafeProp $revVerVal 'summary' '')
                    }
                    $rubric = Get-SafeProp $revVerVal 'qualityRubric'
                    if ($null -ne $rubric) {
                        $r["qualityRubric"] = [ordered]@{
                            specAlignment = [string](Get-SafeProp $rubric 'specAlignment' '')
                            persistenceSafety = [string](Get-SafeProp $rubric 'persistenceSafety' '')
                            backwardCompatibility = [string](Get-SafeProp $rubric 'backwardCompatibility' '')
                            performanceResource = [string](Get-SafeProp $rubric 'performanceResource' '')
                            edgeCaseHandling = [string](Get-SafeProp $rubric 'edgeCaseHandling' '')
                            testOracleIntegrity = [string](Get-SafeProp $rubric 'testOracleIntegrity' '')
                        }
                    }
                    $r["issues"] = $hIssues
                    $r["nextPromptForDev"] = [string](Get-SafeProp $revVerVal 'nextPromptForDev' '')
                    $r
                } else { $null }

                [ordered]@{
                    round = [int]$h.round
                    devSubmission = $hDevSub
                    reviewVerdict = $hRevVer
                }
            }
        }
    )

    $devSub = if ($null -ne (Get-SafeProp $MailboxObject 'currentDevSubmission')) {
        $curDev = $MailboxObject.currentDevSubmission
        $cf = @(if (Get-SafeProp $curDev 'changedFiles') { foreach ($f in $curDev.changedFiles) { [string]$f } })
        $d = [ordered]@{
            submittedAt = [string](Get-SafeProp $curDev 'submittedAt' '')
            summary = [string](Get-SafeProp $curDev 'summary' '')
            changedFiles = $cf
            testGateStatus = [string](Get-SafeProp $curDev 'testGateStatus' '')
            testOutput = [string](Get-SafeProp $curDev 'testOutput' '')
            gitDiffDigest = [string](Get-SafeProp $curDev 'gitDiffDigest' '')
        }
        $cqs = Get-SafeProp $curDev 'codeQualityStatus'
        if (-not [string]::IsNullOrWhiteSpace($cqs)) {
            $d["codeQualityStatus"] = [string]$cqs
        }
        $cqr = Get-SafeProp $curDev 'codeQualityReport'
        if (-not [string]::IsNullOrWhiteSpace($cqr)) {
            $d["codeQualityReport"] = [string]$cqr
        }
        $d
    } else { $null }

    $revVerdict = if ($null -ne (Get-SafeProp $MailboxObject 'currentReviewVerdict')) {
        $curRev = $MailboxObject.currentReviewVerdict
        $issues = @(if (Get-SafeProp $curRev 'issues') {
            foreach ($iss in $curRev.issues) {
                [ordered]@{
                    file = [string](Get-SafeProp $iss 'file' '')
                    lineRange = [string](Get-SafeProp $iss 'lineRange' '')
                    severity = [string](Get-SafeProp $iss 'severity' '')
                    problem = [string](Get-SafeProp $iss 'problem' '')
                    fixSuggestion = [string](Get-SafeProp $iss 'fixSuggestion' '')
                }
            }
        })
        $r = [ordered]@{
            reviewedAt = [string](Get-SafeProp $curRev 'reviewedAt' '')
            verdict = [string](Get-SafeProp $curRev 'verdict' '')
            highestSeverity = [string](Get-SafeProp $curRev 'highestSeverity' '')
            summary = [string](Get-SafeProp $curRev 'summary' '')
        }
        $rubric = Get-SafeProp $curRev 'qualityRubric'
        if ($null -ne $rubric) {
            $r["qualityRubric"] = [ordered]@{
                specAlignment = [string](Get-SafeProp $rubric 'specAlignment' '')
                persistenceSafety = [string](Get-SafeProp $rubric 'persistenceSafety' '')
                backwardCompatibility = [string](Get-SafeProp $rubric 'backwardCompatibility' '')
                performanceResource = [string](Get-SafeProp $rubric 'performanceResource' '')
                edgeCaseHandling = [string](Get-SafeProp $rubric 'edgeCaseHandling' '')
                testOracleIntegrity = [string](Get-SafeProp $rubric 'testOracleIntegrity' '')
            }
        }
        $r["issues"] = $issues
        $r["nextPromptForDev"] = [string](Get-SafeProp $curRev 'nextPromptForDev' '')
        $r
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

function Invoke-WithMailboxLock {
    param(
        [string]$MailboxPath,
        [scriptblock]$Action
    )
    $lockPath = $MailboxPath + ".lock"
    $lockDir = Split-Path -Parent $lockPath
    if (-not [string]::IsNullOrWhiteSpace($lockDir) -and -not (Test-Path -LiteralPath $lockDir)) {
        [System.IO.Directory]::CreateDirectory($lockDir) | Out-Null
    }
    $maxWaitSec = 10
    $start = [DateTime]::UtcNow
    $stream = $null
    while (($([DateTime]::UtcNow) - $start).TotalSeconds -lt $maxWaitSec) {
        try {
            $stream = [System.IO.File]::Open(
                $lockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
            break
        } catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 50
        }
    }
    if ($null -eq $stream) {
        throw "MAILBOX_LOCK_TIMEOUT: Timed out waiting to acquire lock on '$lockPath'."
    }
    try {
        & $Action
    } finally {
        $stream.Dispose()
    }
}

$targetMailbox = Resolve-MailboxFilePath -CustomPath $MailboxPath -SpecDir $SpecDirectory -FeatureName $Feature -ExplicitProjectRoot $ProjectRoot

switch ($Operation) {
    "Init" {
        Invoke-WithMailboxLock -MailboxPath $targetMailbox -Action {
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
    }

    "DevSubmit" {
        Invoke-WithMailboxLock -MailboxPath $targetMailbox -Action {
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

            # Run code quality guard
            $codeQualityScript = Join-Path $PSScriptRoot "guard-code-quality.ps1"
            $codeQualityStatus = "SKIPPED"
            $codeQualityReport = ""
            $wsRoot = if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) { $ProjectRoot } else { Resolve-AiSopWorkspaceRoot -StartPath $targetMailbox }
            if ($null -ne $files -and @($files).Length -gt 0 -and (Test-Path -LiteralPath $codeQualityScript -PathType Leaf)) {
                try {
                    $guardRes = & $codeQualityScript -Files @($files) -WorkspaceRoot $wsRoot -PassThru
                    if ($null -ne $guardRes) {
                        $scannedCount = if ($null -ne $guardRes.ScannedFilesCount) { [int]$guardRes.ScannedFilesCount } else { @($files).Length }
                        if ($guardRes.IsValid) {
                            $codeQualityStatus = "PASS"
                            $codeQualityReport = "Code Quality Guard: 0 violations found across $scannedCount file(s)."
                            Write-Host "✅ Code Quality Guard passed ($scannedCount files scanned)." -ForegroundColor Green
                        } else {
                            $codeQualityStatus = "FAIL"
                            $violationsArr = @($guardRes.Violations)
                            $violationCount = $violationsArr.Length
                            $violationDetails = ($violationsArr | ForEach-Object { "[$($_.RuleId)] $($_.File):$($_.LineNumber) - $($_.Message)" }) -join "`n"
                            $codeQualityReport = "Code Quality Guard: Found $violationCount violation(s):`n$violationDetails"
                            Write-Host "❌ Code Quality Guard detected $violationCount violation(s)!" -ForegroundColor Red
                            throw "CODE_QUALITY_BLOCKED: DevSubmit rejected due to code quality violations:`n$violationDetails"
                        }
                    }
                } catch {
                    if ($_.Exception.Message -match "CODE_QUALITY_BLOCKED") {
                        throw
                    }
                }
            }

            $now = [DateTime]::UtcNow.ToString("o")

            $submission = [ordered]@{
                submittedAt = $now
                summary = $Summary
                changedFiles = @($files)
                testGateStatus = $gateStatus
                testOutput = $testLog
                gitDiffDigest = $diffDigest
                codeQualityStatus = $codeQualityStatus
                codeQualityReport = $codeQualityReport
            }

            $mailbox.currentDevSubmission = $submission
            if ($gateStatus -eq "PASS") {
                $mailbox.status = "WAITING_REVIEW"
                Write-Host "✅ Dev submission recorded for round $($mailbox.round). Status transitioned to WAITING_REVIEW." -ForegroundColor Green
            } else {
                $mailbox.status = "WAITING_DEV"
                Write-Host "⚠️ Dev submission recorded with testGateStatus='$gateStatus'. Status remains WAITING_DEV for self-healing." -ForegroundColor Yellow
            }
            $mailbox.updatedAt = $now

            $jsonStr = ConvertTo-MailboxJson -MailboxObject $mailbox
            Validate-MailboxSchema -Json $jsonStr
            Write-AtomicUtf8File -FilePath $targetMailbox -Content $jsonStr

            if ($PassThru) { return $mailbox }
        }
    }

    "ReviewSubmit" {
        Invoke-WithMailboxLock -MailboxPath $targetMailbox -Action {
            if (-not (Test-Path -LiteralPath $targetMailbox)) {
                throw "Review Mailbox not found at $targetMailbox."
            }

            $rawJson = [System.IO.File]::ReadAllText($targetMailbox, [System.Text.Encoding]::UTF8)
            $mailbox = ConvertFrom-Json $rawJson -Depth 100

            if ($mailbox.status -ne "WAITING_REVIEW") {
                throw "Cannot submit review when mailbox status is '$($mailbox.status)'. Expected WAITING_REVIEW."
            }

            # Mandatory CAS Check 1: Expected Round
            if ($ExpectedRound -le 0) {
                throw "MANDATORY_CAS_REQUIRED: ExpectedRound must be a positive integer for ReviewSubmit."
            }
            if ([int]$mailbox.round -ne $ExpectedRound) {
                throw "MAILBOX_CAS_CONFLICT: Expected round $ExpectedRound but mailbox is currently at round $($mailbox.round)."
            }

            # Mandatory CAS Check 2: Expected SubmittedAt
            if ([string]::IsNullOrWhiteSpace($ExpectedSubmittedAt)) {
                throw "MANDATORY_CAS_REQUIRED: ExpectedSubmittedAt is required for ReviewSubmit."
            }
            if ($mailbox.currentDevSubmission) {
                $actualSubStr = if ($mailbox.currentDevSubmission.submittedAt -is [System.DateTime]) { $mailbox.currentDevSubmission.submittedAt.ToString("o") } else { [string]$mailbox.currentDevSubmission.submittedAt }
                $match = $false
                try {
                    $dtExpected = [DateTimeOffset]::Parse($ExpectedSubmittedAt)
                    $dtActual = [DateTimeOffset]::Parse($actualSubStr)
                    if ([Math]::Abs(($dtExpected - $dtActual).TotalMilliseconds) -le 1000.0) {
                        $match = $true
                    }
                } catch {}
                if (-not $match -and $actualSubStr -ne $ExpectedSubmittedAt) {
                    throw "MAILBOX_CAS_CONFLICT: Expected submission at '$ExpectedSubmittedAt' but found '$actualSubStr'."
                }
            }

            # Mandatory Duty Separation Check
            $effDev = [string]$mailbox.devAgent
            $effRev = if (-not [string]::IsNullOrWhiteSpace($ReviewerIdentity)) { $ReviewerIdentity } else { [string]$mailbox.reviewerAgent }
            if ([string]::IsNullOrWhiteSpace($effRev)) {
                throw "MANDATORY_DUTY_SEPARATION: Reviewer identity must be specified."
            }
            if (-not [string]::IsNullOrWhiteSpace($effDev) -and $effDev.ToLowerInvariant() -eq $effRev.ToLowerInvariant()) {
                throw "SEPARATION_OF_DUTIES_VIOLATION: Developer agent '$effDev' cannot review their own submission."
            }

            if ([string]::IsNullOrWhiteSpace($Verdict)) {
                throw "Parameter -Verdict is required for ReviewSubmit."
            }
            if ([string]::IsNullOrWhiteSpace($Summary)) {
                throw "Parameter -Summary is required for ReviewSubmit."
            }

            # Test gate and quality rubric validation for APPROVED verdict
            $rubricObj = $null
            if ($Verdict -eq "APPROVED") {
                $devSub = $mailbox.currentDevSubmission
                if ($null -eq $devSub -or $devSub.testGateStatus -ne "PASS") {
                    $currStatus = if ($devSub) { [string]$devSub.testGateStatus } else { "NONE" }
                    throw "INVALID_REVIEW_VERDICT: Cannot approve submission when testGateStatus is '$currStatus' (must be PASS)."
                }

                # Quality Rubric Verification (Mandatory for APPROVED)
                if (-not [string]::IsNullOrWhiteSpace($QualityRubricJson)) {
                    try {
                        $rubricParsed = ConvertFrom-Json $QualityRubricJson -Depth 10
                        $SpecAlignment = if (-not [string]::IsNullOrWhiteSpace($rubricParsed.specAlignment)) { [string]$rubricParsed.specAlignment } else { $SpecAlignment }
                        $PersistenceSafety = if (-not [string]::IsNullOrWhiteSpace($rubricParsed.persistenceSafety)) { [string]$rubricParsed.persistenceSafety } else { $PersistenceSafety }
                        $BackwardCompatibility = if (-not [string]::IsNullOrWhiteSpace($rubricParsed.backwardCompatibility)) { [string]$rubricParsed.backwardCompatibility } else { $BackwardCompatibility }
                        $PerformanceResource = if (-not [string]::IsNullOrWhiteSpace($rubricParsed.performanceResource)) { [string]$rubricParsed.performanceResource } else { $PerformanceResource }
                        $EdgeCaseHandling = if (-not [string]::IsNullOrWhiteSpace($rubricParsed.edgeCaseHandling)) { [string]$rubricParsed.edgeCaseHandling } else { $EdgeCaseHandling }
                        $TestOracleIntegrity = if (-not [string]::IsNullOrWhiteSpace($rubricParsed.testOracleIntegrity)) { [string]$rubricParsed.testOracleIntegrity } else { $TestOracleIntegrity }
                    } catch {
                        throw "MANDATORY_QUALITY_RUBRIC_REQUIRED: Failed to parse -QualityRubricJson: $_"
                    }
                }

                $rubricFields = [ordered]@{
                    specAlignment = $SpecAlignment.Trim()
                    persistenceSafety = $PersistenceSafety.Trim()
                    backwardCompatibility = $BackwardCompatibility.Trim()
                    performanceResource = $PerformanceResource.Trim()
                    edgeCaseHandling = $EdgeCaseHandling.Trim()
                    testOracleIntegrity = $TestOracleIntegrity.Trim()
                }

                foreach ($kv in $rubricFields.GetEnumerator()) {
                    if ([string]::IsNullOrWhiteSpace($kv.Value) -or $kv.Value.Length -lt 5) {
                        throw "MANDATORY_QUALITY_RUBRIC_REQUIRED: Quality rubric dimension '$($kv.Key)' is missing or too short (must be >= 5 chars)."
                    }
                    if ($kv.Value -match '^(?i)(lgtm|ok|pass|passed|good|none|n/a|yes|true|all good|looks good)$') {
                        throw "INVALID_QUALITY_RUBRIC: Quality rubric dimension '$($kv.Key)' contains shallow filler ('$($kv.Value)'). Detailed technical evaluation is required."
                    }
                }

                # Anti-boilerplate: Ensure all 6 dimensions are not identical strings
                $distinctValues = @($rubricFields.Values | Select-Object -Unique)
                if ($distinctValues.Count -le 1) {
                    throw "INVALID_QUALITY_RUBRIC: Quality rubric dimensions cannot all be identical boilerplate. Each dimension requires an independent evaluation."
                }

                $rubricObj = $rubricFields
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
            }
            if ($null -ne $rubricObj) {
                $verdictObj["qualityRubric"] = $rubricObj
            }
            $verdictObj["issues"] = @($parsedIssues)
            $verdictObj["nextPromptForDev"] = $NextPromptForDev

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
        Invoke-WithMailboxLock -MailboxPath $targetMailbox -Action {
            if (Test-Path -LiteralPath $targetMailbox) {
                Remove-Item -LiteralPath $targetMailbox -Force
                Write-Host "🧹 Review Mailbox removed at: $targetMailbox" -ForegroundColor Yellow
            } else {
                Write-Host "Review Mailbox was not present at: $targetMailbox" -ForegroundColor Gray
            }
        }
    }
}
