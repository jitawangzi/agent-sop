#requires -Version 7.0
# Shared task identity and validation inputs. No project-domain assumptions.
. (Join-Path $PSScriptRoot 'workflow-transaction.ps1')
. (Join-Path $PSScriptRoot 'task-policy.ps1')
. (Join-Path $PSScriptRoot 'verification-evidence.ps1')
. (Join-Path $PSScriptRoot 'verification-inputs.ps1')
. (Join-Path $PSScriptRoot 'task-diagnostics.ps1')
. (Join-Path $PSScriptRoot 'task-scope.ps1')
. (Join-Path $PSScriptRoot 'junit-evidence.ps1')
. (Join-Path $PSScriptRoot 'task-recovery.ps1')

function Get-AiSopTaskPath {
    param([string]$SpecDirectory, [string]$TaskId)
    if ($TaskId -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$') { throw 'TASK_ID_INVALID' }
    $root = Resolve-PhysicalPathIdentity -Path $SpecDirectory
    $path = Resolve-PhysicalPathIdentity -Path (Join-Path $root "tasks/$TaskId/task.json")
    $prefix = $root.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    $comparison = if ([OperatingSystem]::IsWindows()) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $path.StartsWith($prefix, $comparison)) { throw 'TASK_PATH_ESCAPE' }
    return $path
}

function Read-AiSopTask {
    param([string]$SpecDirectory, [string]$TaskId)
    $path = Get-AiSopTaskPath $SpecDirectory $TaskId
    if (-not [IO.File]::Exists($path)) { throw "TASK_NOT_FOUND: $TaskId" }
    $raw = [IO.File]::ReadAllText($path)
    Assert-AiSopWorkflowJsonSchema -Json $raw -SchemaId TASK
    $task = ConvertFrom-AiSopWorkflowJson -Json $raw -AsHashtable
    if ($task.taskId -cne $TaskId -or $task.feature -cne (Split-Path -Leaf $SpecDirectory)) { throw 'TASK_IDENTITY_MISMATCH' }
    return $task
}

function Get-AiSopChangedInputs {
    param($Before, $After)
    return @(@($Before.files.Keys) + @($After.files.Keys) | Sort-Object -CaseSensitive -Unique | Where-Object {
        $Before.files[$_] -cne $After.files[$_]
    })
}

function Assert-AiSopNoOtherActiveTask {
    param([string]$SpecDirectory, [string]$TaskId)
    # Called with the feature owner lock held. Local registries are not synced,
    # so an absent registry entry does not prove all synced tasks are inactive.
    $root=Resolve-PhysicalPathIdentity $SpecDirectory
    foreach ($entry in @(Get-ChildItem -LiteralPath (Join-Path $root 'tasks') -Directory -ErrorAction SilentlyContinue)) {
        if ($entry.Name -ceq $TaskId) { continue }
        try {
            $path=Get-AiSopTaskPath $root $entry.Name
            if (-not [IO.File]::Exists($path)) { continue }
            $task=Read-AiSopTask $root $entry.Name
        } catch { throw "TASK_INDEX_UNREADABLE:$($entry.Name):$($_.Exception.Message)" }
        if ($task.status -eq 'ACTIVE') {
            throw "TASK_ACTIVE_CONFLICT:$($task.taskId): Resume the existing task; if its local ownership is missing, Recover it first. For independent work, Suspend/Recover the old task before Start. No old completion gates are required."
        }
    }
}

function Get-AiSopTaskSpecDigest {
    param([string]$SpecDirectory, $ValidationContext)
    $SpecDirectory = Resolve-PhysicalPathIdentity $SpecDirectory
    if ($ValidationContext -and $ValidationContext.specDigests.ContainsKey($SpecDirectory)) {
        $cached = $ValidationContext.specDigests[$SpecDirectory]
        if ($cached.error) { throw $cached.error }; return $cached.value
    }
    $parts = @()
    foreach ($name in @('01_server_rules.md','06_design_contract.md','05_test_plan.md','05_test_coverage.json')) {
        $path = Join-Path $SpecDirectory $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $parts += "${name}:missing"; continue }
        $raw = [IO.File]::ReadAllText($path)
        if ($name -eq '05_test_coverage.json') {
            try {
                $coverage = ConvertFrom-AiSopWorkflowJson -Json $raw -AsHashtable
                if ($coverage -isnot [Collections.IDictionary]) { throw 'expected a JSON object' }
            } catch {
                $diagnostic = "SPEC_JSON_INVALID: $path; $($_.Exception.Message)"
                if ($ValidationContext) { $ValidationContext.specDigests[$SpecDirectory]=@{error=$diagnostic} }
                throw $diagnostic
            }
            $coverage.Remove('executionEvidence')
            $raw = ConvertTo-AiSopWorkflowCanonicalJson $coverage
        } else { $raw = ($raw -replace "`r`n", "`n").TrimEnd() }
        $parts += "${name}:$(Get-AiSopWorkflowSha256 $raw)"
    }
    $digest = Get-AiSopWorkflowSha256 ($parts -join "`n")
    if ($ValidationContext) { $ValidationContext.specDigests[$SpecDirectory]=@{value=$digest} }
    return $digest
}

function Get-AiSopTaskProblems {
    param($Task, [string]$WorkspacePath, [string]$SpecDirectory = '', $ValidationContext)
    $problems = [Collections.Generic.List[string]]::new()
    if (-not $ValidationContext) { $ValidationContext=New-AiSopValidationContext }
    try { $snapshot = Get-AiSopValidationSnapshot $WorkspacePath $ValidationContext }
    catch { return @($_.Exception.Message) }
    $specDigest = $null
    if ($Task.tier -eq 'T3' -and $SpecDirectory) {
        try { $specDigest=Get-AiSopTaskSpecDigest $SpecDirectory $ValidationContext }
        catch { $problems.Add($_.Exception.Message) }
    }
    foreach ($problem in @(Get-AiSopTaskScopeProblems $Task $WorkspacePath $SpecDirectory $ValidationContext)) { $problems.Add($problem) }
    if ($Task.tier -eq 'T2' -and -not $Task.syncReview) { $problems.Add('MISSING_SYNC_REVIEW: record affected documentation and test updates, or explain why unchanged') }
    foreach ($pending in @($Task.verifications | Where-Object { $_.outcome -eq 'RUNNING' })) { $problems.Add("RUN_UNFINISHED:$($pending.runId):$(Get-AiSopRunActivity $pending $WorkspacePath)") }
    foreach ($kind in @('compile', 'test')) {
        $applicability = if ($Task.applicability) { $Task.applicability[$kind] } else { $null }
        if ($kind -eq 'test' -and $Task.tier -eq 'T1' -and $applicability.status -ne 'REQUIRED') { continue }
        $records = @($Task.verifications | Where-Object { $_.kind -eq $kind })
        if ($applicability.status -eq 'NOT_APPLICABLE' -and $Task.tier -ne 'T3') {
            if ($applicability.inputDigest -cne $snapshot.digest) { $problems.Add("STALE_APPLICABILITY:$kind") }
            try {
                Assert-AiSopApplicabilityScope $Task $WorkspacePath $ValidationContext | Out-Null
                if ($applicability.startInputsRef -cne $Task.startInputs.inputsRef) { $problems.Add("APPLICABILITY_START_UNBOUND:${kind}:renew applicability against the original task Start record") }
            } catch { $problems.Add($_.Exception.Message) }
            $latest = @($records | Group-Object batch | ForEach-Object { @($_.Group)[-1] })
            foreach ($record in $latest) {
                if ($record.exitCode -ne 0 -or -not $record.inputsStable) { $problems.Add("EXECUTION_FAILED:${kind}:$($record.batch):cannot hide failure with NOT_APPLICABLE") }
            }
            continue
        }
        if (-not $records.Count) { $problems.Add("MISSING_EVIDENCE:$kind"); continue }
        # Each named test batch must have a successful latest execution. A later
        # green batch cannot hide an unresolved failure in another batch.
        foreach ($group in @($records | Group-Object batch)) {
            $record = @($group.Group)[-1]
            try { Assert-AiSopJUnitResult $record } catch { $problems.Add($_.Exception.Message) }
            $recordInputs=$null
            try { $recordInputs=Read-AiSopVerificationInputs $record $WorkspacePath $ValidationContext }
            catch { $problems.Add($_.Exception.Message) }
            if ($record.exitCode -ne 0) { $problems.Add("EXECUTION_FAILED:${kind}:$($record.batch):exit=$($record.exitCode)") }
            if ($Task.tier -eq 'T3' -and $kind -eq 'test' -and $SpecDirectory -and $record.specDigest -cne $specDigest) {
                $problems.Add("STALE_SPEC_EVIDENCE:test:$($record.batch):requirement/design/test-definition changed")
            }
            if ($record.inputDigest -cne $snapshot.digest -or -not $record.inputsStable) {
                $changed = if ($recordInputs) { Get-AiSopChangedInputs -Before $recordInputs -After $snapshot } else { @('input manifest unavailable') }
                $changed = @($changed)
                $detail = if ($changed.Count) { (@($changed | Select-Object -First 20) -join ',') + $(if ($changed.Count -gt 20) { " (+$($changed.Count - 20) more)" }) } else { 'input policy/algorithm changed or inputs were unstable during execution' }
                $problems.Add("STALE_EVIDENCE:${kind}:$($record.batch):$detail")
            }
        }
    }
    if ($Task.tier -eq 'T3') {
        $latestTests = @($Task.verifications | Where-Object { $_.kind -eq 'test' } | Group-Object batch | ForEach-Object { @($_.Group)[-1] })
        $covered = @($latestTests | Where-Object { $_.exitCode -eq 0 -and $_.inputDigest -ceq $snapshot.digest -and $_.inputsStable -and (-not $SpecDirectory -or $_.specDigest -ceq $specDigest) } | ForEach-Object { if ($_.context.junitConfiguration) { $_.reportEvidence.passedCaseIds } else { $_.caseIds } } | Sort-Object -Unique)
        $missing = @($Task.requiredCaseIds | Where-Object { $_ -notin $covered })
        if ($missing.Count) { $problems.Add("UNCOVERED_CASES:$($missing -join ',')") }
    }
    return $problems.ToArray()
}

# Inspect ignore rules in the repository that owns specs, which may itself be a
# nested repository or worktree. A parent's ignore rule is normal in that layout.
function Get-AiSopSpecSyncWarning {
    param([string]$WorkspacePath)
    if (-not (Get-Command git -CommandType Application -ErrorAction SilentlyContinue)) { return }
    $specRoot = Resolve-PhysicalPathIdentity -Path (Join-Path $WorkspacePath '.ai-workspace/specs')
    $existing = $specRoot
    while (-not (Test-Path -LiteralPath $existing -PathType Container)) {
        $parent = Split-Path -Parent $existing
        if (-not $parent -or $parent -eq $existing) { return }
        $existing = $parent
    }
    $repo = & git -C $existing rev-parse --show-toplevel 2>$null
    if ($LASTEXITCODE -ne 0) { return }
    $repo = Resolve-PhysicalPathIdentity -Path ([string]$repo)
    foreach ($relative in @('features/__sop_sync_probe__/06_design_contract.md', '.artifacts/inputs/__sop_sync_probe__.json', '.artifacts/changes/__sop_sync_probe__.json')) {
        $probe = [IO.Path]::GetRelativePath($repo, (Join-Path $specRoot $relative)).Replace('\', '/')
        $ignored = & git -C $repo check-ignore -- $probe 2>$null
        if ($LASTEXITCODE -eq 0 -and $ignored) {
            return "SPECS_IGNORED: $relative is ignored by its owning Git repository '$repo'; review feature and input-manifest tracking there before handoff. No ignore rules or tracked files were changed."
        }
    }
}


function Get-AiSopRunActivity {
    param($Record, [string]$WorkspacePath)
    if ($Record.outcome -ne 'RUNNING') { return 'NONE' }
    if ($Record.context.runnerMachine -cne [Environment]::MachineName -or
        $Record.context.workspace -cne (Resolve-PhysicalPathIdentity $WorkspacePath)) { return 'REMOTE_UNKNOWN' }
    foreach ($prefix in @('runner','child')) {
        if (-not $Record.context["${prefix}Pid"] -or -not $Record.context["${prefix}StartedAt"]) { continue }
        $process = $null
        try {
            $process = [Diagnostics.Process]::GetProcessById([int]$Record.context["${prefix}Pid"])
            if ($process.StartTime.ToUniversalTime().ToString('o') -ceq $Record.context["${prefix}StartedAt"] -and -not $process.HasExited) { return 'RUNNING' }
        } catch [ArgumentException] { } catch { return 'UNCONFIRMED' } finally { if ($process) { $process.Dispose() } }
    }
    return 'INTERRUPTED'
}

function Get-AiSopTaskSummary {
    param($Task, [string]$WorkspacePath, [string]$SpecDirectory, [switch]$CheckInputs, $ValidationContext, [switch]$RecheckHistory)
    $ownerPath = Join-Path (Get-AiSopWorkflowOwnerRegistryRoot -WorkspacePath $WorkspacePath) ($Task.feature.ToLowerInvariant() + '.json')
    $owner = $null; $sessionStatus = 'MISSING'; $ownerStatus = 'MISSING'; $diagnostics = @()
    if (Test-Path -LiteralPath $ownerPath) {
        try {
            $ownerRaw = [IO.File]::ReadAllText($ownerPath)
            Assert-AiSopWorkflowJsonSchema -Json $ownerRaw -SchemaId OWNER
            $owner = ConvertFrom-AiSopWorkflowJson $ownerRaw -AsHashtable
            $ownerStatus = if ($owner.taskId -ceq $Task.taskId -and $owner.ownerId -ceq $Task.ownerId) { $owner.status } else { 'OTHER_TASK' }
            if ($ownerStatus -eq 'ACTIVE' -and $owner.sessionBinding) {
                $sessionStatus = (Get-AiSopWorkflowSession -SessionKey $owner.sessionBinding.sessionKey -WorkspacePath $WorkspacePath).EffectiveStatus
            }
        } catch { $diagnostics += $_.Exception.Message; $sessionStatus = 'UNAVAILABLE' }
    }
    $runs = @($Task.verifications | Where-Object { $_.outcome -eq 'RUNNING' } | ForEach-Object {
        $pendingResult = if ($_.runId) { Get-AiSopRunEvidencePath $SpecDirectory $Task.taskId $_.runId } else { '' }
        @{ runId=$_.runId; kind=$_.kind; batch=$_.batch; activity=(Get-AiSopRunActivity $_ $WorkspacePath); logFile=(Get-AiSopRunLogPath $_ $WorkspacePath $SpecDirectory $Task.taskId); pendingResult=$(if ($pendingResult -and [IO.File]::Exists($pendingResult)) { $pendingResult } else { $null }) }
    })
    $action = if ($Task.status -in @('DONE','CANCELLED')) { 'Start a new task for new work' }
        elseif (@($runs | Where-Object { $_.pendingResult }).Count) { 'Inspect pending result; RetryEvidence saves a terminal result without rerunning. If the session ended, Recover after execution stops, then Resume.' }
        elseif ($runs.Count -and @($runs | Where-Object activity -eq 'RUNNING').Count) { 'Wait for the running command; inspect its log' }
        elseif ($runs.Count) { 'Recover interrupted/foreign run, then Resume' }
        elseif ($Task.status -eq 'PAUSED') { 'Resume' }
        elseif ($ownerStatus -ne 'ACTIVE' -or $sessionStatus -eq 'UNAVAILABLE') { 'Recover local ownership, then Resume' }
        elseif ($sessionStatus -in @('ACTIVE','IDLE')) { 'Existing session may still be active; Resume only for intentional handoff' }
        else { 'Resume' }
    $terminal = $Task.status -in @('DONE','CANCELLED')
    $checkCurrentInputs = $CheckInputs -and (-not $terminal -or $RecheckHistory)
    $verification = if ($terminal) { 'HISTORICAL_NOT_RECHECKED' } else { 'NOT_CHECKED' }
    if ($checkCurrentInputs) {
        try {
            $problems = @(Get-AiSopTaskProblems $Task $WorkspacePath $SpecDirectory $ValidationContext)
            $verification = if ($problems.Count) { 'NEEDS_ATTENTION' }
                elseif ($Task.tier -ne 'T3' -and $Task.applicability -and @($Task.applicability.Values | Where-Object { $_.status -eq 'NOT_APPLICABLE' }).Count) { 'APPLICABILITY_RECORDED' }
                else { 'EXECUTION_EVIDENCE_CURRENT' }
            $diagnostics += $problems
        } catch { $verification='UNAVAILABLE'; $diagnostics += $_.Exception.Message }
    }
    return [ordered]@{
        feature=$Task.feature; taskId=$Task.taskId; tier=$Task.tier; status=$Task.status; objective=$Task.objective
        ownerStatus=$ownerStatus; sessionStatus=$sessionStatus; verification=$verification
        verificationScope=$(if ($checkCurrentInputs) { 'CURRENT_INPUTS' } else { 'NOT_CHECKED' })
        recordedApprovals=(Get-AiSopRecordedApprovals $SpecDirectory)
        nextAction=$Task.nextAction; suggestedAction=$action; notes=$Task.notes; runs=$runs
        baseline=$Task.baseline; startInputs=$Task.startInputs; caseScope=$Task.caseScope; requiredCaseIds=@($Task.requiredCaseIds)
        syncReview=$Task.syncReview; applicability=$Task.applicability
        tierHistory=@($Task.tierHistory | Where-Object { $null -ne $_ })
        pendingFollowUps=@($Task.followUps | Where-Object { $_.status -eq 'PENDING' })
        failedVerifications=@($Task.verifications | Group-Object kind,batch | ForEach-Object { @($_.Group)[-1] } | Where-Object { $_.exitCode -ne 0 -and $_.outcome -ne 'RUNNING' } | ForEach-Object { @{ kind=$_.kind; batch=$_.batch; exitCode=$_.exitCode; outcome=$_.outcome } })
        diagnostics=$diagnostics; updatedAt=$Task.updatedAt
    }
}

function Get-AiSopRecordedApprovals {
    param([string]$SpecDirectory)
    $path=Join-Path $SpecDirectory '00_workflow_state.json'
    if (-not [IO.File]::Exists($path)) { $path=Join-Path $SpecDirectory 'workflow-state.json' }
    if (-not [IO.File]::Exists($path)) { return @{ requirement='NOT_RECORDED'; design='NOT_RECORDED' } }
    try {
        $state=ConvertFrom-AiSopWorkflowJson ([IO.File]::ReadAllText($path)) -AsHashtable
        return @{ requirement=[string]$state.requirement.status; design=[string]$state.design.status }
    } catch { return @{ requirement='UNAVAILABLE'; design='UNAVAILABLE' } }
}

function Get-AiSopVerificationProfile {
    param([string]$WorkspacePath, [string]$Name)
    if ($Name -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$') { throw 'PROFILE_NAME_INVALID' }
    $path = Resolve-PhysicalPathIdentity (Join-Path $WorkspacePath '.ai-workspace/context/verification-commands.json')
    $root = (Resolve-PhysicalPathIdentity $WorkspacePath).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    $comparison = if ([OperatingSystem]::IsWindows()) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if (-not $path.StartsWith($root, $comparison)) { throw 'PROFILE_PATH_ESCAPE' }
    if (-not [IO.File]::Exists($path)) { throw "PROFILE_CONFIG_MISSING: $path" }
    $raw = [IO.File]::ReadAllText($path)
    if (-not ($raw | Test-Json -SchemaFile (Join-Path (Split-Path -Parent $PSScriptRoot) 'schemas/verification-commands.schema.json'))) { throw 'PROFILE_CONFIG_INVALID' }
    $config = ConvertFrom-AiSopWorkflowJson $raw -AsHashtable
    if (-not $config.commands.Contains($Name)) { throw "PROFILE_NOT_FOUND: $Name" }
    return @{ command=$config.commands[$Name]; path=$path; digest=(Get-AiSopWorkflowSha256 $raw) }
}
