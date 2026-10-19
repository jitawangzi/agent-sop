#requires -Version 7.0

[CmdletBinding()]
param([ValidateSet('ANTIGRAVITY','CURSOR','PI','CLAUDE_CODE','CODEX')][string]$Agent='CURSOR')

$ErrorActionPreference = 'Stop'
$SourceScripts = $PSScriptRoot
$SourceEngine = Split-Path -Parent $SourceScripts
. (Join-Path $SourceScripts 'path-identity.ps1')
$TempRoot = Resolve-PhysicalPathIdentity ([IO.Path]::GetTempPath())
$ProbeRoot = Resolve-PhysicalPathIdentity (Join-Path $TempRoot ('guard-live-' + [guid]::NewGuid().ToString('N')))
$WorkspaceRoot = Join-Path $ProbeRoot 'workspace'
$ProbeEngine = Join-Path $WorkspaceRoot '.ai-sop'
$Feature = 'GuardLiveProbe'
$TaskId = 'guard-probe'
$SessionId = 'cursor-live-' + [guid]::NewGuid().ToString('N')
$FeatureSpecDir = Join-Path $WorkspaceRoot ".ai-workspace/specs/features/$Feature"
$TaskPath = Join-Path $FeatureSpecDir "tasks/$TaskId/task.json"
$TaskScript = Join-Path $ProbeEngine 'scripts/workflow-task.ps1'
$SavedEnvironment = @{}
$EnvironmentOverrides = [ordered]@{
    AI_SOP_REGISTRY_ROOT = (Join-Path $ProbeRoot 'registry')
    AI_SOP_OWNER_REGISTRY = (Join-Path $ProbeRoot 'owners')
    AI_SOP_SESSION_REGISTRY = (Join-Path $ProbeRoot 'sessions')
    AI_SOP_COMMAND_GRANT_REGISTRY = (Join-Path $ProbeRoot 'grants')
    AI_SOP_TRANSACTION_REGISTRY = (Join-Path $ProbeRoot 'transactions')
    SERVER_NEW_WORKFLOW_REGISTRY = (Join-Path $ProbeRoot 'owners')
    SERVER_NEW_WORKFLOW_SESSION_REGISTRY = (Join-Path $ProbeRoot 'sessions')
    SERVER_NEW_WORKFLOW_COMMAND_GRANT_REGISTRY = (Join-Path $ProbeRoot 'grants')
    SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY = (Join-Path $ProbeRoot 'transactions')
    SERVER_NEW_HOOK_DEDUP_REGISTRY = (Join-Path $ProbeRoot 'dedup')
    SERVER_NEW_HOOK_CORRELATION_REGISTRY = (Join-Path $ProbeRoot 'correlation')
    AI_SOP_GUARD_ROOT = $ProbeEngine
    AI_SOP_SKIP_OWNER_GUARD = '0'
    SERVER_NEW_SKIP_OWNER_GUARD = '0'
    AI_SESSION_ID = 'unrelated-parent-session'
    AI_SOP_INVOCATION_SESSION_ID = 'unrelated-explicit-session'
}
$ProbeCreated = $false
$LocationPushed = $false
$ProbeResult = $null
$script:LiveStepCounter=0

function Assert-LiveProbe {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Invoke-LiveDispatch {
    param([string]$RawPayload, [string]$EventHint = 'PRE_TOOL_USE')
    if ($Agent -eq 'ANTIGRAVITY' -and $EventHint -eq 'SESSION_START') { $EventHint='PRE_INVOCATION' }
    $hint=if ($Agent -in @('CODEX','PI')) { $Agent } else { '' }
    Invoke-AiSopHookDispatcher -RawPayload $RawPayload -EventHint $EventHint `
        -AgentHint $hint `
        -TrustedWorkspaceRoot $WorkspaceRoot -AcceptedAt ([DateTimeOffset]::UtcNow)
}

function New-LiveCursorPayload {
    param(
        [ValidateSet('START','TOOL')][string]$Kind = 'TOOL',
        [string]$NativeSession = $SessionId,
        [string]$ToolName = '',
        [hashtable]$ToolInput = @{},
        [string]$Occurrence = ([guid]::NewGuid().ToString('N'))
    )
    if ($Agent -ne 'CURSOR') {
        if ($ToolName -eq 'Shell') { $ToolName='Bash' }
        if ($Agent -eq 'ANTIGRAVITY') {
            $native=@{conversationId=$NativeSession;workspacePaths=@($WorkspaceRoot);transcriptPath=(Join-Path $WorkspaceRoot 'transcript.jsonl');artifactDirectoryPath=$WorkspaceRoot;modelName='auto'}
            if ($Kind -eq 'START') { $native.invocationNum=1; $native.initialNumSteps=0 }
            else { $native.toolCall=@{name=$ToolName;args=$ToolInput}; $native.stepIdx=++$script:LiveStepCounter }
            return ($native | ConvertTo-Json -Compress -Depth 20)
        }
        if ($Agent -eq 'CODEX' -and $ToolName -eq 'Edit') {
            $ToolName='apply_patch'; $ToolInput=@{command="*** Begin Patch`n*** Update File: $($ToolInput.file_path)`n@@`n-before`n+after`n*** End Patch"}
        }
        if ($Agent -eq 'PI') {
            if ($ToolName -eq 'Edit') { $ToolInput=@{path=$ToolInput.file_path;oldText='before';newText='after'} }
            if ($ToolName -eq 'Read') { $ToolInput=@{path=$ToolInput.file_path} }
            $ToolName=$ToolName.ToLowerInvariant()
        }
        $native=@{session_id=$NativeSession;cwd=$WorkspaceRoot}
        if ($Kind -eq 'START') { $native.hook_event_name='SessionStart'; $native.source='startup' }
        else { $native.hook_event_name='PreToolUse';$native.tool_name=$ToolName;$native.tool_input=$ToolInput;$native.tool_use_id="tool-$Occurrence" }
        return ($native | ConvertTo-Json -Compress -Depth 20)
    }
    if ($Kind -eq 'START') {
        return (@{ session_id=$NativeSession; is_background_agent=$false; composer_mode='agent' } | ConvertTo-Json -Compress)
    }
    return ([ordered]@{
        conversation_id=$NativeSession; generation_id="generation-$Occurrence"
        hook_event_name='preToolUse'; workspace_roots=@($WorkspaceRoot)
        tool_name=$ToolName; tool_input=$ToolInput; tool_use_id="tool-$Occurrence"; cwd=$WorkspaceRoot
    } | ConvertTo-Json -Compress -Depth 20)
}

function Invoke-LiveTask {
    param([ValidateSet('Start','Resume','Suspend','Cancel')][string]$Operation)
    $command = "pwsh -NoProfile -File './.ai-sop/scripts/workflow-task.ps1' -Operation '$Operation' -Feature '$Feature' -TaskId '$TaskId' -Agent $Agent -NativeSessionId '$SessionId'"
    if ($Operation -eq 'Start') { $command += " -Tier T2 -Objective '隔离验证写前任务检查'" }
    $hook = Invoke-LiveDispatch (New-LiveCursorPayload -ToolName Shell -ToolInput @{command=$command})
    Assert-LiveProbe ($hook.Decision -eq 'ALLOW' -and $hook.ReasonCode -eq 'TASK_BOOTSTRAP_COMMAND') (
        "Task $Operation 引导命令被拒绝或走错路由：$($hook.ReasonCode)"
    )
    $arguments = @{ Operation=$Operation; WorkspacePath=$WorkspaceRoot; Feature=$Feature; TaskId=$TaskId; Agent=$Agent; NativeSessionId=$SessionId }
    if ($Operation -eq 'Start') { $arguments.Tier='T2'; $arguments.Objective='隔离验证写前任务检查' }
    & $TaskScript @arguments 3>&1 | Out-Null
    Assert-LiveProbe ($LASTEXITCODE -eq 0) "Task $Operation 执行失败：$LASTEXITCODE"
    Assert-LiveProbe ($env:AI_SOP_INVOCATION_SESSION_ID -ceq 'unrelated-explicit-session') 'Task 命令泄漏了临时会话环境。'
}

function Invoke-LiveEdit {
    param([string]$RelativePath)
    Invoke-LiveDispatch (New-LiveCursorPayload -ToolName Edit -ToolInput @{
        file_path=(Join-Path $WorkspaceRoot $RelativePath); old_string='before'; new_string='after'
    })
}

try {
    foreach ($name in $EnvironmentOverrides.Keys) {
        $SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    Assert-LiveProbe (-not (Test-Path -LiteralPath $ProbeRoot)) '隔离探测目录已存在，拒绝复用。'
    [IO.Directory]::CreateDirectory($WorkspaceRoot) | Out-Null
    $ProbeCreated = $true
    $WorkspaceRoot = Resolve-PhysicalPathIdentity $WorkspaceRoot
    [IO.Directory]::CreateDirectory((Join-Path $ProbeEngine 'scripts')) | Out-Null
    # 复制运行时文件到临时宿主，不读取或改写真实宿主的功能记录及防护开关。
    Get-ChildItem -LiteralPath $SourceScripts -Filter '*.ps1' -File | ForEach-Object {
        Copy-Item -LiteralPath $_.FullName -Destination (Join-Path $ProbeEngine 'scripts')
    }
    foreach ($directory in @('schemas','config')) {
        Copy-Item -LiteralPath (Join-Path $SourceEngine $directory) -Destination $ProbeEngine -Recurse
    }
    [IO.Directory]::CreateDirectory((Join-Path $WorkspaceRoot 'src')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $WorkspaceRoot 'docs')) | Out-Null
    [IO.File]::WriteAllText((Join-Path $WorkspaceRoot 'src/probe.txt'), 'before')
    [IO.File]::WriteAllText((Join-Path $WorkspaceRoot 'docs/probe.md'), 'before')
    foreach ($name in $EnvironmentOverrides.Keys) {
        [Environment]::SetEnvironmentVariable($name, $EnvironmentOverrides[$name])
    }
    Push-Location -LiteralPath $WorkspaceRoot
    $LocationPushed = $true
    . (Join-Path $ProbeEngine 'scripts/hook-dispatcher.ps1')

    $start = Invoke-LiveDispatch (New-LiveCursorPayload -Kind START) -EventHint SESSION_START
    Assert-LiveProbe ($start.Decision -eq 'ALLOW') "Cursor 会话注册失败：$($start.ReasonCode)"
    $contextHint=if ($Agent -eq 'ANTIGRAVITY') { 'PRE_INVOCATION' } else { 'SESSION_START' }
    $context=Add-AiSopHarnessSessionContext $start (New-LiveCursorPayload -Kind START) $contextHint
    if ($Agent -ne 'PI') { Assert-LiveProbe ($context.Contains('-NativeSessionId') -and $context.Contains($SessionId)) '原生会话上下文未传入客户端。' }
    foreach ($relativePath in @('src/probe.txt','docs/probe.md')) {
        $withoutTask = Invoke-LiveEdit $relativePath
        Assert-LiveProbe ($withoutTask.Decision -eq 'DENY') "缺少任务时仍允许编辑：$relativePath"
    }
    $read = Invoke-LiveDispatch (New-LiveCursorPayload -ToolName Read -ToolInput @{file_path=(Join-Path $WorkspaceRoot 'docs/probe.md')})
    Assert-LiveProbe ($read.Decision -eq 'ALLOW') '只读查询不应要求修改任务。'
    if ($Agent -eq 'CODEX') {
        $view=Invoke-LiveDispatch (New-LiveCursorPayload -ToolName view_image -ToolInput @{path=(Join-Path $WorkspaceRoot 'docs/probe.md')})
        Assert-LiveProbe ($view.Decision -eq 'ALLOW') 'Codex 原生只读工具不应要求任务。'
        $spawn=Invoke-LiveDispatch (New-LiveCursorPayload -ToolName spawn_agent -ToolInput @{message='执行修改'})
        Assert-LiveProbe ($spawn.Decision -eq 'DENY') 'Codex 子 Agent 不得在未登记任务时开始执行。'
        $unknownRead=Invoke-LiveDispatch (New-LiveCursorPayload -ToolName view_image_extra -ToolInput @{})
        Assert-LiveProbe ($unknownRead.Decision -eq 'DENY') '只读名称前缀不得放行未知工具。'
    }

    Invoke-LiveTask Start
    $task = Get-Content -LiteralPath $TaskPath -Raw | ConvertFrom-Json
    $ownerPath = Join-Path (Get-AiSopWorkflowOwnerRegistryRoot -WorkspacePath $WorkspaceRoot) ($Feature.ToLowerInvariant() + '.json')
    $owner = Get-Content -LiteralPath $ownerPath -Raw | ConvertFrom-Json
    Assert-LiveProbe ($task.status -eq 'ACTIVE' -and $task.tier -eq 'T2' -and $owner.taskId -ceq $TaskId -and
        $owner.schemaVersion -eq '1.1' -and $owner.status -eq 'ACTIVE' -and $owner.sessionBinding.sessionKey -ceq $start.SessionKey) (
        'Task Start 未建立绑定当前会话的合法 T2 任务。'
    )
    foreach ($relativePath in @('src/probe.txt','docs/probe.md')) {
        $edit = Invoke-LiveEdit $relativePath
        Assert-LiveProbe ($edit.Decision -eq 'ALLOW' -and $edit.ReasonCode -eq 'EXACT_OWNER_AUTHORIZED') (
            "合法活动任务未能授权编辑：$relativePath / $($edit.ReasonCode)"
        )
    }
    $shell = Invoke-LiveDispatch (New-LiveCursorPayload -ToolName Shell -ToolInput @{command='Get-Location'})
    Assert-LiveProbe ($shell.Decision -eq 'ALLOW' -and $shell.ReasonCode -eq 'EXACT_OWNER_AUTHORIZED') '合法活动任务未能授权普通 Shell。'

    Invoke-LiveTask Suspend
    Assert-LiveProbe ((Invoke-LiveEdit 'docs/probe.md').Decision -eq 'DENY') '暂停任务仍可编辑普通文档。'
    Invoke-LiveTask Resume
    Assert-LiveProbe ((Invoke-LiveEdit 'docs/probe.md').Decision -eq 'ALLOW') 'Resume 后仍无法编辑普通文档。'

    $unknown = Invoke-LiveDispatch (New-LiveCursorPayload -ToolName unknown_live_tool)
    Assert-LiveProbe ($unknown.Decision -eq 'DENY') '未知工具被意外放行。'
    Assert-LiveProbe ((Invoke-LiveDispatch '{').Decision -eq 'DENY') '损坏的工具输入被意外放行。'

    # 性能采样走真实只读路径，不借用无任务的编辑绕过作为基准。
    $perfSession = 'cursor-perf-' + [guid]::NewGuid().ToString('N')
    $perfStart = Invoke-LiveDispatch (New-LiveCursorPayload -Kind START -NativeSession $perfSession) -EventHint SESSION_START
    Assert-LiveProbe ($perfStart.Decision -eq 'ALLOW') '只读性能探测会话注册失败。'
    $samples = @()
    foreach ($index in 1..20) {
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-LiveDispatch (New-LiveCursorPayload -NativeSession $perfSession -ToolName Read `
            -ToolInput @{file_path=(Join-Path $WorkspaceRoot 'docs/probe.md')} -Occurrence "perf-$index")
        $watch.Stop()
        Assert-LiveProbe ($result.Decision -eq 'ALLOW') '无任务会话的只读性能探测被拒绝。'
        $samples += $watch.ElapsedMilliseconds
    }
    $orderedSamples = @($samples | Sort-Object)
    $normalPathMaxMs = ($samples | Measure-Object -Maximum).Maximum
    Assert-LiveProbe ($normalPathMaxMs -lt 1000) "只读探测路径超过 1000ms：${normalPathMaxMs}ms。"

    # 探测并未实现业务目标，不制造编译/测试证据或调用 Complete 冒充交付。
    Invoke-LiveTask Cancel
    $cancelled = Get-Content -LiteralPath $TaskPath -Raw | ConvertFrom-Json
    Assert-LiveProbe ($cancelled.status -eq 'CANCELLED') '探测任务未通过 Cancel 关闭。'
    Assert-LiveProbe ((Invoke-LiveEdit 'docs/probe.md').Decision -eq 'DENY') '取消任务后仍可编辑普通文档。'
    $ProbeResult = [ordered]@{
        result='PASS'; agent=$Agent; scope='IN_PROCESS_DISPATCHER'; workspaceIsolated=$true; ownerRegistryIsolated=$true
        ownerSchemaVersion='1.1'; taskTier='T2'; finalTaskStatus='CANCELLED'
        sourceAndDocumentEditsRequireTask=$true; currentOwner1_0UsedForAuthorization=$false
        samplePath='READ_WITHOUT_TASK'; sampleCount=$samples.Count
        p50Ms=$orderedSamples[[Math]::Floor(($orderedSamples.Count-1)*0.50)]
        p95Ms=$orderedSamples[[Math]::Floor(($orderedSamples.Count-1)*0.95)]
        normalPathMaxMs=$normalPathMaxMs; clientHookCertified=$false
        concern='仅验证隔离宿主中的 dispatcher 与原生事件载荷，不代表真实客户端 Hook 接线或客户端超时认证。'
    }
} catch {
    $ProbeResult = [ordered]@{ result='FAIL'; scope='IN_PROCESS_DISPATCHER'; errorCode='LIVE_PROBE_FAILED'; errorMessage=$_.Exception.Message }
} finally {
    try {
        # 中途失败也优先用正常任务入口关闭探测任务，再清理隔离数据。
        if (Test-Path -LiteralPath $TaskPath) {
            $remaining = Get-Content -LiteralPath $TaskPath -Raw | ConvertFrom-Json
            if ($remaining.status -eq 'PAUSED') { Invoke-LiveTask Resume; $remaining.status='ACTIVE' }
            if ($remaining.status -eq 'ACTIVE') { Invoke-LiveTask Cancel }
        }
    } catch {
        [Console]::Error.WriteLine("[WARN] 探测任务收尾失败：$($_.Exception.Message)")
        $ProbeResult = [ordered]@{ result='FAIL'; scope='IN_PROCESS_DISPATCHER'; errorCode='LIVE_PROBE_CLEANUP_FAILED'; errorMessage=$_.Exception.Message }
    } finally {
        if ($LocationPushed) { Pop-Location }
        foreach ($name in $SavedEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $SavedEnvironment[$name])
        }
    }
    if ($ProbeCreated -and (Test-Path -LiteralPath $ProbeRoot)) {
        try {
            # 删除前确认最终物理路径仍为本次创建的临时根，不向其他目录递归。
            $resolvedProbe = Resolve-PhysicalPathIdentity $ProbeRoot
            $comparison = if ([OperatingSystem]::IsWindows()) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
            Assert-LiveProbe ($resolvedProbe.Equals($ProbeRoot,$comparison) -and
                (Resolve-PhysicalPathIdentity (Split-Path -Parent $resolvedProbe)).Equals($TempRoot,$comparison) -and
                (Split-Path -Leaf $resolvedProbe) -match '^guard-live-[0-9a-f]{32}$') '探测清理路径不在预期临时目录中。'
            Remove-Item -LiteralPath $resolvedProbe -Recurse -Force
        } catch {
            [Console]::Error.WriteLine("[WARN] 隔离目录清理失败：$($_.Exception.Message)")
            $ProbeResult = [ordered]@{ result='FAIL'; scope='IN_PROCESS_DISPATCHER'; errorCode='LIVE_PROBE_CLEANUP_FAILED'; errorMessage=$_.Exception.Message }
        }
    }
}
$ProbeResult | ConvertTo-Json -Depth 10
if ($ProbeResult.result -eq 'PASS') { exit 0 }
exit 1
