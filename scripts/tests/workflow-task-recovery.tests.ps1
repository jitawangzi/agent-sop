#requires -Version 7.0
$ErrorActionPreference='Stop'
$scripts=Split-Path -Parent $PSScriptRoot
$entry=Join-Path $scripts 'workflow-task.ps1'
. (Join-Path $scripts 'task-context.ps1')
. (Join-Path $scripts 'workflow-session.ps1')
$root=Join-Path ([IO.Path]::GetTempPath()) ('sop-task-recovery-' + [guid]::NewGuid().ToString('N'))
$workspace=Join-Path $root 'workspace'
$spec=Join-Path $workspace '.ai-workspace/specs/features/Example'
$saved=@{}; $runner=$null
foreach ($key in @('AI_SOP_OWNER_REGISTRY','AI_SOP_SESSION_REGISTRY','AI_SOP_COMMAND_GRANT_REGISTRY','AI_SOP_TRANSACTION_REGISTRY','SERVER_NEW_WORKFLOW_OWNER_DEADLINE_MS','CODEX_SESSION_ID')) { $saved[$key]=[Environment]::GetEnvironmentVariable($key) }
function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Task([string]$op, [hashtable]$extra=@{}) {
    & $entry -Operation $op -WorkspacePath $workspace -Feature Example -TaskId recovery -Agent CODEX @extra
    if ($LASTEXITCODE -ne 0) { throw "Task $op failed: $LASTEXITCODE" }
}
function Fails([scriptblock]$action, [string]$pattern) {
    $failure=''
    try { & $action | Out-Null; if ($LASTEXITCODE -ne 0) { $failure="exit=$LASTEXITCODE" } } catch { $failure=$_.Exception.Message }
    Assert ($failure -match $pattern) "Expected $pattern, received '$failure'"
}
function Read-LiveLog([string]$path) {
    $stream=[IO.FileStream]::new($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)
    $reader=[IO.StreamReader]::new($stream)
    try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}
try {
    foreach ($kind in @('OWNER','SESSION','COMMAND_GRANT','TRANSACTION')) { [Environment]::SetEnvironmentVariable("AI_SOP_${kind}_REGISTRY", (Join-Path $root $kind)) }
    $env:SERVER_NEW_WORKFLOW_OWNER_DEADLINE_MS='15000'; $env:CODEX_SESSION_ID='recovery-native'
    [IO.Directory]::CreateDirectory($spec) | Out-Null
    [IO.File]::WriteAllText((Join-Path $workspace 'input.txt'), 'input')
    $sopRoot=Join-Path $workspace '.ai-sop'
    [IO.Directory]::CreateDirectory($sopRoot) | Out-Null
    Copy-Item -LiteralPath $scripts -Destination $sopRoot -Recurse
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $scripts) 'schemas') -Destination $sopRoot -Recurse
    $rootEntry=Join-Path $workspace 'ai-sop.ps1'
    Copy-Item -LiteralPath (Join-Path (Split-Path -Parent $scripts) 'distribution/templates/root/ai-sop.ps1') -Destination $rootEntry
    Task Start @{ Tier='T2'; Objective='Recovery and streaming integration' } | Out-Null
    Task RecordSync @{ Documentation='UNCHANGED'; Tests='UNCHANGED'; Summary='Recovery fixture uses existing command scenarios; no contract change.' } | Out-Null
    # A synchronized task record grants no execution ownership in another workspace.
    $remoteWorkspace=Join-Path $root 'receiver'
    $remoteSpec=Join-Path $remoteWorkspace '.ai-workspace/specs/features/Example'
    $remoteTaskPath=Get-AiSopTaskPath $remoteSpec 'recovery'
    [IO.Directory]::CreateDirectory((Split-Path -Parent $remoteTaskPath)) | Out-Null
    Copy-Item -LiteralPath (Get-AiSopTaskPath $spec 'recovery') -Destination $remoteTaskPath
    $localOwnerRegistry=$env:AI_SOP_OWNER_REGISTRY
    try {
        $env:AI_SOP_OWNER_REGISTRY=Join-Path $root 'receiver-owner'
        Fails { & $entry -Operation Resume -WorkspacePath $remoteWorkspace -Feature Example -TaskId recovery -Agent CODEX } 'TASK_NOT_RESUMABLE'
        & $entry -Operation Recover -WorkspacePath $remoteWorkspace -Feature Example -TaskId recovery -Agent CODEX | Out-Null
        & $entry -Operation Resume -WorkspacePath $remoteWorkspace -Feature Example -TaskId recovery -Agent CODEX | Out-Null
        $remoteOwner=Get-Content -LiteralPath (Join-Path $env:AI_SOP_OWNER_REGISTRY 'example.json') -Raw | ConvertFrom-Json
        Assert ($remoteOwner.workspacePath -ceq (Resolve-PhysicalPathIdentity $remoteWorkspace)) 'Receiver inherited sender authority'
        & $entry -Operation Suspend -WorkspacePath $remoteWorkspace -Feature Example -TaskId recovery -Agent CODEX | Out-Null
    } finally { $env:AI_SOP_OWNER_REGISTRY=$localOwnerRegistry }
    Assert ((Read-AiSopTask $spec 'recovery').status -eq 'ACTIVE') 'Receiver changed sender task'
    Fails { Task Recover } 'SESSION_MAY_BE_ACTIVE'
    Task Recover @{ ForceRecovery=$true; Notes='Old agent stopped' } | Out-Null
    Assert ((Read-AiSopTask $spec 'recovery').status -eq 'PAUSED') 'Recover did not pause task'
    $ownerPath=Join-Path $env:AI_SOP_OWNER_REGISTRY 'example.json'
    $released=Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json
    $session=Get-AiSopWorkflowSession -SessionKey $released.sessionBinding.sessionKey -WorkspacePath $workspace
    Assert (-not $session.Record.boundOwnerId) 'Recover left old session bound'
    $status=Task Status @{OutputFormat="JsonLines"} | ConvertFrom-Json
    $discover=Task Discover @{OutputFormat="JsonLines"} | ConvertFrom-Json
    Assert ($status.status -eq 'PAUSED' -and $discover.status -eq $status.status -and $status.ownerStatus -eq 'RELEASED') 'Discover/Status disagree'
    $rootStatus=& $rootEntry Status -Feature Example -TaskId recovery -OutputFormat JsonLines | ConvertFrom-Json
    Assert ($rootStatus.status -eq $status.status -and $rootStatus.ownerStatus -eq $status.ownerStatus) 'Root Status still shows legacy state'
    Task Resume | Out-Null
    & (Join-Path $scripts 'workflow-owner.ps1') -Operation ForceRelease -Feature Example -SpecDirectory $spec -Workflow SUPERPOWERS -Agent CODEX -OwnerId 'task-recovery' | Out-Null
    Assert ((Read-AiSopTask $spec 'recovery').status -eq 'PAUSED') 'Legacy ForceRelease orphaned task state'
    Task Resume | Out-Null
    Invoke-AiSopWorkflowSession -Operation End -Agent CODEX -NativeSessionId $env:CODEX_SESSION_ID -WorkspacePath $workspace -AcceptedAt ([DateTimeOffset]::UtcNow) | Out-Null
    Task Recover | Out-Null
    $env:CODEX_SESSION_ID='recovery-native-new'
    Task Resume | Out-Null
    # Missing local owner must not silently inherit permissions from a mirror.
    Remove-Item -LiteralPath $ownerPath
    Fails { Task Resume } 'TASK_NOT_RESUMABLE'
    Task Recover @{ ForceRecovery=$true } | Out-Null
    Assert (-not (Test-Path -LiteralPath $ownerPath)) 'Recovery recreated active authority from mirror'
    Task Resume | Out-Null

    $contextDir=Join-Path $workspace '.ai-workspace/context'
    [IO.Directory]::CreateDirectory($contextDir) | Out-Null
    $configPath=Join-Path $contextDir 'verification-commands.json'
    $config=@{ schemaVersion='1.0'; commands=@{
        build=@{kind='compile';executable='pwsh';arguments=@('-NoProfile','-Command',"if (-not (Test-Path input.txt)) { exit 2 }; Write-Output 'BUILD_OK'")}
        check=@{kind='test';batch='regression';executable='pwsh';arguments=@('-NoProfile','-Command',"if ([IO.File]::ReadAllText('input.txt') -ne 'input') { exit 2 }; Write-Output 'TEST_OK'")}
        slow=@{kind='test';batch='regression';executable='pwsh';arguments=@('-NoProfile','-Command',"[Console]::WriteLine('READY'); [Console]::Out.Flush(); Start-Sleep -Seconds 60")}
    }}
    [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json -Depth 10))
    Task Run @{Profile='build'} | Out-Null
    Task Run @{Profile='check'} | Out-Null
    Task Verify | Out-Null
    Fails { Task Run @{ Profile='build'; Executable='pwsh' } } 'PROFILE_OVERRIDE_FORBIDDEN'
    Fails { Task Run @{ Profile='missing' } } 'PROFILE_NOT_FOUND'
    Fails { Task Run @{ Profile='slow'; TimeoutSeconds=1; Reason='Exercise timeout instead of the normal regression command' } } 'Task Run failed'
    $last=(Read-AiSopTask $spec 'recovery').verifications[-1]
    Assert ($last.outcome -eq 'TIMED_OUT' -and $last.exitCode -eq 124) 'Timeout was not recorded'
    Fails { Task Verify } 'Task Verify failed'
    Task Run @{Profile='check'; Reason='Restore normal regression after timeout'} | Out-Null

    # Launch an actual external runner and inspect its durable log while running.
    $runner=[Diagnostics.Process]::new()
    $runner.StartInfo.FileName=(@(Get-Command pwsh -CommandType Application)[0]).Source
    $runner.StartInfo.UseShellExecute=$false; $runner.StartInfo.CreateNoWindow=$true
    $runner.StartInfo.RedirectStandardOutput=$true; $runner.StartInfo.RedirectStandardError=$true
    foreach ($arg in @('-NoProfile','-File',$entry,'-Operation','Run','-WorkspacePath',$workspace,'-Feature','Example','-TaskId','recovery','-Agent','CODEX','-Profile','slow','-Reason','Exercise interrupted execution')) { $runner.StartInfo.ArgumentList.Add($arg) }
    Assert ($runner.Start()) 'Runner launch failed'
    $stdout=$runner.StandardOutput.ReadToEndAsync(); $stderr=$runner.StandardError.ReadToEndAsync()
    $deadline=[DateTimeOffset]::UtcNow.AddSeconds(20); $streamed=$false
    while ([DateTimeOffset]::UtcNow -lt $deadline -and -not $runner.HasExited) {
        $live=(Read-AiSopTask $spec 'recovery').verifications[-1]
        if ($live.outcome -eq 'RUNNING' -and $live.context.childPid) {
            $log=Get-AiSopRunLogPath $live $workspace $spec 'recovery'
            if ((Test-Path -LiteralPath $log) -and (Read-LiveLog $log).Contains('READY')) { $streamed=$true; break }
        }
        [Threading.Thread]::Sleep(100)
    }
    Assert $streamed "Output was not streamed before exit: $($runner.HasExited)"
    $liveStatus=Task Status @{OutputFormat="JsonLines"} | ConvertFrom-Json
    Assert ($liveStatus.runs[0].activity -eq 'RUNNING') 'Status missed running process'
    Fails { Task Recover @{ForceRecovery=$true} } 'RUN_STILL_ACTIVE'
    Fails { Task Resume } 'RUN_UNFINISHED'
    Fails { Task Suspend } 'RUN_UNFINISHED'
    Fails { Task Run @{Profile='build'} } 'RUN_UNFINISHED'
    Fails { Task ChangeTier @{Tier='T1';Reason='Requested quicker handoff';UserRequest='Use T1'} } 'RUN_UNFINISHED'
    Task AddFollowUp @{FollowUpId='runner-doc';FollowUpKind='documentation';Summary='Explain interruption recovery';Scope=@('runtime documentation')} | Out-Null
    Assert ((Read-AiSopTask $spec recovery).verifications[-1].outcome -eq 'RUNNING') 'Recording a follow-up changed the running verification'
    # Only terminate the Process instance created by this test, including its child.
    $runner.Kill($true); $runner.WaitForExit(5000) | Out-Null
    $runner.Dispose(); $runner=$null
    $abandoned=Task Status @{OutputFormat="JsonLines"} | ConvertFrom-Json
    Assert ($abandoned.runs[0].activity -eq 'INTERRUPTED') 'Abrupt termination not diagnosed'
    Fails { Task Complete } 'RUN_UNFINISHED'
    Task Recover @{ForceRecovery=$true;Notes='Runner terminated during test'} | Out-Null
    $recovered=Read-AiSopTask $spec 'recovery'
    Assert ($recovered.verifications[-1].outcome -eq 'INTERRUPTED' -and $recovered.status -eq 'PAUSED') 'Interrupted result lost during recovery'
    Task Resume | Out-Null
    Fails { Task Verify } 'Task Verify failed'
    Task Run @{Profile='check'; Reason='Restore normal regression after interruption'} | Out-Null
    Task Complete | Out-Null
    Write-Output 'PASS: recovery, status consistency, project profiles, timeout, streaming, abrupt termination'
} finally {
    if ($runner) { if (-not $runner.HasExited) { $runner.Kill($true); $runner.WaitForExit(5000) | Out-Null }; $runner.Dispose() }
    foreach ($key in $saved.Keys) { [Environment]::SetEnvironmentVariable($key,$saved[$key]) }
    $resolved=[IO.Path]::GetFullPath($root)
    if ($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue }
}
