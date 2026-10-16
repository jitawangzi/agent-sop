#requires -Version 7.0
# Task baselines describe one change. Feature baselines remain the authority for
# long-lived approvals and legacy callers; neither is silently rewritten.
function New-AiSopTaskBaseline {
    param([string]$WorkspacePath)
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
    return $baseline
}

function Initialize-AiSopTaskStart {
    param($Task, [string]$WorkspacePath, [string]$TransactionId, [switch]$NewStart, [switch]$CaptureBaseline)
    $Task['baseline']=New-AiSopTaskBaseline $WorkspacePath
    if (-not $NewStart) { $Task.baseline.source='ADOPTED'; return }
    # Capture only this small contract, independently of the source-scan budget.
    # Resume/adoption must never manufacture a pre-edit contract snapshot.
    $Task['startImpact']=Get-AiSopTaskImpactSnapshot $Task $WorkspacePath
    $full=$Task.tier -eq 'T3' -or $CaptureBaseline
    $origin=@{
        status='UNAVAILABLE'; taskId=$Task.taskId; feature=$Task.feature; createdAt=$Task.createdAt
        transactionId=$TransactionId; mode=$(if ($full) { 'FULL' } else { 'BOUNDED' })
    }
    try {
        $snapshot=if ($full) { Get-AiSopInputSnapshot $WorkspacePath } else { Get-AiSopInputSnapshot $WorkspacePath -BudgetMilliseconds 500 -MaxBytes 8MB }
        $origin.inputsRef=Save-AiSopInputManifest $snapshot $WorkspacePath
        $origin.inputDigest=$snapshot.digest; $origin.status='CAPTURED'
    } catch {
        if ($full) { throw }
        # No partial snapshot is authoritative. Normal T1/T2 verification stays
        # available even when a quick start cannot prove the original inputs.
        $origin.reason=$_.Exception.Message
    }
    $Task['startInputs']=$origin
    if ($Task.tier -eq 'T3') {
        $Task.baseline.inputsRef=$origin.inputsRef; $Task.baseline.inputDigest=$origin.inputDigest
    }
}

function Get-AiSopTaskImpactSnapshot {
    param($Task, [string]$WorkspacePath)
    try {
        $path=Resolve-AiSopWorkspaceChild $WorkspacePath ".ai-workspace/specs/features/$($Task.feature)/04_change_impact.json"
        if (-not (Test-Path -LiteralPath $path)) { return @{status='ABSENT'} }
        return @{status='CAPTURED';artifactHash=(Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()}
    } catch { return @{status='UNAVAILABLE';reason=$_.Exception.Message} }
}

function Get-AiSopTaskImpactDisposition {
    param($Task, [string]$WorkspacePath)
    $current=Get-AiSopTaskImpactSnapshot $Task $WorkspacePath
    if ($current.status -eq 'UNAVAILABLE') { throw "TASK_IMPACT_UNAVAILABLE: $($current.reason)" }
    if ($current.status -eq 'ABSENT') {
        if ($Task.impactReview -or $Task.startImpact.status -eq 'CAPTURED') {
            throw 'TASK_IMPACT_MISSING: a recorded or reviewed 04_change_impact.json was removed; restore and review the task analysis'
        }
        return 'ABSENT'
    }
    $path=Resolve-AiSopWorkspaceChild $WorkspacePath ".ai-workspace/specs/features/$($Task.feature)/04_change_impact.json"
    $impact=ConvertFrom-AiSopWorkflowJson ([IO.File]::ReadAllText($path)) -AsHashtable
    if ($impact -isnot [Collections.IDictionary]) { throw 'TASK_IMPACT_INVALID: expected an object' }
    if ($impact.taskId -ceq $Task.taskId) { return 'CURRENT' }
    if ($Task.impactReview) {
        throw 'TASK_IMPACT_IDENTITY_MISMATCH: this task already reviewed 04; restore its taskId and run ReviewImpact after reviewing the changes'
    }
    if (-not $Task.startImpact) { return 'LEGACY_UNKNOWN' }
    if ($Task.startImpact.status -eq 'UNAVAILABLE') {
        throw 'TASK_IMPACT_ORIGIN_UNAVAILABLE: the Start contract could not be read; review and bind the current 04 to this task instead of assuming it is historical'
    }
    if ($Task.startImpact.status -eq 'CAPTURED' -and $Task.startImpact.artifactHash -ceq $current.artifactHash) { return 'HISTORICAL' }
    throw 'TASK_IMPACT_IDENTITY_MISMATCH: 04 was added or modified after Start; set its taskId to the current task and review it with ReviewImpact'
}

function Read-AiSopTaskStartInputs {
    param($Task, [string]$WorkspacePath, $ValidationContext)
    $origin=$Task.startInputs
    if (-not $origin -or $origin.status -ne 'CAPTURED') {
        throw 'TASK_START_INPUTS_UNAVAILABLE: no complete input snapshot was recorded at this task Start. Keep normal tier verification; a new task may request Start -CaptureBaseline before edits. Never adopt a post-change Run snapshot'
    }
    if ($origin.taskId -cne $Task.taskId -or $origin.feature -cne $Task.feature -or $origin.createdAt -cne $Task.createdAt -or
        $origin.transactionId -cnotmatch '^claim-[0-9a-f]{32}$') { throw 'TASK_START_IDENTITY_MISMATCH' }
    return Read-AiSopVerificationInputs $origin $WorkspacePath $ValidationContext
}

function Set-AiSopTaskStartBaseline {
    param($Task, [string]$WorkspacePath, [string]$InputsRef, [string]$Reason)
    if ($Task.baseline.inputsRef) { throw 'TASK_BASELINE_IMMUTABLE' }
    $snapshot=Read-AiSopTaskStartInputs $Task $WorkspacePath
    if ($InputsRef -cne $Task.startInputs.inputsRef) { throw 'TASK_BASELINE_SOURCE_UNVERIFIED: only this task Start snapshot can supply its baseline' }
    $Task.baseline.inputsRef=$Task.startInputs.inputsRef; $Task.baseline.inputDigest=$snapshot.digest
    $Task.baseline.source='START'; $Task.baseline.reason=$Reason
}

function Assert-AiSopApplicabilityScope {
    param($Task, [string]$WorkspacePath, $ValidationContext)
    $before=Read-AiSopTaskStartInputs $Task $WorkspacePath $ValidationContext
    $after=Get-AiSopValidationSnapshot $WorkspacePath $ValidationContext
    if ($before.algorithm -cne $after.algorithm -or [string]$before.policyDigest -cne [string]$after.policyDigest) {
        throw 'APPLICABILITY_POLICY_CHANGED: input rules must match task Start; do not classify changed source as non-executable after editing'
    }
    $policy=Get-AiSopInputPolicy $WorkspacePath
    if ([string]$policy.digest -cne [string]$after.policyDigest) { throw 'APPLICABILITY_POLICY_CHANGED: policy changed during validation' }
    $unsafe=@(foreach ($path in @(Get-AiSopChangedInputs $before $after)) {
        $declared=$false
        foreach ($rule in $policy.nonExecutable) { if (Test-AiSopInputPathWithin $path $rule.path) { $declared=$true; break } }
        if (-not $declared) { $path }
    })
    if ($unsafe.Count) { throw "APPLICABILITY_INPUTS_CHANGED: verification required for $(@($unsafe | Select-Object -First 20) -join ', '); only predeclared nonExecutable inputs may change under this exemption" }
    return $after
}

function Read-AiSopTaskBaselineInputs {
    param($Task, [string]$WorkspacePath, $ValidationContext)
    if (-not $Task.baseline.inputsRef) { throw 'TASK_BASELINE_REQUIRED: this task needs its recorded Start snapshot; SetBaseline cannot adopt arbitrary later manifests' }
    if ($Task.startInputs) {
        $before=Read-AiSopTaskStartInputs $Task $WorkspacePath $ValidationContext
        if ($Task.baseline.inputsRef -cne $Task.startInputs.inputsRef -or $Task.baseline.inputDigest -cne $Task.startInputs.inputDigest) { throw 'TASK_BASELINE_SOURCE_UNVERIFIED' }
    } elseif ($Task.baseline.source -ne 'START') {
        # Prior T3 Start snapshots remain valid. Old manually adopted baselines
        # have no machine-verifiable provenance and must not prove an empty delta.
        throw 'TASK_BASELINE_SOURCE_UNVERIFIED: legacy adopted baseline has no task Start provenance; restore the original task Start record or finish with the original engine after reviewing its full change scope'
    }
    if (-not $Task.startInputs) { $before=Read-AiSopVerificationInputs $Task.baseline $WorkspacePath $ValidationContext }
    return $before
}

function Get-AiSopTaskChanges {
    param($Task, [string]$WorkspacePath, $ValidationContext)
    $before=Read-AiSopTaskBaselineInputs $Task $WorkspacePath $ValidationContext
    $after=Get-AiSopValidationSnapshot $WorkspacePath $ValidationContext
    if ($before.algorithm -cne $after.algorithm -or [string]$before.policyDigest -cne [string]$after.policyDigest) {
        throw 'TASK_INPUT_POLICY_CHANGED: use the original input policy and matching engine algorithm; finish active tasks before upgrading input rules. Do not replace the task baseline to hide changed inputs'
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
    try { Get-AiSopTaskImpactDisposition $Task $WorkspacePath | Out-Null } catch { $problems.Add($_.Exception.Message) }
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
