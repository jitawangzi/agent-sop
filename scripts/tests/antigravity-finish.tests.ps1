#requires -Version 7.0
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$sourceRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $sourceRoot 'scripts/hook-dispatcher.ps1')
. (Join-Path $sourceRoot 'scripts/hidden-process.ps1')
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('agy-finish-' + [guid]::NewGuid().ToString('N'))
$workspace = Join-Path $testRoot 'workspace'
$registryNames = @('SERVER_NEW_WORKFLOW_REGISTRY','SERVER_NEW_WORKFLOW_SESSION_REGISTRY',
    'SERVER_NEW_WORKFLOW_COMMAND_GRANT_REGISTRY','SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY',
    'SERVER_NEW_HOOK_DEDUP_REGISTRY','SERVER_NEW_HOOK_CORRELATION_REGISTRY','AI_SOP_GUARD_ROOT',
    'SERVER_NEW_SKIP_OWNER_GUARD','AI_SOP_SKIP_OWNER_GUARD')
$saved = @{}
$checks = 0
function Assert-Equal($Actual, $Expected, [string]$Message) {
    if ($Actual -cne $Expected) { throw "$Message Expected '$Expected', got '$Actual'." }
    $script:checks++
}
function Copy-Payload($Value) {
    ConvertFrom-AiSopJson ($Value | ConvertTo-Json -Depth 50 -Compress)
}
function Normalize($Payload) {
    ConvertTo-AiSopHookEvent -RawPayload ($Payload | ConvertTo-Json -Depth 50 -Compress) `
        -EventHint PRE_TOOL_USE -TrustedWorkspaceRoot $workspace -AcceptedAt ([DateTimeOffset]::UtcNow)
}
function Dispatch($Payload, [string]$Hint = 'PRE_TOOL_USE', [string]$Agent = 'ANTIGRAVITY') {
    Invoke-AiSopHookDispatcher -RawPayload ($Payload | ConvertTo-Json -Depth 50 -Compress) `
        -EventHint $Hint -AgentHint $Agent -TrustedWorkspaceRoot $workspace
}
function Snapshot([switch]$StateOnly) {
    @(Get-ChildItem -LiteralPath $testRoot -File -Recurse | Where-Object {
        -not $StateOnly -or $_.DirectoryName -cne $testRoot
    } | Sort-Object FullName | ForEach-Object {
        $_.FullName + ':' + (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
    }) -join "`n"
}
try {
    [IO.Directory]::CreateDirectory($workspace) | Out-Null
    foreach ($name in $registryNames) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name)
        if ($name -like 'SERVER_NEW_*REGISTRY') {
            [Environment]::SetEnvironmentVariable($name, (Join-Path $testRoot $name))
        } else { [Environment]::SetEnvironmentVariable($name, $null) }
    }
    $env:AI_SOP_GUARD_ROOT = Join-Path $workspace '.ai-sop'
    $fixture = ConvertFrom-AiSopJson ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fixtures/hooks/antigravity-pre-tool-finish.json')))
    $fixture.workspacePaths = @($workspace)
    $event = Normalize $fixture
    $guard = Get-AiSopGuardTargetDecision $event
    Write-Host "Native fixture: class=$($event.toolClass), guard=$($guard.Decision)/$($guard.ReasonCode)"
    Assert-Equal $event.toolClass 'SAFE_NON_EDIT' 'Native finish must be classified as result transport.'
    Assert-Equal $guard.Decision 'ALLOW' 'Guard must allow completion without an owner.'
    Assert-Equal (Get-AiSopGuardDecision -HookEvent $event -AcceptedAt ([DateTimeOffset]::UtcNow)).Decision 'ALLOW' 'Full guard does not require a task for completion.'
    Assert-Equal @($event.targetPaths).Count 0 'Completion has no edit targets.'
    $before = Snapshot
    $allowed = Dispatch $fixture
    Assert-Equal $allowed.Decision 'ALLOW' 'Unregistered read-only review must finish without Task Start.'
    Assert-Equal $allowed.ExitCode 0 'Native success exit code.'
    Assert-Equal $allowed.ReasonCode 'SAFE_NON_EDIT' 'Completion uses existing guard boundary.'
    Assert-Equal $allowed.Envelope '{"decision":"allow"}' 'No overwrite, grants or injected steps.'
    Assert-Equal (Snapshot) $before 'Completion must not create registry/workspace state.'

    # A completion cannot repair, revive or recover lifecycle state just to emit JSON.
    $txRoot = Get-AiSopWorkflowTransactionRegistryRoot -WorkspacePath $workspace
    [IO.Directory]::CreateDirectory($txRoot) | Out-Null
    [IO.File]::WriteAllText((Join-Path $txRoot 'unresolved.json'), '{unresolved')
    $before = Snapshot
    Assert-Equal (Dispatch $fixture).Decision 'ALLOW' 'Unresolved permissions do not block result transport.'
    Assert-Equal (Snapshot) $before 'Completion must not recover unresolved journals.'
    [IO.File]::Delete((Join-Path $txRoot 'unresolved.json'))

    $start = Copy-Payload $fixture; $start.Remove('toolCall'); $start.Remove('stepIdx')
    Assert-Equal (Dispatch $start 'PRE_INVOCATION').Decision 'ALLOW' 'Existing native lifecycle still starts.'
    $stop = Copy-Payload $start; $stop.fullyIdle = $true
    Assert-Equal (Dispatch $stop 'STOP').Decision 'ALLOW' 'Existing native lifecycle still ends.'
    $before = Snapshot
    Assert-Equal (Dispatch $fixture).Decision 'ALLOW' 'An ended review session may return its result.'
    Assert-Equal (Snapshot) $before 'Completion must not revive or renew an ended session.'

    # Result content is schema-neutral; nested strings are data, not executable tools.
    $nested = Copy-Payload $fixture
    $nested.toolCall.args = @{ result = @{ text = '完成'; nested = @(@{value=$null}, $true, 3) } }
    Assert-Equal (Normalize $nested).toolClass 'SAFE_NON_EDIT' 'No fixed review schema required.'
    $changed = Copy-Payload $fixture
    $changed.toolCall.args.materialPart.partId = 'part-2'
    Assert-Equal ((Normalize $changed).canonicalSemanticArgsSha256 -eq $event.canonicalSemanticArgsSha256) $false 'Bind complete nested result content.'

    foreach ($name in @('Finish','FINISH','finish_write','mcp__native__finish','run_command','write_to_file','invoke_subagent')) {
        $negative = Copy-Payload $fixture; $negative.toolCall.name = $name
        Assert-Equal (Dispatch $negative).Decision 'DENY' "Alias/write/shell/delegation stays denied: $name"
    }
    foreach ($argsValue in @(@{CommandLine='Set-Content x bad'}, @{file_path='x';content='bad'},
        @{path='x';content='bad'},
        @{operation='write';path='x'}, @{toolCall=@{name='write_to_file';args=@{}}},
        @{Subagents=@(@{Prompt='modify'})})) {
        $negative = Copy-Payload $fixture; $negative.toolCall.args = $argsValue
        Assert-Equal (Normalize $negative).toolClass 'UNKNOWN' 'Conflicting operational arguments stay unknown.'
        Assert-Equal (Dispatch $negative).Decision 'DENY' 'Operational arguments cannot borrow finish permission.'
    }
    foreach ($badValue in @($null, 'text', @('array'), 1)) {
        $negative = Copy-Payload $fixture; $negative.toolCall.args = $badValue
        Assert-Equal (Dispatch $negative).Decision 'DENY' 'Non-object arguments stay denied.'
    }
    foreach ($pair in @(@('stepIdx',-1), @('stepIdx','4'), @('modelName',@{operation='write'}), @('isBattleMode','false'))) {
        $negative = Copy-Payload $fixture; $negative[$pair[0]] = $pair[1]
        Assert-Equal (Dispatch $negative).Decision 'DENY' 'Malformed native metadata stays denied.'
    }
    $minimal = @{conversationId='minimal-finish';workspacePaths=@($workspace);toolCall=@{name='finish';args=@{}}}
    Assert-Equal (Dispatch $minimal).Decision 'ALLOW' 'Optional native metadata and a fixed output schema are not required.'
    foreach ($field in @('operation','command','tool_input')) {
        $negative = Copy-Payload $fixture; $negative.toolCall[$field] = 'write'
        Assert-Equal (Dispatch $negative).Decision 'DENY' 'Ambiguous tool envelope stays denied.'
        $negative = Copy-Payload $fixture; $negative[$field] = 'write'
        Assert-Equal (Dispatch $negative).Decision 'DENY' 'Operational root fields stay denied.'
    }
    $hybrid = Copy-Payload $fixture; $hybrid.session_id='foreign'; $hybrid.tool_name='Write'
    Assert-Equal (Dispatch $hybrid).Decision 'DENY' 'Hybrid native identities stay denied.'
    $wrongProvider = @{session_id='foreign';cwd=$workspace;hook_event_name='PreToolUse';tool_name='finish';tool_input=$fixture.toolCall.args;tool_use_id='fixture-call'}
    Assert-Equal (Normalize $wrongProvider).toolClass 'UNKNOWN' 'Claude cannot borrow native finish.'
    Assert-Equal (Dispatch $wrongProvider).Decision 'DENY' 'Trusted provider mismatch stays denied.'
    Assert-Equal (Dispatch $fixture 'STOP').Decision 'DENY' 'Tool/event conflict stays denied.'
    $policy = Get-AiSopToolPolicy -PolicyPath (Join-Path $sourceRoot 'config/hook-tool-policy.json')
    foreach ($shape in @('CLAUDE_PRE_TOOL_USE','COPILOT_CLAUDE_COMPAT','COPILOT_GITHUB_NATIVE','CURSOR_PRE_TOOL_USE','CODEX','PI')) {
        Assert-Equal (Resolve-AiSopToolPolicy -Policy $policy -NativeShape $shape -ToolName 'finish' -Arguments $fixture.toolCall.args).ToolClass 'UNKNOWN' "Other provider cannot borrow finish: $shape"
    }
    $ambiguousPolicy = Copy-Payload $policy
    $ambiguousPolicy.tools += @($ambiguousPolicy.tools | Where-Object {$_.match.value -ceq 'finish'})
    Assert-Equal (Resolve-AiSopToolPolicy -Policy $ambiguousPolicy -NativeShape ANTIGRAVITY -ToolName finish -Arguments $fixture.toolCall.args).ToolClass 'UNKNOWN' 'Ambiguous policy cannot grant completion.'
    $write = Copy-Payload $fixture
    $write.toolCall = @{name='write_to_file';args=@{TargetFile=(Join-Path $workspace 'source.txt');CodeContent='bad';Overwrite=$true}}
    Assert-Equal (Normalize $write).toolClass 'FILE_EDIT' 'Write retains edit classification.'
    Assert-Equal (Dispatch $write).Decision 'DENY' 'Writes still require lifecycle and owner.'

    # Exercise the executable dispatcher in an owned installed-layout mock, not a string classifier.
    [IO.Directory]::CreateDirectory((Join-Path $workspace '.ai-sop')) | Out-Null
    foreach ($dir in @('scripts','schemas','config')) {
        Copy-Item -LiteralPath (Join-Path $sourceRoot $dir) -Destination (Join-Path $workspace '.ai-sop') -Recurse
    }
    $payloadFile = Join-Path $testRoot 'payload.json'
    $runnerFile = Join-Path $testRoot 'invoke-dispatcher.ps1'
    [IO.File]::WriteAllText($runnerFile, @'
param([string]$PayloadFile, [string]$Dispatcher)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
[IO.File]::ReadAllText($PayloadFile) | & (Get-Process -Id $PID).Path -NoProfile -File $Dispatcher -EventHint PRE_TOOL_USE -AgentHint ANTIGRAVITY
$dispatchExit = $LASTEXITCODE
exit $dispatchExit
'@)
    foreach ($case in @(@{payload=$fixture;decision='allow'}, @{payload=$write;decision='deny'})) {
        [IO.File]::WriteAllText($payloadFile, ($case.payload | ConvertTo-Json -Compress -Depth 50), [Text.UTF8Encoding]::new($false))
        $stateBefore = Snapshot -StateOnly
        $child = Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path `
            -ArgumentList @('-NoProfile','-File',$runnerFile,'-PayloadFile',$payloadFile,'-Dispatcher',(Join-Path $workspace '.ai-sop/scripts/hook-dispatcher.ps1')) `
            -RedirectStandardOutput (Join-Path $testRoot 'stdout.txt') `
            -RedirectStandardError (Join-Path $testRoot 'stderr.txt') -TimeoutSeconds 30 -CloseStandardInput -PassThru
        try {
            $child.WaitForExit()
            Assert-Equal $child.ExitCode 0 'Antigravity consumes native JSON decisions on exit zero.'
            $native = ConvertFrom-AiSopJson ([IO.File]::ReadAllText((Join-Path $testRoot 'stdout.txt')))
            Assert-Equal $native.decision $case.decision 'Real dispatcher native decision.'
            if ($case.decision -ceq 'allow') {
                Assert-Equal (Snapshot -StateOnly) $stateBefore 'Real completion process must not mutate workspace or registries.'
            }
        } finally { $child.Dispose() }
    }
    Write-Output "All Antigravity finish tests passed ($checks assertions)."
} finally {
    foreach ($name in $registryNames) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    if ([IO.Directory]::Exists($testRoot)) { [IO.Directory]::Delete($testRoot, $true) }
}
