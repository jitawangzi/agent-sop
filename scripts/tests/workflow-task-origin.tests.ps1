#requires -Version 7.0
$ErrorActionPreference='Stop'
$scripts=Split-Path -Parent $PSScriptRoot
. (Join-Path $scripts 'task-context.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('sop-task-origin-' + [guid]::NewGuid().ToString('N'))
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
function Task([string]$op,[string]$id,[hashtable]$extra=@{}) {
    & $entry -Operation $op -WorkspacePath $workspace -Feature Example -TaskId $id -Agent CODEX @extra
    if ($LASTEXITCODE -ne 0) { throw "Task $op failed: $LASTEXITCODE" }
}
function Clone($value) { ConvertFrom-AiSopWorkflowJson (ConvertTo-AiSopWorkflowCanonicalJson $value) -AsHashtable }
try {
    foreach ($kind in @('OWNER','SESSION','COMMAND_GRANT','TRANSACTION')) { [Environment]::SetEnvironmentVariable("AI_SOP_${kind}_REGISTRY",(Join-Path $root $kind)) }
    $env:SERVER_NEW_WORKFLOW_OWNER_DEADLINE_MS='15000'; $env:CODEX_SESSION_ID='origin-session'
    [IO.Directory]::CreateDirectory($spec) | Out-Null
    Put 'src/input.txt' 'before'; Put 'docs/guide.md' 'before'; Put 'docs/old.md' 'old'
    $config='.ai-workspace/context/verification-inputs.json'
    $policy=@{schemaVersion='1.0';include=@();exclude=@();nonExecutable=@(@{path='docs';reason='Human-readable guidance, never consumed by a build or runtime'})}
    Put $config ($policy | ConvertTo-Json -Depth 8)
    $snapshot=Get-AiSopInputSnapshot $workspace
    Assert ((Get-AiSopInputSnapshot $workspace -BudgetMilliseconds 60000).digest -ceq $snapshot.digest) 'Budgeted capture changed the input algorithm'
    Fails { Get-AiSopInputSnapshot $workspace -BudgetMilliseconds 60000 -MaxBytes 2 } 'INPUT_CAPTURE_BUDGET_EXCEEDED: bytes'

    Task Start docs @{Tier='T2';Objective='Update non-executable documentation'} | Out-Null
    $initial=Read-AiSopTask $spec docs
    Assert ($initial.startInputs.status -eq 'CAPTURED' -and $initial.startInputs.mode -eq 'BOUNDED') 'Small light task failed to record its origin'
    Put 'docs/guide.md' 'updated'; Put 'docs/new.md' 'new'; [IO.File]::Delete((Join-Path $workspace 'docs/old.md'))
    foreach ($kind in @('compile','test')) { Task SetApplicability docs @{Kind=$kind;Applicability='NOT_APPLICABLE';Reason='Only predeclared human-readable documentation changed'} | Out-Null }
    Task RecordSync docs @{Documentation='UPDATED';Tests='NOT_APPLICABLE';Summary='Only explanatory text changed; added and removed documentation accounted for'} | Out-Null
    Task Verify docs | Out-Null
    $declared=Read-AiSopTask $spec docs
    Assert ($declared.applicability.compile.startInputsRef -ceq $initial.startInputs.inputsRef) 'Applicability not bound to the creation snapshot'
    $oldDeclaration=Clone $declared
    $oldDeclaration.applicability.compile.Remove('startInputsRef')
    Assert ((Get-AiSopTaskProblems $oldDeclaration $workspace $spec) -match 'APPLICABILITY_START_UNBOUND') 'Legacy unbound declaration was silently grandfathered'
    $legacy=Clone $declared; $legacy.Remove('startInputs')
    Assert ((Get-AiSopTaskProblems $legacy $workspace $spec) -match 'TASK_START_INPUTS_UNAVAILABLE') 'Missing original inputs authorized a skip'

    # Existing dirty/untracked inputs are captured by content, independent of VCS
    # status, file length, or restored last-write timestamps.
    $input=Join-Path $workspace 'src/input.txt'; $stamp=[IO.File]::GetLastWriteTimeUtc($input)
    Put 'src/input.txt' 'edited'; [IO.File]::SetLastWriteTimeUtc($input,$stamp)
    foreach ($kind in @('compile','test')) { Fails { Task SetApplicability docs @{Kind=$kind;Applicability='NOT_APPLICABLE';Reason='Claiming only docs changed must fail'} } 'APPLICABILITY_INPUTS_CHANGED' }
    Assert ((Get-AiSopTaskProblems (Read-AiSopTask $spec docs) $workspace $spec) -match 'APPLICABILITY_INPUTS_CHANGED') 'Verify trusted a declaration after source edits'
    $policy.nonExecutable+=@{path='src';reason='Late reclassification must not authorize a skip'}
    Put $config ($policy | ConvertTo-Json -Depth 8)
    Fails { Task SetApplicability docs @{Kind='compile';Applicability='NOT_APPLICABLE';Reason='Late reclassification'} } 'APPLICABILITY_POLICY_CHANGED'
    $policy.nonExecutable=@($policy.nonExecutable | Where-Object path -eq docs); Put $config ($policy | ConvertTo-Json -Depth 8)
    Put 'src/input.txt' 'before'
    Task Suspend docs | Out-Null
    $env:CODEX_SESSION_ID='receiving-session'
    Task Resume docs | Out-Null
    Assert ((ConvertTo-AiSopWorkflowCanonicalJson (Read-AiSopTask $spec docs).startInputs) -ceq (ConvertTo-AiSopWorkflowCanonicalJson $initial.startInputs)) 'Handoff recaptured or replaced the original inputs'
    Task Complete docs | Out-Null

    Task Start upgrade @{Tier='T1'; UserRequest='本测试明确选择 T1';Objective='Change code before an explicit T3 upgrade'} | Out-Null
    $beforeUpgrade=Read-AiSopTask $spec upgrade
    Put 'src/input.txt' 'after-upgrade-start'
    Task Run upgrade @{Kind='compile';Executable='pwsh';Arguments=@('-NoProfile','-Command','exit 0')} | Out-Null
    $runRef=(Read-AiSopTask $spec upgrade).verifications[-1].inputsRef
    Fails { Task SetBaseline upgrade @{BaselineInputsRef=$runRef;Reason='A Run snapshot is not a task origin'} } 'TASK_BASELINE_SOURCE_UNVERIFIED'
    Task SetBaseline upgrade @{BaselineInputsRef=$beforeUpgrade.startInputs.inputsRef;Reason='Use the exact origin recorded in this task creation transaction'} | Out-Null
    Task ChangeTier upgrade @{Tier='T3';Reason='Explicit full verification';UserRequest='Use T3 now'} | Out-Null
    Assert ((Task Changes upgrade | ConvertFrom-Json).manifest.changes.Count -eq 1) 'Origin adoption erased the earlier T1 source change'
    $current=Read-AiSopTask $spec upgrade
    $legacy=Clone $current; $legacy.Remove('startInputs'); $legacy.baseline.source='ADOPTED'
    Fails { Get-AiSopTaskChanges $legacy $workspace } 'TASK_BASELINE_SOURCE_UNVERIFIED'
    $legacy.tier='T1'
    $tierUpdate=@{operation='ChangeTier';tier='T3';reason='Upgrade a historical task';userRequest='Use T3 now'}
    Fails { Update-AiSopTaskPolicy $legacy $tierUpdate $spec $workspace ([DateTimeOffset]::UtcNow.ToString('o')) } 'TASK_BASELINE_SOURCE_UNVERIFIED'
    Assert ($legacy.tier -eq 'T1') 'Unverified historical baseline stranded the task in T3'
    $legacy.baseline.source='START'
    Update-AiSopTaskPolicy $legacy $tierUpdate $spec $workspace ([DateTimeOffset]::UtcNow.ToString('o')) | Out-Null
    Assert ($legacy.tier -eq 'T3') 'Historical T3 Start baseline could not be reused on upgrade'
    Assert ((Get-AiSopTaskChanges $legacy $workspace).manifest.changes.Count -eq 1) 'Historical T3 Start baseline lost compatibility'
    $foreign=Clone $current; $foreign.startInputs.taskId='another-task'
    Fails { Read-AiSopTaskStartInputs $foreign $workspace } 'TASK_START_IDENTITY_MISMATCH'
    Fails { Task Resume upgrade @{CaptureBaseline=$true} } 'CAPTURE_BASELINE_REQUIRES_START'
    Task Cancel upgrade | Out-Null

    # A large input must not make light Start read the whole file or save an
    # incomplete manifest. Normal T1 compile/completion remains available.
    $large=Join-Path $workspace 'large.bin'
    $stream=[IO.File]::Create($large)
    try { $stream.SetLength(9MB) } finally { $stream.Dispose() }
    $started=Task Start bounded @{Tier='T1'; UserRequest='本测试明确选择 T1';Objective='Quick change in a large workspace'} | Out-String
    Assert ($started -match 'TASK_START_INPUTS: UNAVAILABLE' -and $started -match 'INPUT_CAPTURE_BUDGET_EXCEEDED' -and $started -match 'normal T1/T2 verification remains available') 'Start did not report missing origin and the available normal flow'
    $bounded=Read-AiSopTask $spec bounded
    Assert ($bounded.startInputs.status -eq 'UNAVAILABLE' -and -not $bounded.startInputs.inputsRef -and $bounded.startInputs.reason -match 'INPUT_CAPTURE_BUDGET_EXCEEDED') 'Light Start exceeded its budget or saved a partial origin'
    $status=& $entry -Operation Status -WorkspacePath $workspace -Feature Example -TaskId bounded -Json | ConvertFrom-Json
    Assert ($status.tasks[0].startInputs.status -eq 'UNAVAILABLE') 'A receiving agent cannot discover the missing origin through Status'
    Fails { Task SetApplicability bounded @{Kind='compile';Applicability='NOT_APPLICABLE';Reason='Unknown origin cannot prove docs-only changes'} } 'TASK_START_INPUTS_UNAVAILABLE'
    Fails { Task ChangeTier bounded @{Tier='T3';Reason='Missing origin cannot be invented';UserRequest='Use T3'} } 'TASK_START_INPUTS_UNAVAILABLE'
    Assert ((Read-AiSopTask $spec bounded).tier -eq 'T1') 'Failed upgrade stranded the task in T3'
    Task Run bounded @{Kind='compile';Executable='pwsh';Arguments=@('-NoProfile','-Command','exit 0')} | Out-Null
    $run=Read-AiSopTask $spec bounded
    Fails { Task SetBaseline bounded @{BaselineInputsRef=$run.verifications[-1].inputsRef;Reason='A later full Run cannot repair the start'} } 'TASK_START_INPUTS_UNAVAILABLE'
    $legacy=Clone $run; $legacy.Remove('startInputs')
    Assert (@(Get-AiSopTaskProblems $legacy $workspace $spec).Count -eq 0) 'Old light tasks now require origin proof for normal compilation'
    Task Complete bounded | Out-Null

    # Full capture is opt-in on light tasks and is forwarded by the host entry.
    $engine=Join-Path $workspace '.ai-sop'; [IO.Directory]::CreateDirectory($engine) | Out-Null
    Copy-Item -LiteralPath $scripts -Destination $engine -Recurse
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $scripts) 'schemas') -Destination $engine -Recurse
    $hostEntry=Join-Path $workspace 'ai-sop.ps1'
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $scripts) 'distribution/templates/root/ai-sop.ps1') -Destination $hostEntry
    $fullStart=& $hostEntry Task -Operation Start -Feature Example -TaskId full -Tier T1 -UserRequest '本测试明确选择 T1' -CaptureBaseline -Objective 'Explicit pre-edit origin' -Agent CODEX | Out-String
    Assert ($LASTEXITCODE -eq 0) 'Host Start failed'
    Assert ($fullStart -match 'TASK_START_INPUTS: CAPTURED mode=FULL') 'Host Start did not expose the captured origin'
    $full=Read-AiSopTask $spec full
    Assert ($full.tier -eq 'T1' -and $full.startInputs.mode -eq 'FULL' -and $full.startInputs.status -eq 'CAPTURED') 'Full capture switched tiers or was not forwarded'
    # Portable proof is carried by task.json plus its referenced manifest, not a
    # machine-local registry or an editable manifest creation timestamp.
    $receiver=Join-Path $root 'receiver'; [IO.Directory]::CreateDirectory($receiver) | Out-Null
    $target=Get-AiSopInputManifestPath $receiver $full.startInputs.inputsRef
    [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
    Copy-Item -LiteralPath (Get-AiSopInputManifestPath $workspace $full.startInputs.inputsRef) -Destination $target
    Assert ((Read-AiSopTaskStartInputs $full $receiver).digest -ceq $full.startInputs.inputDigest) 'Origin could not be read in another workspace'
    [IO.File]::WriteAllText($target,'{}')
    Fails { Read-AiSopTaskStartInputs $full $receiver } 'INPUT_MANIFEST_CORRUPT'
    Task Cancel full | Out-Null
    Write-Output 'PASS: bounded/full Start capture, origin provenance, tier upgrades, declared non-executable changes, legacy compatibility and portable handoff'
} finally {
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key,$saved[$key]) }
    $resolved=[IO.Path]::GetFullPath($root)
    $prefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sop-task-origin-*') { throw 'Unsafe fixture cleanup path' }
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue
}
