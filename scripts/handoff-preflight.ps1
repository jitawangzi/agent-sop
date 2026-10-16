#requires -Version 7.0
# Observational only: do not call session getters that perform transaction
# recovery, acquire locks, execute a target engine, or scan business inputs.
function Get-AiSopPreflightRepository {
    param([string]$Path, [Collections.IDictionary]$Cache)
    $dir=Split-Path -Parent $Path
    while (-not [IO.Directory]::Exists($dir)) { $parent=Split-Path -Parent $dir; if (-not $parent -or $parent -eq $dir) { return $null }; $dir=$parent }
    if ($Cache.ContainsKey($dir)) { return $Cache[$dir] }
    $result=$null
    if (Get-Command git -CommandType Application -ErrorAction SilentlyContinue) {
        $repo=& git --no-optional-locks -C $dir rev-parse --show-toplevel 2>$null
        if ($LASTEXITCODE -eq 0) {
            $repo=Resolve-PhysicalPathIdentity ([string]$repo)
            $branch=& git --no-optional-locks -C $repo symbolic-ref --quiet --short HEAD 2>$null
            $commit=& git --no-optional-locks -C $repo rev-parse --verify HEAD 2>$null
            $result=@{root=$repo;branch=[string]$branch;commit=[string]$commit}
        }
    }
    $Cache[$dir]=$result
    return $result
}

function Add-AiSopPreflightArtifact {
    param([Collections.IDictionary]$Artifacts, [string]$WorkspacePath, [string]$RelativePath, [string]$Kind, [string]$RequiredBy, [Collections.IDictionary]$Repositories)
    if ($Artifacts.ContainsKey($RelativePath)) {
        $item=$Artifacts[$RelativePath]
        $item.requiredBy=@(@($item.requiredBy)+@($RequiredBy) | Sort-Object -Unique)
        return $item
    }
    $path=Resolve-AiSopWorkspaceChild $WorkspacePath $RelativePath
    $exists=[IO.File]::Exists($path)
    $repo=Get-AiSopPreflightRepository $path $Repositories
    $tracking='NO_GIT'; $dirty=$false
    if ($repo) {
        $relative=[IO.Path]::GetRelativePath($repo.root,$path).Replace('\','/')
        & git --no-optional-locks -C $repo.root ls-files --error-unmatch -- ":(literal)$relative" 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $tracking='TRACKED' }
        else {
            & git --no-optional-locks -C $repo.root check-ignore -- $relative 2>$null | Out-Null
            $tracking=if ($LASTEXITCODE -eq 0) { 'IGNORED' } else { 'UNTRACKED' }
        }
        $status=& git --no-optional-locks -C $repo.root status --porcelain --untracked-files=all -- ":(literal)$relative" 2>$null
        $dirty=-not [string]::IsNullOrWhiteSpace([string]$status)
    }
    $item=@{path=$RelativePath;kind=$Kind;requiredBy=@($RequiredBy);status=$(if ($exists) { 'PRESENT' } else { 'MISSING' });repository=$repo;tracking=$tracking;dirty=$dirty;diagnostics=@()}
    $Artifacts[$RelativePath]=$item
    return $item
}

function Get-AiSopPreflightLocalState {
    param($Task, [string]$SpecDirectory, [string]$WorkspacePath)
    $result=@{owner='MISSING';session='MISSING';runs=@();diagnostics=@()}
    $ownerRoot=Resolve-PhysicalPathIdentity (Get-AiSopWorkflowOwnerRegistryRoot -WorkspacePath $WorkspacePath)
    $ownerPath=Resolve-AiSopWorkspaceChild $ownerRoot ($Task.feature.ToLowerInvariant()+'.json')
    $recovery=Get-AiSopTaskRecoveryDiagnostics $SpecDirectory $Task.taskId $WorkspacePath $ownerPath
    if ([IO.File]::Exists($ownerPath)) {
        $ownerRecord=@($recovery.records | Where-Object kind -eq 'OWNER')[0]
        $result.owner=if ($ownerRecord.status -eq 'VALID') { $ownerRecord.ownerStatus } else { $ownerRecord.status }
        if ($ownerRecord.diagnostic) { $result.diagnostics+=@($ownerRecord.diagnostic) }
        $sessionRecord=@($recovery.records | Where-Object kind -eq 'SESSION')
        if ($sessionRecord.Count) {
            $result.session=if ($sessionRecord[0].status -eq 'VALID') { $sessionRecord[0].effectiveStatus } else { $sessionRecord[0].status }
            if ($sessionRecord[0].diagnostic) { $result.diagnostics+=@($sessionRecord[0].diagnostic) }
        }
    }
    foreach ($run in @($Task.verifications | Where-Object outcome -eq 'RUNNING')) {
        $pending=Get-AiSopRunEvidencePath $SpecDirectory $Task.taskId $run.runId
        $result.runs+=@{runId=$run.runId;activity=(Get-AiSopRunActivity $run $WorkspacePath);pendingResultExists=[IO.File]::Exists($pending);pendingResultPath=[IO.Path]::GetRelativePath($WorkspacePath,$pending).Replace('\','/')}
    }
    if ($result.runs.Count) {
        $result.pendingEvidence=@($recovery.records | Where-Object kind -eq 'PENDING')
        foreach ($pending in @($result.pendingEvidence | Where-Object status -eq 'INVALID')) { $result.diagnostics+=@("PENDING_EVIDENCE_INVALID: $($pending.path): $($pending.diagnostic)") }
    }
    return $result
}

function Get-AiSopHandoffPreflight {
    param([string]$WorkspacePath, [string]$Feature, [string]$TaskId, [string]$TargetEnginePath, [switch]$IncludeHistory)
    $WorkspacePath=Resolve-PhysicalPathIdentity $WorkspacePath
    $Feature=Resolve-AiSopFeatureName $WorkspacePath $Feature
    if ($TaskId -and -not $Feature) { throw 'PREFLIGHT_FEATURE_REQUIRED: select Feature with TaskId' }
    if ($TaskId -and $TaskId -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,79}$') { throw 'TASK_ID_INVALID' }
    $currentEngine=Resolve-PhysicalPathIdentity (Split-Path -Parent $PSScriptRoot)
    $target=if ($TargetEnginePath) { Resolve-PhysicalPathIdentity $TargetEnginePath } else { $currentEngine }
    $issues=[Collections.Generic.List[object]]::new(); $tasks=[Collections.Generic.List[object]]::new()
    $legacyFeatures=[Collections.Generic.List[object]]::new()
    $selectedFeatures=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $artifacts=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $repositories=[Collections.Generic.Dictionary[string,object]]::new([StringComparer]::Ordinal)
    $context=New-AiSopValidationContext
    # Cache file validity separately from each task record's binding to the file.
    $inputChecks=@{}
    $capabilities=$null; $policy=$null; $targetAlgorithm=$null
    try {
        $capPath=Resolve-AiSopWorkspaceChild $target 'config/runtime-compatibility.json'
        $raw=[IO.File]::ReadAllText($capPath)
        if (-not (Test-Json -Json $raw -SchemaFile (Join-Path $currentEngine 'schemas/runtime-compatibility.schema.json') -ErrorAction Stop)) { throw 'invalid descriptor' }
        $capabilities=ConvertFrom-AiSopWorkflowJson $raw -AsHashtable
        $targetTaskSchema=Resolve-AiSopWorkspaceChild $target 'schemas/workflow-task.schema.json'
        if (-not [IO.File]::Exists($targetTaskSchema)) { throw 'target task schema missing' }
        foreach ($name in @('workflow-task.ps1','verification-inputs.ps1')) {
            if (-not [IO.File]::Exists((Resolve-AiSopWorkspaceChild $target "scripts/$name"))) { throw "target engine component missing: $name" }
        }
    } catch { $issues.Add(@{code='ENGINE_COMPATIBILITY_UNKNOWN';detail=$_.Exception.Message}); $capabilities=$null }
    try {
        $policy=Get-AiSopInputPolicy $WorkspacePath
        if ($capabilities) { $targetAlgorithm=if ($policy.digest) { $capabilities.inputAlgorithms.configured } else { $capabilities.inputAlgorithms.unconfigured } }
    } catch { $issues.Add(@{code='INPUT_POLICY_INVALID';detail=$_.Exception.Message}) }
    foreach ($warning in @(Get-AiSopDeploymentWarnings $WorkspacePath)) { $issues.Add(@{code='DEPLOYMENT_WARNING';detail=$warning}) }
    foreach ($name in @('verification-inputs.json','verification-commands.json','junit-case-map.json')) {
        $relative=".ai-workspace/context/$name"
        if ([IO.File]::Exists((Resolve-AiSopWorkspaceChild $WorkspacePath $relative))) { Add-AiSopPreflightArtifact $artifacts $WorkspacePath $relative 'PROJECT_CONTEXT' 'project' $repositories | Out-Null }
    }
    $featuresRoot=Resolve-AiSopWorkspaceChild $WorkspacePath '.ai-workspace/specs/features'
    foreach ($dir in @(Get-ChildItem -LiteralPath $featuresRoot -Directory -ErrorAction SilentlyContinue | Where-Object { -not $Feature -or $_.Name -ceq $Feature } | Sort-Object Name)) {
        $spec=Resolve-AiSopWorkspaceChild $WorkspacePath ".ai-workspace/specs/features/$($dir.Name)"
        $taskRoot=Resolve-AiSopWorkspaceChild $WorkspacePath ".ai-workspace/specs/features/$($dir.Name)/tasks"
        $records=@(Get-ChildItem -LiteralPath $taskRoot -Directory -ErrorAction SilentlyContinue | Where-Object { -not $TaskId -or $_.Name -ceq $TaskId } | Sort-Object Name)
        $selected=$false
        if (-not $records.Count -and -not $TaskId) {
            $selected=$true
            $statePath=Resolve-AiSopTaskWorkflowStatePath $spec
            $statePath=Resolve-AiSopWorkspaceChild $WorkspacePath ([IO.Path]::GetRelativePath($WorkspacePath,$statePath))
            $legacyFeatures.Add(@{feature=$dir.Name;status='LEGACY_UNVERIFIED';workflowStatePath=$(if ([IO.File]::Exists($statePath)) { [IO.Path]::GetRelativePath($WorkspacePath,$statePath).Replace('\','/') } else { $null });recordedApprovals=(Get-AiSopRecordedApprovals $spec)})
            $issues.Add(@{code='LEGACY_FEATURE';detail="$($dir.Name): no task identity; inventory only, not approval or completion verification. Inspect original ownership before explicit adoption; do not create a task automatically"})
        }
        foreach ($entry in $records) {
            $identity="$($dir.Name)/$($entry.Name)"; $task=$null
            $item=@{feature=$dir.Name;taskId=$entry.Name;status='UNAVAILABLE';tier=$null;diagnostics=@();localState=@{owner='NOT_CHECKED';session='NOT_CHECKED';runs=@()}}
            try {
                $task=Read-AiSopTask $spec $entry.Name
                if (-not $IncludeHistory -and -not $TaskId -and $task.status -in @('DONE','CANCELLED') -and -not @($task.followUps | Where-Object status -eq 'PENDING').Count) { continue }
                $item.status=$task.status; $item.tier=$task.tier
                $item.objective=$task.objective; $item.nextAction=$task.nextAction
                $item.startInputsStatus=if ($task.startInputs) { $task.startInputs.status } else { 'LEGACY_UNKNOWN' }
                $item.pendingFollowUps=@($task.followUps | Where-Object status -eq 'PENDING')
            } catch { $item.diagnostics+=@($_.Exception.Message) }
            $selected=$true; $tasks.Add($item)
            $taskArtifact=Add-AiSopPreflightArtifact $artifacts $WorkspacePath ".ai-workspace/specs/features/$($dir.Name)/tasks/$($entry.Name)/task.json" 'TASK' $identity $repositories
            if (-not $task) { $taskArtifact.status='INVALID'; $taskArtifact.diagnostics=$item.diagnostics; continue }
            $active=$task.status -in @('ACTIVE','PAUSED')
            if (-not $active) { $item.localState=@{owner='NOT_APPLICABLE';session='NOT_APPLICABLE';runs=@()} }
            if ($capabilities) {
                try {
                    if ($task.schemaVersion -cnotin $capabilities.taskSchemaVersions -or -not (Test-Json -Json (ConvertTo-AiSopWorkflowCanonicalJson $task) -SchemaFile $targetTaskSchema -ErrorAction Stop)) { throw 'task format unsupported' }
                } catch { $item.diagnostics+=@("TARGET_TASK_INCOMPATIBLE: $($_.Exception.Message)") }
            }
            $references=@(@{label='startInputs';record=$task.startInputs},@{label='baseline';record=$task.baseline})
            for ($index=0; $index -lt @($task.verifications).Count; $index++) {
                $run=$task.verifications[$index]
                $references+=@{label="verifications[$index] $($run.kind)/$($run.batch) run=$($run.runId)";record=$run}
            }
            foreach ($reference in $references) {
                $record=$reference.record
                if (-not $record.inputsRef) { continue }
                $relative=".ai-workspace/specs/.artifacts/inputs/$($record.inputsRef).json"
                $artifact=Add-AiSopPreflightArtifact $artifacts $WorkspacePath $relative 'INPUT_MANIFEST' $identity $repositories
                if (-not $inputChecks.ContainsKey($record.inputsRef)) {
                    try { $inputChecks[$record.inputsRef]=@{snapshot=(Read-AiSopInputManifest $record.inputsRef $WorkspacePath $context)} }
                    catch { $inputChecks[$record.inputsRef]=@{error=$_.Exception.Message} }
                }
                $check=$inputChecks[$record.inputsRef]
                if ($check.error) {
                    $artifact.status=if ($artifact.status -eq 'MISSING') { 'MISSING' } else { 'INVALID' }
                    $artifact.diagnostics=@($check.error)
                    continue
                }
                $snapshot=$check.snapshot; $artifact.status='VALID'
                if ($snapshot.digest -cne $record.inputDigest) {
                    $item.diagnostics+=@("INPUT_MANIFEST_DIGEST_MISMATCH: $($reference.label) references $($record.inputsRef); file is valid, record inputDigest does not match")
                }
                if ($capabilities -and $snapshot.algorithm -cnotin $capabilities.readableInputAlgorithms) { $item.diagnostics+=@("TARGET_INPUT_FORMAT_UNSUPPORTED: $($record.inputsRef) $($snapshot.algorithm)") }
            }
            if ($task.impactReview.changeSetDigest) {
                $ref=$task.impactReview.changeSetDigest
                $artifact=Add-AiSopPreflightArtifact $artifacts $WorkspacePath ".ai-workspace/specs/.artifacts/changes/$ref.json" 'CHANGE_MANIFEST' $identity $repositories
                $change=$null
                try {
                    $raw=[IO.File]::ReadAllText((Resolve-AiSopWorkspaceChild $WorkspacePath $artifact.path))
                    if ((Get-AiSopWorkflowSha256 $raw) -cne $ref -or -not (Test-Json -Json $raw -SchemaFile (Join-Path $currentEngine 'schemas/task-change-manifest.schema.json') -ErrorAction Stop)) { throw 'TASK_CHANGE_MANIFEST_CORRUPT' }
                    $parsed=ConvertFrom-AiSopWorkflowJson $raw -AsHashtable
                    $paths=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                    foreach ($entryChange in $parsed.changes) {
                        Resolve-AiSopWorkspaceChild $WorkspacePath $entryChange.path | Out-Null
                        if (-not $paths.Add($entryChange.path) -or $entryChange.before -ceq $entryChange.after) { throw 'TASK_CHANGE_MANIFEST_CORRUPT: duplicate path or unchanged entry' }
                    }
                    $change=$parsed
                    $artifact.status='VALID'
                } catch { $artifact.status=if ($artifact.status -eq 'MISSING') { 'MISSING' } else { 'INVALID' }; $artifact.diagnostics=@($_.Exception.Message) }
                if ($change -and ($change.taskId -cne $task.taskId -or $change.feature -cne $task.feature -or
                    $change.baselineRef -cne $task.baseline.inputsRef -or $change.baselineInputDigest -cne $task.baseline.inputDigest)) {
                    $item.diagnostics+=@("TASK_CHANGE_MANIFEST_BINDING_MISMATCH: impactReview references $ref; file is valid, task/feature/baseline binding does not match")
                }
            }
            if ($active) {
                if ($task.startInputs.status -eq 'CAPTURED' -and $targetAlgorithm -and $task.tier -ne 'T3') {
                    try {
                        $origin=Read-AiSopTaskStartInputs $task $WorkspacePath $context
                        if ($origin.algorithm -cne $targetAlgorithm -or [string]$origin.policyDigest -cne [string]$policy.digest) { $item.diagnostics+=@('START_INPUT_POLICY_MISMATCH: normal tier verification remains available, but this origin cannot support NOT_APPLICABLE or T3 scope under the target input policy') }
                    } catch { $item.diagnostics+=@($_.Exception.Message) }
                }
                if ($task.tier -eq 'T3') {
                    try {
                        $baseline=Read-AiSopTaskBaselineInputs $task $WorkspacePath $context
                        if ($targetAlgorithm -and ($baseline.algorithm -cne $targetAlgorithm -or [string]$baseline.policyDigest -cne [string]$policy.digest)) { $item.diagnostics+=@('TARGET_BASELINE_INCOMPATIBLE: finish with the original engine/input policy before upgrading; do not replace the baseline') }
                    } catch { $item.diagnostics+=@($_.Exception.Message) }
                }
                foreach ($record in @($task.verifications | Group-Object kind,batch | ForEach-Object { @($_.Group)[-1] })) {
                    $item.diagnostics+=@(Get-AiSopRunDefinitionProblems $record $WorkspacePath)
                    if ($capabilities -and $record.context.profileDigestAlgorithm -and $record.context.profileDigestAlgorithm -cnotin $capabilities.verificationDefinitionBindings) { $item.diagnostics+=@('TARGET_DEFINITION_BINDING_UNSUPPORTED: selected Profile semantics are not supported by the target engine') }
                    if ($record.context.profile) {
                        Add-AiSopPreflightArtifact $artifacts $WorkspacePath '.ai-workspace/context/verification-commands.json' 'VERIFICATION_DEFINITION' $identity $repositories | Out-Null
                    }
                    if ($record.context.junitConfiguration) {
                        try {
                            $mapping=ConvertFrom-AiSopWorkflowJson $record.context.junitConfiguration -AsHashtable
                            if ($capabilities -and $mapping.bindingVersion -and $mapping.bindingVersion -cnotin $capabilities.verificationDefinitionBindings) { $item.diagnostics+=@('TARGET_DEFINITION_BINDING_UNSUPPORTED: current JUnit map binding is not supported by the target engine') }
                            if ($mapping.mapPath) { Add-AiSopPreflightArtifact $artifacts $WorkspacePath $mapping.mapPath 'VERIFICATION_DEFINITION' $identity $repositories | Out-Null }
                        } catch { $item.diagnostics+=@("JUNIT_DEFINITION_UNAVAILABLE: $($_.Exception.Message)") }
                    }
                    if ($record.inputsRef -and $targetAlgorithm) {
                        try {
                            $snapshot=Read-AiSopVerificationInputs $record $WorkspacePath $context
                            if ($snapshot.algorithm -cne $targetAlgorithm -or [string]$snapshot.policyDigest -cne [string]$policy.digest) { $item.diagnostics+=@("EVIDENCE_POLICY_MISMATCH: $($record.kind)/$($record.batch) will require verification under the target engine/input policy") }
                        } catch { } # File errors and per-record binding errors were reported above.
                    }
                }
                try {
                    $item.localState=Get-AiSopPreflightLocalState $task $spec $WorkspacePath
                    $item.diagnostics+=@($item.localState.diagnostics)
                    foreach ($run in $item.localState.runs) { $item.diagnostics+=@("RUN_UNFINISHED: $($run.runId) $($run.activity); stop/finish on the original workspace and settle pending evidence before moving or upgrading") }
                    if ($item.localState.owner -ne 'ACTIVE' -and $task.status -eq 'ACTIVE') { $item.diagnostics+=@('LOCAL_OWNERSHIP_UNAVAILABLE: inspect/recover local ownership before Resume; never copy another workspace session registry') }
                    if ($item.localState.owner -eq 'ACTIVE' -and $item.localState.session -in @('MISSING','ENDED','EXPIRED')) { $item.diagnostics+=@('SESSION_REBIND_REQUIRED: use the normal Resume/Recover flow; preflight does not renew sessions') }
                } catch { $item.diagnostics+=@("LOCAL_STATE_UNAVAILABLE: $($_.Exception.Message)") }
                foreach ($record in @($task.verifications | Where-Object outcome -eq 'RUNNING')) {
                    if ($capabilities -and $record.context.protocol -cnotin $capabilities.verificationProtocols) { $item.diagnostics+=@('TARGET_RUN_PROTOCOL_UNSUPPORTED') }
                }
            }
        }
        if ($selected) {
            $selectedFeatures.Add($dir.Name) | Out-Null
            foreach ($file in @(Get-ChildItem -LiteralPath $spec -File | Sort-Object Name)) {
                Add-AiSopPreflightArtifact $artifacts $WorkspacePath ".ai-workspace/specs/features/$($dir.Name)/$($file.Name)" 'FEATURE_SPEC' $dir.Name $repositories | Out-Null
            }
        }
    }
    if (-not $tasks.Count -and -not $legacyFeatures.Count -and ($Feature -or $TaskId)) { $issues.Add(@{code='TASK_SELECTION_EMPTY';detail='No matching task records; check Feature/TaskId or use IncludeHistory for terminal tasks'}) }
    # Journals are local authority, never a portable handoff artifact. Merely
    # report them; session getters would replay them and violate read-only use.
    $txRoot=Resolve-PhysicalPathIdentity (Get-AiSopWorkflowTransactionRegistryRoot -WorkspacePath $WorkspacePath)
    foreach ($journal in @(Get-ChildItem -LiteralPath $txRoot -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        $issues.Add(@{code='LOCAL_TRANSACTION_PENDING';detail="$($journal.FullName): resolve transaction recovery on the original workspace before handoff or upgrade"})
    }
    foreach ($item in $tasks) {
        $item.diagnostics=@($item.diagnostics | Select-Object -Unique)
        foreach ($diagnostic in $item.diagnostics) { $issues.Add(@{code='TASK_ATTENTION';detail="$($item.feature)/$($item.taskId): $diagnostic"}) }
    }
    foreach ($artifact in $artifacts.Values) {
        if ($artifact.status -in @('MISSING','INVALID')) { $issues.Add(@{code='ARTIFACT_UNAVAILABLE';detail="$($artifact.path): $($artifact.status) $($artifact.diagnostics -join '; ')"}) }
        if ($artifact.tracking -ne 'TRACKED' -or $artifact.dirty) { $issues.Add(@{code='SYNC_REQUIRED';detail="$($artifact.path): $($artifact.tracking) dirty=$($artifact.dirty); sync using its owning repository or an explicit file transfer"}) }
    }
    return [ordered]@{
        schemaVersion='1.0';readOnly=$true;workspace=$WorkspacePath;status=$(if ($issues.Count) { 'NEEDS_ATTENTION' } else { 'NO_ISSUES_DETECTED' })
        engine=@{inspector=$currentEngine;target=$target;repository=(Get-AiSopPreflightRepository (Join-Path $target 'config/runtime-compatibility.json') $repositories);capabilities=$capabilities;expectedInputAlgorithm=$targetAlgorithm}
        tasks=$tasks.ToArray();legacyFeatures=$legacyFeatures.ToArray();artifacts=@($artifacts.Values | Sort-Object path);issues=$issues.ToArray()
        syncRoots=@('.ai-workspace/context/')+@($selectedFeatures | Sort-Object | ForEach-Object { ".ai-workspace/specs/features/$_/" })+@(
            if (@($artifacts.Values | Where-Object { $_.kind -in @('INPUT_MANIFEST','CHANGE_MANIFEST') }).Count) { '.ai-workspace/specs/.artifacts/' }
        )
        notes=@('Advisory preflight, not a completion gate. No business-input hashes, tests, locks or transaction recovery were run. Recheck after stopping edits; this is not an atomic snapshot.',
            'Sync the feature specifications and task records, referenced specs/.artifacts manifests, project context and matching source revision. The repository column identifies nested Git owners; tracked files may still need commit/push/fetch. Remote reachability and target source equality are not checked.',
            'Local ownership, sessions, transaction journals and .ai-workspace/.runtime logs stay on their original machine/workspace. Resolve unfinished runs there, then Suspend or use deliberate Resume/Recover at the destination.',
            'Target compatibility is based on its local declaration and task schema, without executing it. Omit TargetEnginePath to check only the currently running engine; this does not certify an unspecified future upgrade.')
    }
}

function Write-AiSopHandoffPreflight {
    param($Report, [switch]$Json)
    if ($Json) { $Report | ConvertTo-Json -Depth 25; return }
    Write-Output "Preflight (read-only): $($Report.status) — $($Report.workspace)"
    Write-Output "  target=$($Report.engine.target) inputAlgorithm=$($Report.engine.expectedInputAlgorithm)"
    foreach ($task in $Report.tasks) {
        Write-Output "  [$($task.status)] $($task.feature)/$($task.taskId) $($task.tier) owner=$($task.localState.owner) session=$($task.localState.session)"
        Write-Output "    objective=$($task.objective); checkpoint=$($task.nextAction); startInputs=$($task.startInputsStatus)"
        foreach ($followUp in $task.pendingFollowUps) { Write-Output "    follow-up (non-blocking): $($followUp.summary)" }
    }
    foreach ($legacy in $Report.legacyFeatures) {
        Write-Output "  [LEGACY_UNVERIFIED] $($legacy.feature) state=$($legacy.workflowStatePath); no taskId, inventory only"
    }
    foreach ($root in $Report.syncRoots) { Write-Output "  sync tree: $root (includes project-specific references and attachments)" }
    foreach ($artifact in $Report.artifacts) { Write-Output "  sync: $($artifact.path) [$($artifact.status), $($artifact.tracking), dirty=$($artifact.dirty)] repo=$($artifact.repository.root)" }
    foreach ($issue in $Report.issues) { Write-Output "  ! $($issue.code): $($issue.detail)" }
    foreach ($note in $Report.notes) { Write-Output "  $note" }
}
