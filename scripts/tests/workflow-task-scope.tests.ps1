#requires -Version 7.0
$ErrorActionPreference='Stop'
$scripts=Split-Path -Parent $PSScriptRoot
. (Join-Path $scripts 'task-context.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('sop-task-scope-' + [guid]::NewGuid().ToString('N'))
$workspace=Join-Path $root 'workspace'
$spec=Join-Path $workspace '.ai-workspace/specs/features/Example'
$entry=Join-Path $scripts 'workflow-task.ps1'
$saved=@{}
foreach ($key in @('AI_SOP_OWNER_REGISTRY','AI_SOP_SESSION_REGISTRY','AI_SOP_COMMAND_GRANT_REGISTRY','AI_SOP_TRANSACTION_REGISTRY','SERVER_NEW_WORKFLOW_OWNER_DEADLINE_MS','CODEX_SESSION_ID')) { $saved[$key]=[Environment]::GetEnvironmentVariable($key) }
function Assert($condition,[string]$message) { if (-not $condition) { throw $message } }
function Fails([scriptblock]$action,[string]$pattern) {
    $failure=''
    try { & $action | Out-Null; if ($LASTEXITCODE -ne 0) { $failure="exit=$LASTEXITCODE" } } catch { $failure=$_.Exception.Message }
    Assert ($failure -match $pattern) "Expected $pattern; got $failure"
}
function Put([string]$relative,[string]$text) {
    $path=Join-Path $workspace $relative
    [IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
    [IO.File]::WriteAllText($path,$text)
}
function Task([string]$op,[string]$id='one',[hashtable]$extra=@{}) {
    & $entry -Operation $op -WorkspacePath $workspace -Feature Example -TaskId $id -Agent CODEX @extra
    if ($LASTEXITCODE -ne 0) { throw "Task $op failed: $LASTEXITCODE" }
}
try {
    foreach ($kind in @('OWNER','SESSION','COMMAND_GRANT','TRANSACTION')) { [Environment]::SetEnvironmentVariable("AI_SOP_${kind}_REGISTRY",(Join-Path $root $kind)) }
    $env:SERVER_NEW_WORKFLOW_OWNER_DEADLINE_MS='15000'; $env:CODEX_SESSION_ID='scope-session'
    [IO.Directory]::CreateDirectory($spec) | Out-Null
    Put 'src/inherited.txt' 'committed'; Put 'src/current.txt' 'before'; Put 'src/deleted.txt' 'before'
    Put 'tests/check.ps1' 'if (1 -ne 1) { throw "bad" }'
    git -C $workspace init -b main --quiet
    git -C $workspace add src tests
    git -C $workspace -c user.name=Test -c user.email=test@example.invalid commit --quiet -m initial
    $originalRevision=[string](& git -C $workspace rev-parse HEAD)
    Put 'src/inherited.txt' 'prior unfinished change'
    Task Start one @{Tier='T3';Objective='Independent scoped change'} | Out-Null
    $task=Read-AiSopTask $spec one
    Assert ($task.baseline.revision -ceq $originalRevision -and $task.baseline.inputsRef) 'T3 start baseline missing'
    Assert ((Task Changes one | ConvertFrom-Json).manifest.changes.Count -eq 0) 'Inherited dirt attributed to new task'
    Put 'src/current.txt' 'after'; Put 'shared/added.txt' 'new shared dependency'
    [IO.File]::Delete((Join-Path $workspace 'src/deleted.txt'))
    $changes=Task Changes one | ConvertFrom-Json -AsHashtable
    Assert ($changes.manifest.changes.Count -eq 3 -and 'src/inherited.txt' -cnotin $changes.manifest.changes.path) 'Delta lost additions/deletions or inherited dirt'
    Assert (@($changes.manifest.changes | Where-Object status -eq 'DELETED').Count -eq 1) 'Deletion missing'
    git -C $workspace add src shared
    Assert ((Task Changes one | ConvertFrom-Json).changeSetDigest -ceq $changes.changeSetDigest) 'Staging invalidated task delta'
    git -C $workspace -c user.name=Test -c user.email=test@example.invalid commit --quiet -m current
    Assert ((Task Changes one | ConvertFrom-Json).changeSetDigest -ceq $changes.changeSetDigest) 'Commit invalidated task delta'
    $impact=@{schemaVersion='1.0';feature='Example';taskId='one';baseline=$task.baseline.revision;baselineInputDigest=$task.baseline.inputDigest;changeSetDigest=$changes.changeSetDigest;changedFiles=@($changes.manifest.changes.path);changedSymbols=@('src/current.txt');entryPoints=@('file reader');upstreamCallers=@();downstreamEffects=@();stateReadsWrites=@();invariants=@();requiredRegressionCases=@('TC-CURRENT')}
    $impactPath=Join-Path $spec '04_change_impact.json'
    function Impact { [IO.File]::WriteAllText($impactPath,($impact | ConvertTo-Json -Depth 12)) }
    $actualDigest=$impact.changeSetDigest; $impact.changeSetDigest='0'*64; Impact
    Fails { Task ReviewImpact } 'TASK_IMPACT_STALE'
    $impact.changeSetDigest=$actualDigest; $impact.changedFiles=@('src/current.txt'); Impact
    Fails { Task ReviewImpact } 'TASK_IMPACT_FILES_MISMATCH'
    $impact.changedFiles=@($changes.manifest.changes.path); Impact
    Task ReviewImpact | Out-Null
    $stateEntry=Join-Path $scripts 'workflow-state.ps1'
    $risk=& $stateEntry -Operation AssessRisk -Path $spec -TaskId one | ConvertFrom-Json
    Assert ($risk.changeSetDigest -ceq $actualDigest -and $risk.baseline -ceq $task.baseline.revision) 'Risk assessment mixed task/feature digests'
    & $stateEntry -Operation ValidateChangeImpact -Path $impactPath -TaskId one | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'Task impact rejected after content-stable commit'
    $changePath=Join-Path $workspace ".ai-workspace/specs/.artifacts/changes/$actualDigest.json"
    $changeRaw=[IO.File]::ReadAllText($changePath); [IO.File]::WriteAllText($changePath,'{}')
    Fails { & $stateEntry -Operation ValidateChangeImpact -Path $impactPath -TaskId one } 'TASK_CHANGE_MANIFEST_CORRUPT'
    [IO.File]::Delete($changePath)
    Fails { & $stateEntry -Operation ValidateChangeImpact -Path $impactPath -TaskId one } 'TASK_CHANGE_MANIFEST_MISSING'
    [IO.File]::WriteAllText($changePath,$changeRaw)
    Put 'src/current.txt' 'changed again'
    Fails { & $stateEntry -Operation ValidateChangeImpact -Path $impactPath -TaskId one } 'TASK_IMPACT_STALE'
    Put 'src/current.txt' 'after'
    # Whole-feature traceability remains; unrelated planned cases need not run.
    Put '.ai-workspace/specs/features/Example/01_server_rules.md' "# Rules`n- BR-CURRENT current behavior`n- BR-LATER future behavior"
    Put '.ai-workspace/specs/features/Example/06_design_contract.md' "# Design`n- DC-CURRENT current implementation`n- DC-LATER future implementation"
    Put '.ai-workspace/specs/features/Example/05_test_plan.md' "# Tests`n## TC-CURRENT current case`n## TC-LATER future case"
    function ArtifactHash([string]$name) { Get-AiSopWorkflowSha256 ([IO.File]::ReadAllText((Join-Path $spec $name)).TrimEnd() + "`n") }
    $approval=@{schemaVersion='1.0';feature='Example'}
    foreach ($gate in @(@{key='requirement';name='01_server_rules.md'},@{key='design';name='06_design_contract.md'})) { $approval[$gate.key]=@{artifact=$gate.name;status='APPROVED';sha256=(ArtifactHash $gate.name);approvedAt=[DateTimeOffset]::UtcNow.ToString('o');approvedBy='human:test'} }
    Put '.ai-workspace/specs/features/Example/00_workflow_state.json' ($approval | ConvertTo-Json -Depth 8)
    $coverage=@{schemaVersion='1.0';feature='Example';requirementArtifact='01_server_rules.md';requirementSha256=(ArtifactHash '01_server_rules.md');designArtifact='06_design_contract.md';designSha256=(ArtifactHash '06_design_contract.md');testPlanArtifact='05_test_plan.md';testPlanSha256=(ArtifactHash '05_test_plan.md');riskExemptions=@();cases=@(
        @{id='TC-CURRENT';title='Current';status='VERIFIED';priority='P0';testTypes=@('FUNCTIONAL');requirementIds=@('BR-CURRENT');designIds=@('DC-CURRENT');automationCarrier='tests/check.ps1';setup=@('Create isolated fixture');trigger=@('Invoke current behavior');assertions=@{protocol=@(@{target='result';operator='EQ';expected=1})};cleanup=@('Dispose fixture')},
        @{id='TC-LATER';title='Later';status='PLANNED';priority='P0';testTypes=@('FUNCTIONAL');requirementIds=@('BR-LATER');designIds=@('DC-LATER');automationCarrier='TODO'}
    )}
    Put '.ai-workspace/specs/features/Example/05_test_coverage.json' ($coverage | ConvertTo-Json -Depth 12)
    Fails { Task SetCaseScope one @{CaseIds=@('TC-UNKNOWN');Reason='wrong id'} } 'TASK_CASE_UNKNOWN'
    Fails { Task SetCaseScope one @{CaseIds=@();Reason='empty scope'} } 'TASK_CASE_SCOPE_EMPTY'
    Task SetCaseScope one @{CaseIds=@('TC-LATER');Reason='Check mandatory regression inclusion'} | Out-Null
    Assert ((Get-AiSopTaskScopeProblems (Read-AiSopTask $spec one) $workspace $spec) -match 'TASK_CASE_SCOPE_MISSING_REGRESSION') 'Impact regression excluded silently'
    Task SetCaseScope one @{CaseIds=@('TC-CURRENT');Reason='This task only modifies current behavior'} | Out-Null
    Task Run one @{Kind='compile';Executable='pwsh';Arguments=@('-NoProfile','-Command','exit 0')} | Out-Null
    Task Run one @{Kind='test';Executable='pwsh';Arguments=@('-NoProfile','-File','tests/check.ps1');CaseIds=@('TC-CURRENT')} | Out-Null
    & $stateEntry -Operation ValidateTestCoverage -Path (Join-Path $spec '05_test_coverage.json') -Phase VERIFY -TaskId one | Out-Null
    Assert ($LASTEXITCODE -eq 0) 'Unrelated planned case blocked task coverage'
    Assert ((Read-AiSopTask $spec one).requiredCaseIds.Count -eq 1) 'Coverage validation widened task execution scope'
    [IO.File]::AppendAllText((Join-Path $spec '05_test_plan.md'),"`nClarify the current case.")
    Assert ((Get-AiSopTaskScopeProblems (Read-AiSopTask $spec one) $workspace $spec) -match 'TASK_CASE_SCOPE_STALE') 'Spec changes did not stale scope'
    Fails { Task SetBaseline one @{BaselineInputsRef=$task.baseline.inputsRef;Reason='Cannot erase delta'} } 'TASK_BASELINE_IMMUTABLE'
    $ownerPath=Join-Path $env:AI_SOP_OWNER_REGISTRY 'example.json'; $featureBaseline=([IO.File]::ReadAllText($ownerPath) | ConvertFrom-Json).baseline
    Task Cancel | Out-Null
    Task Start two @{Tier='T3';Objective='Next independent task'} | Out-Null
    $second=Read-AiSopTask $spec two
    Assert ($second.baseline.revision -cne $task.baseline.revision -and $second.baseline.inputsRef -cne $task.baseline.inputsRef) 'Independent task inherited old baseline'
    Assert ((Task Changes two | ConvertFrom-Json).manifest.changes.Count -eq 0) 'New task includes preceding task changes'
    $emptyRisk=& $stateEntry -Operation AssessRisk -Path $spec -TaskId two | ConvertFrom-Json
    Assert ('TASK_DIFF_INCOMPLETE' -notin $emptyRisk.triggersHit -and 'TASK_SCOPE_UNAVAILABLE' -notin $emptyRisk.triggersHit) 'Empty delta was treated as an unreadable null path'
    $verifyOutput=[Collections.Generic.List[string]]::new()
    try { Task Verify two 2>&1 | ForEach-Object { $verifyOutput.Add([string]$_) } } catch { $verifyOutput.Add($_.Exception.Message) }
    Assert (($verifyOutput -join "`n") -match 'Historical impact analysis belongs to another task' -and ($verifyOutput -join "`n") -notmatch 'TASK_IMPACT_STALE|04_change_impact.json is mandatory') 'Independent task inherited prior impact obligation'
    Assert (([IO.File]::ReadAllText($ownerPath) | ConvertFrom-Json).baseline -ceq $featureBaseline) 'Task start rewrote feature approval baseline'
    Task Cancel two | Out-Null
    Task Start three @{Tier='T1';Objective='Quick task later explicitly upgraded'} | Out-Null
    Assert (-not (Read-AiSopTask $spec three).baseline.inputsRef) 'T1 start performed full snapshot'
    Task ChangeTier three @{Tier='T3';Reason='User requests full scope';UserRequest='Use T3 now'} | Out-Null
    Fails { Task Changes three } 'TASK_BASELINE_REQUIRED'
    Task SetBaseline three @{BaselineInputsRef=$second.baseline.inputsRef;Reason='Known content immediately before this task, recorded by preceding task Start'} | Out-Null
    Assert ((Task Changes three | ConvertFrom-Json).manifest.changes.Count -eq 0) 'Explicit known baseline could not be adopted'
    Write-Output 'PASS: task/feature baselines, inherited dirt, content delta, impact binding, task case scope and migration'
} finally {
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key,$saved[$key]) }
    $resolved=[IO.Path]::GetFullPath($root)
    if ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue }
}
