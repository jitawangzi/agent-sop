#requires -Version 7.0
$ErrorActionPreference='Stop'
$scripts=Split-Path -Parent $PSScriptRoot
$engine=Split-Path -Parent $scripts
. (Join-Path $scripts 'task-context.ps1')
. (Join-Path $scripts 'workflow-session.ps1')
. (Join-Path $scripts 'handoff-preflight.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('sop-preflight-'+[guid]::NewGuid().ToString('N'))
$workspace=Join-Path $root 'workspace'
$saved=@{}
foreach ($key in @('AI_SOP_OWNER_REGISTRY','AI_SOP_SESSION_REGISTRY','AI_SOP_COMMAND_GRANT_REGISTRY','AI_SOP_TRANSACTION_REGISTRY','CODEX_SESSION_ID')) { $saved[$key]=[Environment]::GetEnvironmentVariable($key) }
function Assert($condition,[string]$message) { if (-not $condition) { throw $message } }
function Put([string]$path,[string]$text) {
    $full=Join-Path $workspace $path
    [IO.Directory]::CreateDirectory((Split-Path -Parent $full)) | Out-Null
    [IO.File]::WriteAllText($full,$text)
}
function SaveTask($task) { Put ".ai-workspace/specs/features/$($task.feature)/tasks/$($task.taskId)/task.json" (ConvertTo-AiSopWorkflowCanonicalJson $task) }
function MakeTask([string]$feature,[string]$id,[string]$tier='T3',[string]$status='PAUSED') {
    $at=[DateTimeOffset]::UtcNow.ToString('o')
    return @{schemaVersion='1.0';feature=$feature;taskId=$id;ownerId="task-$id";tier=$tier;status=$status;objective='Preflight fixture';nextAction='Continue';notes='';createdAt=$at;updatedAt=$at;requiredCaseIds=@();verifications=@()
        startInputs=@{status='CAPTURED';taskId=$id;feature=$feature;createdAt=$at;transactionId=('claim-'+('a'*32));mode='FULL';inputsRef=$ref;inputDigest=$snapshot.digest}
        baseline=@{vcs='none';revision='0';capturedAt=$at;source='START';inputsRef=$ref;inputDigest=$snapshot.digest}}
}
function InitRepo([string]$path) {
    & git -C $path init --quiet 2>$null
    if ($LASTEXITCODE -ne 0) { throw 'git init failed' }
}
function CommitRepo([string]$path) {
    & git -C $path add --all
    & git -C $path -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet -m fixture
    if ($LASTEXITCODE -ne 0) { throw 'fixture git commit failed' }
}
function TreeHash {
    return (@(Get-ChildItem -LiteralPath $root -File -Recurse -Force | Sort-Object FullName | ForEach-Object { $_.FullName+':'+(Get-FileHash -LiteralPath $_.FullName).Hash }) -join "`n")
}
try {
    foreach ($kind in @('OWNER','SESSION','COMMAND_GRANT','TRANSACTION')) { [Environment]::SetEnvironmentVariable("AI_SOP_${kind}_REGISTRY",(Join-Path $root $kind)) }
    Put 'src/main.txt' 'source'
    Put '.ai-workspace/.gitignore' "specs/`n.runtime/`n"
    Put '.ai-workspace/context/verification-inputs.json' '{"schemaVersion":"1.0","include":[],"exclude":[]}'
    Put '.ai-workspace/specs/features/Example/06_design_contract.md' 'design'
    InitRepo (Join-Path $workspace '.ai-workspace')
    InitRepo (Join-Path $workspace '.ai-workspace/specs')
    $snapshot=Get-AiSopInputSnapshot $workspace
    $ref=Save-AiSopInputManifest $snapshot $workspace
    $one=MakeTask Example one; $two=MakeTask Other two; $done=MakeTask Example done T3 DONE
    SaveTask $one; SaveTask $two; SaveTask $done
    CommitRepo (Join-Path $workspace '.ai-workspace')
    CommitRepo (Join-Path $workspace '.ai-workspace/specs')
    # Make business-input reads and transaction recovery fatal. A read-only
    # preflight must only read state/manifests, and must never acquire authority.
    function Get-AiSopInputSnapshot { throw 'UNEXPECTED_BUSINESS_SCAN' }
    function Invoke-AiSopWorkflowTransactionRecovery { throw 'UNEXPECTED_RECOVERY' }
    function Enter-AiSopWorkflowFileLock { throw 'UNEXPECTED_LOCK' }
    $before=TreeHash
    $report=Get-AiSopHandoffPreflight $workspace
    Assert ($report.status -eq 'NO_ISSUES_DETECTED' -and $report.tasks.Count -eq 2) 'Valid paused tasks were not inspectable'
    $manifest=@($report.artifacts | Where-Object kind -eq 'INPUT_MANIFEST')
    Assert ($manifest.Count -eq 1 -and $manifest[0].requiredBy.Count -eq 2) 'Shared manifest references were not deduplicated'
    Assert ('.ai-workspace/specs/.artifacts/' -in $report.syncRoots) 'Sync roots omitted the shared immutable manifests'
    Assert ($manifest[0].repository.root -ceq (Resolve-PhysicalPathIdentity (Join-Path $workspace '.ai-workspace/specs')) -and $manifest[0].tracking -eq 'TRACKED') 'Nested specs repository ownership used the parent ignore rule'
    $config=$report.artifacts | Where-Object kind -eq 'PROJECT_CONTEXT'
    Assert ($config.repository.root -ceq (Resolve-PhysicalPathIdentity (Join-Path $workspace '.ai-workspace'))) 'Project context assigned to specs repository'
    Assert ($before -ceq (TreeHash)) 'Preflight wrote workspace, Git or registry files'
    Put '.ai-workspace/specs/features/Legacy/workflow-state.json' '{"requirement":{"status":"APPROVED"},"design":{"status":"DRAFT"}}'
    Put '.ai-workspace/specs/features/Legacy/06_design_contract.md' 'legacy design'
    Put '.ai-workspace/specs/features/Legacy/.workflow-owner.json' '{"ownerId":"historical-only"}'
    $before=TreeHash
    $legacy=Get-AiSopHandoffPreflight $workspace Legacy
    Assert ($legacy.tasks.Count -eq 0 -and $legacy.legacyFeatures.Count -eq 1 -and $legacy.legacyFeatures[0].status -eq 'LEGACY_UNVERIFIED') 'Legacy inventory invented task identity or omitted the feature'
    Assert ($legacy.legacyFeatures[0].workflowStatePath -like '*/workflow-state.json' -and $legacy.legacyFeatures[0].recordedApprovals.requirement -eq 'APPROVED') 'Legacy state fallback was lost'
    Assert ('.ai-workspace/specs/features/Legacy/' -in $legacy.syncRoots -and @($legacy.artifacts | Where-Object kind -eq 'FEATURE_SPEC').Count -eq 3) 'Legacy feature specs or sync root missing'
    Assert (@($legacy.issues | Where-Object code -eq 'TASK_SELECTION_EMPTY').Count -eq 0 -and @($legacy.issues | Where-Object code -eq 'LEGACY_FEATURE').Count -eq 1) 'Legacy selection was mislabeled as missing task'
    Assert (@($legacy.artifacts | Where-Object { $_.kind -eq 'FEATURE_SPEC' -and $_.tracking -eq 'UNTRACKED' -and $_.repository.root -eq (Resolve-PhysicalPathIdentity (Join-Path $workspace '.ai-workspace/specs')) }).Count -eq 3) 'Legacy artifacts lost nested repository ownership or sync warnings'
    $humanLegacy=Write-AiSopHandoffPreflight $legacy | Out-String
    Assert ($humanLegacy -match 'LEGACY_UNVERIFIED' -and $humanLegacy -match 'inventory only') 'Human output implies legacy feature is verified'
    Assert ($before -ceq (TreeHash)) 'Legacy inventory mutated feature, owner or repository'
    Put '.ai-workspace/specs/features/Legacy/00_workflow_state.json' '{broken'
    $invalidLegacy=Get-AiSopHandoffPreflight $workspace Legacy
    Assert ($invalidLegacy.legacyFeatures[0].workflowStatePath -like '*/00_workflow_state.json' -and $invalidLegacy.legacyFeatures[0].recordedApprovals.requirement -eq 'UNAVAILABLE') 'Corrupt primary legacy state fell back to old approval'
    $missingTask=Get-AiSopHandoffPreflight $workspace Legacy absent
    Assert ($missingTask.legacyFeatures.Count -eq 0 -and @($missingTask.issues | Where-Object code -eq 'TASK_SELECTION_EMPTY').Count -eq 1) 'Explicit missing TaskId silently selected legacy feature instead'
    $allFeatures=Get-AiSopHandoffPreflight $workspace
    Assert ($allFeatures.tasks.Count -eq 2 -and $allFeatures.legacyFeatures.Count -eq 1) 'Mixed legacy/task inventory lost an independent feature'
    $one.verifications=@(@{kind='compile';batch='binding';command='fixture';exitCode=0;executedAt=[DateTimeOffset]::UtcNow.ToString('o');inputDigest=('f'*64);inputsRef=$ref;inputsStable=$true;caseIds=@();runId=('c'*32);outcome='PASSED';context=@{protocol='2'}})
    SaveTask $one
    $before=TreeHash
    $binding=Get-AiSopHandoffPreflight $workspace
    $shared=@($binding.artifacts | Where-Object kind -eq 'INPUT_MANIFEST')[0]
    Assert ($shared.status -eq 'VALID' -and $shared.diagnostics.Count -eq 0 -and $shared.requiredBy.Count -eq 2) 'One bad reference contaminated a shared valid manifest'
    Assert ((@($binding.tasks | Where-Object taskId -eq 'one')[0].diagnostics -join ' ') -match 'INPUT_MANIFEST_DIGEST_MISMATCH: verifications\[0\] compile/binding') 'Binding error did not identify the exact task record'
    Assert (@($binding.tasks | Where-Object taskId -eq 'two')[0].diagnostics.Count -eq 0) 'Bad reference blamed another task'
    Assert ($before -ceq (TreeHash)) 'Binding diagnostics mutated the task or manifest'
    $one.verifications=@(); SaveTask $one
    # The file can be valid while its baseline binding to this task is wrong.
    $change=@{schemaVersion='1.0';taskId='one';feature='Example';baselineRef=$ref;baselineInputDigest=('f'*64);changes=@()}
    $changeRaw=ConvertTo-AiSopWorkflowCanonicalJson $change; $changeRef=Get-AiSopWorkflowSha256 $changeRaw
    Put ".ai-workspace/specs/.artifacts/changes/$changeRef.json" $changeRaw
    $one.impactReview=@{artifactHash=('a'*64);inputDigest=$snapshot.digest;reviewedAt=[DateTimeOffset]::UtcNow.ToString('o');changeSetDigest=$changeRef}; SaveTask $one
    $changeBinding=Get-AiSopHandoffPreflight $workspace Example one
    Assert ('.ai-workspace/specs/.artifacts/' -in $changeBinding.syncRoots) 'Change manifests omitted from directory sync plan'
    Assert (@($changeBinding.artifacts | Where-Object kind -eq 'CHANGE_MANIFEST')[0].status -eq 'VALID' -and ($changeBinding.tasks[0].diagnostics -join ' ') -match 'TASK_CHANGE_MANIFEST_BINDING_MISMATCH') 'Change baseline mismatch was missed or blamed on valid file content'
    $change.changes=@('not-a-change-object')
    $changeRaw=ConvertTo-AiSopWorkflowCanonicalJson $change; $changeRef=Get-AiSopWorkflowSha256 $changeRaw
    Put ".ai-workspace/specs/.artifacts/changes/$changeRef.json" $changeRaw
    $one.impactReview.changeSetDigest=$changeRef; SaveTask $one
    $badShape=Get-AiSopHandoffPreflight $workspace Example one
    Assert (@($badShape.artifacts | Where-Object kind -eq 'CHANGE_MANIFEST')[0].status -eq 'INVALID') 'Valid content hash hid invalid change array structure'
    $one.Remove('impactReview'); SaveTask $one
    $manifestPath=Get-AiSopInputManifestPath $workspace $ref
    $manifestRaw=[IO.File]::ReadAllText($manifestPath)
    [IO.File]::Delete($manifestPath)
    $missing=Get-AiSopHandoffPreflight $workspace Example one
    Assert (@($missing.artifacts | Where-Object status -eq 'MISSING').Count -eq 1 -and ($missing.issues.detail -join ' ') -match 'INPUT_MANIFEST_MISSING') 'Missing reference not inventoried'
    Assert (@($missing.artifacts | Where-Object kind -eq 'INPUT_MANIFEST')[0].diagnostics.Count -eq 1) 'Shared start/baseline reference repeated the same missing-file error'
    [IO.File]::WriteAllText($manifestPath,'{}')
    $corrupt=Get-AiSopHandoffPreflight $workspace Example one
    Assert (@($corrupt.artifacts | Where-Object status -eq 'INVALID').Count -eq 1) 'Corrupt reference was accepted'
    Assert (@($corrupt.artifacts | Where-Object kind -eq 'INPUT_MANIFEST')[0].diagnostics.Count -eq 1) 'Corrupt file diagnostic was repeated for every reference'
    [IO.File]::WriteAllText($manifestPath,$manifestRaw)
    $candidate=Join-Path $root 'candidate'
    [IO.Directory]::CreateDirectory($candidate) | Out-Null
    foreach ($dir in @('config','schemas','scripts')) { Copy-Item -LiteralPath (Join-Path $engine $dir) -Destination $candidate -Recurse }
    $capPath=Join-Path $candidate 'config/runtime-compatibility.json'
    $caps=ConvertFrom-AiSopWorkflowJson ([IO.File]::ReadAllText($capPath)) -AsHashtable
    $caps.inputAlgorithms.configured='inputs-next'
    [IO.File]::WriteAllText($capPath,($caps | ConvertTo-Json -Depth 6))
    $upgrade=Get-AiSopHandoffPreflight $workspace Example one $candidate
    Assert (($upgrade.issues.detail -join ' ') -match 'TARGET_BASELINE_INCOMPATIBLE') 'Target input-algorithm incompatibility missed'
    $history=Get-AiSopHandoffPreflight $workspace Example done $candidate
    Assert (-not (($history.issues.detail -join ' ') -match 'TARGET_BASELINE_INCOMPATIBLE')) 'Terminal task was revalidated against target current-input policy'
    Assert ($history.tasks[0].localState.owner -eq 'NOT_APPLICABLE' -and $history.tasks[0].localState.session -eq 'NOT_APPLICABLE') 'Historical ownership printed as an unexplained empty field'
    $unknown=Get-AiSopHandoffPreflight $workspace Example one (Join-Path $root 'missing-engine')
    Assert (@($unknown.issues | Where-Object code -eq 'ENGINE_COMPATIBILITY_UNKNOWN').Count -eq 1) 'Unknown target engine presented as compatible'
    Put '.ai-workspace/context/verification-commands.json' '{"schemaVersion":"1.0","commands":{"build":{"kind":"compile","executable":"pwsh","arguments":["-NoProfile","-Command","exit 0"]}}}'
    $profile=Get-AiSopVerificationProfile $workspace build
    $one.verifications=@(@{kind='compile';batch='build';command='fixture';exitCode=0;executedAt=[DateTimeOffset]::UtcNow.ToString('o');inputDigest=$snapshot.digest;inputsRef=$ref;inputsStable=$true;caseIds=@();runId=('d'*32);outcome='PASSED';context=@{profile='build';profileDigest=$profile.digest;profileDigestAlgorithm=$profile.digestAlgorithm}})
    SaveTask $one
    $caps.Remove('verificationDefinitionBindings'); [IO.File]::WriteAllText($capPath,($caps | ConvertTo-Json -Depth 6))
    $oldTarget=Get-AiSopHandoffPreflight $workspace Example one $candidate
    Assert (($oldTarget.tasks[0].diagnostics -join ' ') -match 'TARGET_DEFINITION_BINDING_UNSUPPORTED') 'Older target was reported capable of current definition checks'
    Put '.ai-workspace/context/verification-commands.json' '{"schemaVersion":"1.0","commands":{"build":{"kind":"compile","executable":"pwsh","arguments":["-NoProfile","-Command","exit 2"]}}}'
    $drift=Get-AiSopHandoffPreflight $workspace Example one
    Assert (($drift.tasks[0].diagnostics -join ' ') -match 'STALE_PROFILE_EVIDENCE') 'Preflight missed selected definition drift'
    Assert (@($drift.artifacts | Where-Object { $_.path -eq '.ai-workspace/context/verification-commands.json' -and 'Example/one' -in $_.requiredBy }).Count -eq 1) 'Profile source was not assigned to the referencing task'
    $one.verifications=@(); SaveTask $one
    $old=ConvertFrom-AiSopWorkflowJson (ConvertTo-AiSopWorkflowCanonicalJson $one) -AsHashtable
    $old.Remove('startInputs'); $old.baseline.source='ADOPTED'; SaveTask $old
    $adopted=Get-AiSopHandoffPreflight $workspace Example one
    Assert (($adopted.issues.detail -join ' ') -match 'TASK_BASELINE_SOURCE_UNVERIFIED') 'Legacy adopted baseline not reported'
    SaveTask $one
    $env:CODEX_SESSION_ID='preflight-session'
    & (Get-Process -Id $PID).Path -NoProfile -File (Join-Path $scripts 'workflow-task.ps1') -Operation Start -WorkspacePath $workspace -Feature Live -TaskId live -Tier T1 -Objective 'Live preflight fixture' -Agent CODEX | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'Live session fixture failed'
    $before=TreeHash
    $live=Get-AiSopHandoffPreflight $workspace Live live
    Assert ($live.tasks[0].localState.owner -eq 'ACTIVE' -and $live.tasks[0].localState.session -in @('ACTIVE','IDLE') -and -not $live.tasks[0].diagnostics.Count) 'Live session was not read without recovery or locks'
    Assert ($before -ceq (TreeHash)) 'Preflight changed a live session/registry'
    $one.status='ACTIVE'; $runId='b'*32
    $one.verifications=@(@{kind='compile';batch='main';command='fixture';exitCode=-2;executedAt=[DateTimeOffset]::UtcNow.ToString('o');inputDigest=$snapshot.digest;inputsRef=$ref;inputsStable=$false;caseIds=@();runId=$runId;outcome='RUNNING';context=@{runnerMachine='FOREIGN';workspace='foreign';protocol='2'}})
    SaveTask $one
    Put ".ai-workspace/specs/features/Example/tasks/one/$runId.pending.json" '{broken'
    [IO.Directory]::CreateDirectory($env:AI_SOP_TRANSACTION_REGISTRY) | Out-Null
    [IO.File]::WriteAllText((Join-Path $env:AI_SOP_TRANSACTION_REGISTRY 'pending.json'),'{unresolved')
    $before=TreeHash
    $running=Get-AiSopHandoffPreflight $workspace Example one
    Assert (($running.issues.detail -join ' ') -match 'RUN_UNFINISHED' -and ($running.issues.detail -join ' ') -match 'PENDING_EVIDENCE_INVALID') 'Interrupted run or damaged pending evidence not reported'
    Assert (@($running.issues | Where-Object code -eq 'LOCAL_TRANSACTION_PENDING').Count -eq 1) 'Pending transaction not surfaced'
    Assert ($before -ceq (TreeHash)) 'Preflight recovered/changed a pending transaction or run'
    Put '.ai-workspace/specs/features/Example/tasks/damaged/task.json' '{broken'
    $damaged=Get-AiSopHandoffPreflight $workspace Example
    Assert (@($damaged.tasks | Where-Object status -eq 'UNAVAILABLE').Count -eq 1 -and @($damaged.tasks | Where-Object taskId -eq 'one').Count -eq 1) 'Damaged task hid other tasks'
    Assert (@($damaged.tasks | Where-Object taskId -eq 'damaged')[0].localState.owner -eq 'NOT_CHECKED') 'Unreadable task claimed local ownership was checked'
    Put '.ai-workspace/specs/.gitignore' '.artifacts/'
    & git -C (Join-Path $workspace '.ai-workspace/specs') rm --cached --quiet -- ".artifacts/inputs/$ref.json"
    $ignored=Get-AiSopHandoffPreflight $workspace Other two
    Assert (@($ignored.artifacts | Where-Object tracking -eq 'IGNORED').Count -eq 1) 'Ignored artifact in owning specs repository missed'
    [IO.Directory]::CreateDirectory((Join-Path $workspace '.ai-sop')) | Out-Null
    foreach ($dir in @('scripts','schemas','config')) { Copy-Item -LiteralPath (Join-Path $engine $dir) -Destination (Join-Path $workspace '.ai-sop') -Recurse }
    Copy-Item -LiteralPath (Join-Path $engine 'distribution/templates/root/ai-sop.ps1') -Destination (Join-Path $workspace 'ai-sop.ps1')
    $json=& (Join-Path $workspace 'ai-sop.ps1') Preflight -Feature Other -TaskId two -Json | ConvertFrom-Json -AsHashtable
    Assert ($LASTEXITCODE -eq 0 -and $json.readOnly -and $json.tasks.Count -eq 1 -and $json.status -eq 'NEEDS_ATTENTION') 'Root Preflight did not emit advisory JSON with success exit status'
    $human=& (Join-Path $workspace 'ai-sop.ps1') Preflight -Feature Other -TaskId two | Out-String
    Assert ($LASTEXITCODE -eq 0 -and $human -match 'sync tree' -and $human -match 'read-only') 'Human preflight output missing inventory'
    Write-Output 'handoff-preflight.tests PASS'
} finally {
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key,$saved[$key]) }
    $resolved=[IO.Path]::GetFullPath($root)
    $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if ($resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'sop-preflight-*') { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue }
}
