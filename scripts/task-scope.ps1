#requires -Version 7.0
# Task baselines describe one change. Feature baselines remain the authority for
# long-lived approvals and legacy callers; neither is silently rewritten.
function New-AiSopTaskBaseline {
    param([string]$WorkspacePath, [string]$Tier, [switch]$CaptureInputs)
    $baseline=@{ vcs='none'; revision='0'; capturedAt=[DateTimeOffset]::UtcNow.ToString('o'); source='START' }
    if (Test-Path -LiteralPath (Join-Path $WorkspacePath '.svn')) {
        if (Get-Command svn -CommandType Application -ErrorAction SilentlyContinue) {
            $revision=& svn info --non-interactive --show-item revision $WorkspacePath 2>$null
            if ($LASTEXITCODE -eq 0 -and [string]$revision -match '^\d+$') { $baseline.vcs='svn'; $baseline.revision=[string]$revision }
        }
    } elseif (Test-Path -LiteralPath (Join-Path $WorkspacePath '.git')) {
        $revision=& git -C $WorkspacePath rev-parse --verify HEAD 2>$null
        if ($LASTEXITCODE -eq 0) { $baseline.vcs='git'; $baseline.revision=[string]$revision }
    }
    if ($CaptureInputs -and $Tier -eq 'T3') {
        $snapshot=Get-AiSopInputSnapshot $WorkspacePath
        $baseline.inputsRef=Save-AiSopInputManifest $snapshot $WorkspacePath
        $baseline.inputDigest=$snapshot.digest
    }
    return $baseline
}

function Get-AiSopTaskChanges {
    param($Task, [string]$WorkspacePath, $ValidationContext)
    if (-not $Task.baseline.inputsRef) { throw 'TASK_BASELINE_REQUIRED: use a known pre-change input manifest with SetBaseline; never capture already modified code as the original baseline' }
    $before=Read-AiSopVerificationInputs $Task.baseline $WorkspacePath $ValidationContext
    $after=Get-AiSopValidationSnapshot $WorkspacePath $ValidationContext
    if ($before.algorithm -cne $after.algorithm -or [string]$before.policyDigest -cne [string]$after.policyDigest) {
        throw 'TASK_INPUT_POLICY_CHANGED: restore the task input policy before reviewing changes; do not replace the task baseline to hide changed inputs'
    }
    $paths=[Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in @($before.files.Keys) + @($after.files.Keys)) { [void]$paths.Add($path) }
    $changes=@(foreach ($path in $paths) {
        $old=$before.files[$path]; $new=$after.files[$path]
        if ($old -ceq $new) { continue }
        @{ path=$path; before=$old; after=$new; status=$(if (-not $old) { 'ADDED' } elseif (-not $new) { 'DELETED' } else { 'MODIFIED' }) }
    })
    $manifest=@{ schemaVersion='1.0'; taskId=$Task.taskId; feature=$Task.feature; baselineRef=$Task.baseline.inputsRef; baselineInputDigest=$before.digest; changes=$changes }
    $raw=ConvertTo-AiSopWorkflowCanonicalJson $manifest
    return @{ manifest=$manifest; changeSetDigest=(Get-AiSopWorkflowSha256 $raw); inputDigest=$after.digest; baseline=$Task.baseline.revision }
}

function Save-AiSopTaskChangeManifest {
    param($Changes, [string]$WorkspacePath)
    $path=Resolve-AiSopWorkspaceChild $WorkspacePath ".ai-workspace/specs/.artifacts/changes/$($Changes.changeSetDigest).json"
    $raw=ConvertTo-AiSopWorkflowCanonicalJson $Changes.manifest
    if ([IO.File]::Exists($path)) {
        if ((Get-AiSopWorkflowSha256 ([IO.File]::ReadAllText($path))) -cne $Changes.changeSetDigest) { throw 'TASK_CHANGE_MANIFEST_CORRUPT' }
    } else { Write-AiSopWorkflowTextAtomic -Path $path -Text $raw }
    return $Changes.changeSetDigest
}

function Assert-AiSopTaskImpactBinding {
    param($Task, $Impact, [string]$WorkspacePath, $ValidationContext, [switch]$CheckReview, [string]$ArtifactHash)
    $changes=Get-AiSopTaskChanges $Task $WorkspacePath $ValidationContext
    if ($Impact.taskId -cne $Task.taskId -or $Impact.feature -cne $Task.feature -or
        $Impact.baseline -cne $Task.baseline.revision -or $Impact.baselineInputDigest -cne $Task.baseline.inputDigest -or
        $Impact.changeSetDigest -cne $changes.changeSetDigest) { throw 'TASK_IMPACT_STALE: use Task Changes and review the actual task delta before updating the impact contract' }
    $declared=@($Impact.changedFiles | Sort-Object -CaseSensitive -Unique)
    $actual=@($changes.manifest.changes | ForEach-Object { $_.path } | Sort-Object -CaseSensitive -Unique)
    if ((ConvertTo-AiSopWorkflowCanonicalJson $declared) -cne (ConvertTo-AiSopWorkflowCanonicalJson $actual)) { throw 'TASK_IMPACT_FILES_MISMATCH: changedFiles must include every added, modified and deleted input' }
    if ($CheckReview) {
        if ($Task.impactReview.artifactHash -cne $ArtifactHash -or $Task.impactReview.inputDigest -cne $changes.inputDigest -or
            $Task.impactReview.changeSetDigest -cne $changes.changeSetDigest) { throw 'IMPACT_REVIEW_REQUIRED: inspect current analysis and task delta, then ReviewImpact' }
        $path=Resolve-AiSopWorkspaceChild $WorkspacePath ".ai-workspace/specs/.artifacts/changes/$($changes.changeSetDigest).json"
        if (-not [IO.File]::Exists($path)) { throw "TASK_CHANGE_MANIFEST_MISSING: sync $path from the source workspace" }
        if ((Get-AiSopWorkflowSha256 ([IO.File]::ReadAllText($path))) -cne $changes.changeSetDigest) { throw 'TASK_CHANGE_MANIFEST_CORRUPT' }
    }
    return $changes
}

function Read-AiSopTaskCoverage {
    param([string]$SpecDirectory)
    $path=Join-Path $SpecDirectory '05_test_coverage.json'
    if (-not [IO.File]::Exists($path)) { throw "TASK_COVERAGE_MISSING: $path" }
    try {
        $coverage=ConvertFrom-AiSopWorkflowJson ([IO.File]::ReadAllText($path)) -AsHashtable
        if ($coverage -isnot [Collections.IDictionary] -or -not @($coverage.cases).Count) { throw 'cases must be a nonempty array' }
        $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($case in $coverage.cases) {
            if ([string]::IsNullOrWhiteSpace($case.id) -or -not $ids.Add([string]$case.id)) { throw 'case ids must be nonempty and unique' }
        }
        return $coverage
    } catch { throw "SPEC_JSON_INVALID: $path; $($_.Exception.Message)" }
}

function Set-AiSopTaskCaseScope {
    param($Task, [string[]]$CaseIds, [string]$Reason, [string]$SpecDirectory, [string]$At)
    if ([string]::IsNullOrWhiteSpace($Reason)) { throw 'TASK_CASE_SCOPE_REASON_REQUIRED' }
    if (-not $CaseIds.Count -or @($CaseIds | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count) { throw 'TASK_CASE_SCOPE_EMPTY' }
    $coverage=Read-AiSopTaskCoverage $SpecDirectory
    $known=@($coverage.cases.id)
    $unknown=@($CaseIds | Where-Object { $_ -cnotin $known })
    if ($unknown.Count) { throw "TASK_CASE_UNKNOWN:$($unknown -join ',')" }
    $entry=@{ caseIds=@($CaseIds | Sort-Object -CaseSensitive -Unique); reason=$Reason; specDigest=(Get-AiSopTaskSpecDigest $SpecDirectory); recordedAt=$At }
    $Task.requiredCaseIds=$entry.caseIds
    $Task['caseScope']=$entry
    $Task['caseScopeHistory']=@($Task.caseScopeHistory | Where-Object { $null -ne $_ }) + @($entry)
}

function Get-AiSopTaskScopeProblems {
    param($Task, [string]$WorkspacePath, [string]$SpecDirectory, $ValidationContext)
    $problems=[Collections.Generic.List[string]]::new()
    if ($Task.tier -ne 'T3') { return @() }
    try { Get-AiSopTaskChanges $Task $WorkspacePath $ValidationContext | Out-Null } catch { $problems.Add($_.Exception.Message) }
    if (-not $Task.caseScope -or -not @($Task.requiredCaseIds).Count) { $problems.Add('TASK_CASE_SCOPE_REQUIRED: SetCaseScope records the related cases and reason; no implicit whole-feature execution scope') }
    elseif ($SpecDirectory) {
        try {
            if ((ConvertTo-AiSopWorkflowCanonicalJson @($Task.caseScope.caseIds | Sort-Object -CaseSensitive)) -cne
                (ConvertTo-AiSopWorkflowCanonicalJson @($Task.requiredCaseIds | Sort-Object -CaseSensitive))) { $problems.Add('TASK_CASE_SCOPE_INCONSISTENT') }
            $coverage=Read-AiSopTaskCoverage $SpecDirectory
            $known=@($coverage.cases.id)
            foreach ($id in $Task.requiredCaseIds) { if ($id -cnotin $known) { $problems.Add("TASK_CASE_UNKNOWN:$id") } }
            if ($Task.caseScope.specDigest -cne (Get-AiSopTaskSpecDigest $SpecDirectory $ValidationContext)) { $problems.Add('TASK_CASE_SCOPE_STALE: review the affected cases after specification changes, then SetCaseScope') }
            $impactPath=Join-Path $SpecDirectory '04_change_impact.json'
            if ([IO.File]::Exists($impactPath)) {
                $impact=ConvertFrom-AiSopWorkflowJson ([IO.File]::ReadAllText($impactPath)) -AsHashtable
                if ($impact.taskId -ceq $Task.taskId) {
                    foreach ($id in $impact.requiredRegressionCases) { if ($id -cnotin $Task.requiredCaseIds) { $problems.Add("TASK_CASE_SCOPE_MISSING_REGRESSION:$id") } }
                }
            }
        } catch { $problems.Add($_.Exception.Message) }
    }
    return $problems.ToArray()
}
