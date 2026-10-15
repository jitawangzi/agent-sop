#requires -Version 7.0
$ErrorActionPreference='Stop'
$scripts=Split-Path -Parent $PSScriptRoot
. (Join-Path $scripts 'task-context.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('sop-task-inputs-' + [guid]::NewGuid().ToString('N'))
$workspace=Join-Path $root 'workspace'
$spec=Join-Path $workspace '.ai-workspace/specs/features/Example'
$entry=Join-Path $workspace '.ai-sop/scripts/workflow-task.ps1'
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
    $env:SERVER_NEW_WORKFLOW_OWNER_DEADLINE_MS='15000'; $env:CODEX_SESSION_ID='input-policy-session'
    [IO.Directory]::CreateDirectory($spec) | Out-Null
    Put 'src/main.txt' 'source'; Put 'shared/base.txt' 'shared'; Put 'generated/output.txt' 'generated'
    Put 'build/handwritten.txt' 'real input'; Put 'build/noise.txt' 'output'
    Put '.ai-workspace/context/contract.txt' 'project input'; Put '.ai-workspace/context/noise.txt' 'context noise'
    $original=Get-AiSopInputSnapshot $workspace
    Assert ($original.algorithm -eq 'inputs-v2' -and -not $original.files.ContainsKey('build/handwritten.txt')) 'Default v2 compatibility changed'
    $policy=@{schemaVersion='1.0';include=@('build/handwritten.txt','.ai-workspace/context/contract.txt');exclude=@(@{path='generated';reason='Compiler outputs only'})}
    $config='.ai-workspace/context/verification-inputs.json'
    Put $config ($policy | ConvertTo-Json -Depth 5)
    $configured=Get-AiSopInputSnapshot $workspace
    Assert ($configured.algorithm -eq 'inputs-v3' -and $configured.files.ContainsKey('shared/base.txt')) 'Configured inputs dropped shared dependencies'
    Assert ($configured.files.ContainsKey('build/handwritten.txt') -and $configured.files.ContainsKey('.ai-workspace/context/contract.txt')) 'Explicit inputs did not override default exclusions'
    Assert (-not $configured.files.ContainsKey('build/noise.txt') -and -not $configured.files.ContainsKey('.ai-workspace/context/noise.txt') -and -not $configured.files.ContainsKey('generated/output.txt')) 'Reincluded descendant brought excluded siblings into inputs'
    Put 'generated/output.txt' 'new output'
    Assert ((Get-AiSopInputSnapshot $workspace).digest -ceq $configured.digest) 'Excluded generated output invalidated inputs'
    Put 'shared/base.txt' 'changed shared'
    Assert ((Get-AiSopInputSnapshot $workspace).digest -cne $configured.digest) 'Shared dependency change was missed'
    $policy.exclude[0].reason='Output description corrected'; Put $config ($policy | ConvertTo-Json -Depth 5)
    Assert ((Get-AiSopInputSnapshot $workspace).policyDigest -cne $configured.policyDigest) 'Policy changes not bound to evidence'
    foreach ($badPath in @('../outside','C:/outside','src/*','.ai-workspace/specs','.ai-workspace')) {
        Put $config (@{schemaVersion='1.0';include=@($badPath);exclude=@()} | ConvertTo-Json -Depth 5)
        Fails { Get-AiSopInputSnapshot $workspace } 'INPUT_POLICY_INVALID'
    }
    Put $config '{broken'; Fails { Get-AiSopInputSnapshot $workspace } 'INPUT_POLICY_INVALID'
    Put $config ($policy | ConvertTo-Json -Depth 5)
    # A physical link cannot redirect configured input or manifest paths outside
    # the workspace. Skip only when the OS disallows creation of test links.
    $outside=Join-Path $root 'outside'; [IO.Directory]::CreateDirectory($outside) | Out-Null
    $link=Join-Path $workspace 'linked'
    $linked=$false
    try { New-Item -ItemType SymbolicLink -Path $link -Target $outside -ErrorAction Stop | Out-Null; $linked=$true } catch { Write-Output 'SKIP: symlink creation unavailable' }
    if ($linked) {
        try { Fails { Resolve-AiSopWorkspaceChild $workspace 'linked/file' } 'WORKSPACE_PATH_ESCAPE' }
        finally { [IO.Directory]::Delete($link) }
    }
    # Instrument only the isolated copy: Status across two tasks must read source
    # content once; a later invocation must scan again and see a new change.
    $engine=Join-Path $workspace '.ai-sop'; [IO.Directory]::CreateDirectory($engine) | Out-Null
    Copy-Item -LiteralPath $scripts -Destination $engine -Recurse
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $scripts) 'schemas') -Destination $engine -Recurse
    $counter=Join-Path $root 'scans.txt'
    $inputModule=Join-Path $engine 'scripts/verification-inputs.ps1'
    $inputText=[IO.File]::ReadAllText($inputModule)
    $needle="function Get-AiSopInputSnapshot {`n    param([string]`$WorkspacePath)"
    $inputText=$inputText.Replace($needle, ($needle + "`n    [IO.File]::AppendAllText('" + $counter.Replace("'","''") + "', 'scan;')"))
    [IO.File]::WriteAllText($inputModule,$inputText)
    $template=Join-Path (Split-Path -Parent $scripts) 'distribution/templates/root/ai-sop.ps1'
    Copy-Item -LiteralPath $template -Destination (Join-Path $workspace 'ai-sop.ps1')
    Task Start one @{Tier='T1';Objective='Input evidence and independent start'} | Out-Null
    Task Run one @{Kind='compile';Executable='pwsh';Arguments=@('-NoProfile','-Command','exit 0')} | Out-Null
    Task Run one @{Kind='compile';Executable='pwsh';Arguments=@('-NoProfile','-Command','exit 0')} | Out-Null
    $task=Read-AiSopTask $spec one
    Assert ($task.verifications[0].inputsRef -ceq $task.verifications[1].inputsRef -and -not $task.verifications[0].ContainsKey('inputs')) 'Run did not deduplicate the full input manifest'
    $manifestPath=Get-AiSopInputManifestPath $workspace $task.verifications[0].inputsRef
    Assert (@(Get-ChildItem -LiteralPath (Split-Path -Parent $manifestPath) -File).Count -eq 1) 'Repeated runs stored duplicate manifests'
    $logPath=Get-AiSopRunLogPath $task.verifications[-1] $workspace $spec one
    Assert ($logPath -like '*\.runtime\*' -or $logPath -like '*/.runtime/*') 'Logs still stored in specs'
    Assert ([IO.File]::Exists($logPath) -and -not @(Get-ChildItem -LiteralPath (Split-Path -Parent (Get-AiSopTaskPath $spec one)) -Filter '*.log').Count) 'Local log missing or synced log still generated'
    Task Verify | Out-Null
    $manifestRaw=[IO.File]::ReadAllText($manifestPath)
    [IO.File]::WriteAllText($manifestPath,'{}')
    Assert ((Get-AiSopTaskProblems $task $workspace $spec) -match 'INPUT_MANIFEST_CORRUPT') 'Corrupt manifest accepted'
    [IO.File]::Delete($manifestPath)
    Assert ((Get-AiSopTaskProblems $task $workspace $spec) -match 'INPUT_MANIFEST_MISSING') 'Missing manifest accepted'
    [IO.File]::WriteAllText($manifestPath,$manifestRaw)
    # A receiving workspace needs the portable artifact, even with identical code.
    $receiver=Join-Path $root 'receiver'; [IO.Directory]::CreateDirectory($receiver) | Out-Null
    Fails { Read-AiSopVerificationInputs $task.verifications[0] $receiver } 'INPUT_MANIFEST_MISSING'
    $receivedPath=Get-AiSopInputManifestPath $receiver $task.verifications[0].inputsRef
    [IO.Directory]::CreateDirectory((Split-Path -Parent $receivedPath)) | Out-Null
    Copy-Item -LiteralPath $manifestPath -Destination $receivedPath
    Assert ((Read-AiSopVerificationInputs $task.verifications[0] $receiver).digest -ceq $task.verifications[0].inputDigest) 'Portable input manifest could not be read'
    Task Suspend | Out-Null
    $beforeStart=[IO.File]::ReadAllText((Get-AiSopTaskPath $spec one))
    Fails { Task Start one @{Tier='T1';Objective='Different independent goal'} } 'TASK_ALREADY_EXISTS'
    Assert ([IO.File]::ReadAllText((Get-AiSopTaskPath $spec one)) -ceq $beforeStart) 'Rejected Start mutated original task'
    Fails { Task Resume one @{Objective='Different goal'} } 'RESUME_OBJECTIVE_MISMATCH'
    Task Start two @{Tier='T1';Objective='Another task'} | Out-Null
    [IO.File]::WriteAllText($counter,'')
    $status=& $entry -Operation Status -WorkspacePath $workspace -Feature Example -Json | ConvertFrom-Json
    Assert ($status.schemaVersion -eq '1.0' -and $status.tasks.Count -eq 2 -and [IO.File]::ReadAllText($counter) -ceq 'scan;') 'Status did not share one input snapshot across tasks'
    Assert (Test-Json -Json ($status | ConvertTo-Json -Depth 20) -SchemaFile (Join-Path (Split-Path -Parent $scripts) 'schemas/task-status.schema.json')) 'Versioned Status output violates its schema'
    Put 'src/main.txt' 'next invocation change'
    $status=& $entry -Operation Status -WorkspacePath $workspace -Feature Example -Json | ConvertFrom-Json
    Assert ([IO.File]::ReadAllText($counter) -ceq 'scan;scan;' -and ($status.tasks | Where-Object taskId -eq one).diagnostics -match 'STALE_EVIDENCE') 'Snapshot leaked between Status invocations'
    $rootStatus=& (Join-Path $workspace 'ai-sop.ps1') Status -Feature Example -Json | ConvertFrom-Json
    Assert ($rootStatus.tasks.Count -eq 2 -and $rootStatus.schemaVersion -eq '1.0') 'Root Status JSON contract differs'
    $human=& (Join-Path $workspace 'ai-sop.ps1') Status -Feature Example | Out-String
    Assert ($human -match '\[PAUSED\]' -and $human -match 'next:') 'Default Status is not readable'
    if ([OperatingSystem]::IsWindows()) {
        $caseStatus=& $entry -Operation Status -WorkspacePath $workspace -Feature example -TaskId two -Json | ConvertFrom-Json
        Assert ($caseStatus.tasks[0].feature -ceq 'Example') 'Windows feature case was not canonicalized'
        & $entry -Operation Checkpoint -WorkspacePath $workspace -Feature example -TaskId two -Agent CODEX | Out-Null
        Assert ($LASTEXITCODE -eq 0) 'Windows case-insensitive mutation failed'
    } else {
        Assert ((Resolve-AiSopFeatureName $workspace example) -ceq 'example') 'POSIX feature lookup ignored case'
    }
    Task AddFollowUp two @{FollowUpId='sync';FollowUpKind='documentation';Summary='Deferred description';Scope=@('contract')} | Out-Null
    Task SetApplicability two @{Kind='compile';Applicability='NOT_APPLICABLE';Reason='Only recording a deferred description'} | Out-Null
    Task Complete two | Out-Null
    $discover=& $entry -Operation Discover -WorkspacePath $workspace -Feature Example -Json | ConvertFrom-Json
    Assert ($discover.tasks.Count -eq 2 -and ($discover.tasks | Where-Object taskId -eq two).pendingFollowUps.Count -eq 1) 'DONE task follow-up disappeared from discovery'
    Task Resume | Out-Null
    Task CloseFollowUp one @{SourceTaskId='two';FollowUpId='sync';Disposition='RESOLVED';Resolution='Description synchronized in current task'} | Out-Null
    Task Cancel | Out-Null
    $empty=& $entry -Operation Discover -WorkspacePath $workspace -Feature Example -Json | ConvertFrom-Json
    Assert ($empty.tasks.Count -eq 0) 'Terminal history clutters default discovery'
    $history=& $entry -Operation Discover -WorkspacePath $workspace -Feature Example -IncludeHistory -Json | ConvertFrom-Json
    Assert ($history.tasks.Count -eq 2) 'IncludeHistory did not restore terminal tasks'
    Task Start three @{Tier='T3';Objective='Malformed specification diagnostics'} | Out-Null
    Put '.ai-workspace/specs/features/Example/05_test_coverage.json' '{broken'
    $bad=& $entry -Operation Status -WorkspacePath $workspace -Feature Example -TaskId three -Json | ConvertFrom-Json
    Assert ($bad.tasks[0].status -eq 'ACTIVE' -and $bad.tasks[0].diagnostics -match 'SPEC_JSON_INVALID:') 'Invalid spec misreported as corrupt task or success'
    Fails { Task Run three @{Kind='test';Executable='pwsh';Arguments=@('-NoProfile','-Command','exit 0')} } 'SPEC_JSON_INVALID'
    Fails { Task ReviewImpact three } 'IMPACT_ARTIFACT_MISSING'
    Task Cancel three | Out-Null
    # Deployment drift should warn without blocking task listing.
    Put '.ai-sop/distribution/templates/root/ai-sop.ps1' 'new engine entry'
    $drift=& $entry -Operation Discover -WorkspacePath $workspace -Json | ConvertFrom-Json
    Assert ($drift.warnings -match 'DEPLOYMENT_PROJECTION_STALE') 'Outdated host entry was not diagnosed'
    Put '.ai-workspace/specs/features/Legacy/feature-state.json' '{"tier":"T3","phase":"IMPLEMENT"}'
    $legacy=& $entry -Operation Status -WorkspacePath $workspace -Feature Legacy -Json | ConvertFrom-Json
    Assert ($legacy.tasks[0].status -eq 'LEGACY' -and $legacy.tasks[0].tier -eq 'T3' -and $legacy.tasks[0].phase -eq 'IMPLEMENT') 'Legacy state details were lost'
    Write-Output 'PASS: input policy, portable manifests, snapshot reuse, Start/Resume, status formats, feature paths, spec and deployment diagnostics'
} finally {
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key,$saved[$key]) }
    $resolved=[IO.Path]::GetFullPath($root)
    $tempPrefix=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/') + [IO.Path]::DirectorySeparatorChar
    if ($resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'sop-task-inputs-*') { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue }
}
