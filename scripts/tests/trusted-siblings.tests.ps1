#requires -Version 7.0

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$ScriptsRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $ScriptsRoot "hook-dispatcher.ps1")

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "ASSERTION FAILED: $Message" }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -cne $Expected) {
        throw "ASSERTION FAILED: $Message (Expected '$Expected', got '$Actual')"
    }
}

function Assert-ThrowsCode {
    param([string]$Code, [scriptblock]$Action, [string]$Message)
    $threw = $false
    try {
        & $Action | Out-Null
    } catch {
        $threw = $true
        if ($_.Exception.Message -cne $Code) {
            throw "ASSERTION FAILED: $Message (Expected code '$Code', got '$($_.Exception.Message)')"
        }
    }
    if (-not $threw) {
        throw "ASSERTION FAILED: $Message (Expected throw '$Code', but succeeded)"
    }
}

$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("ai-sop-trusted-siblings-" + [guid]::NewGuid().ToString("N"))
$Workspace = Join-Path $TestRoot "host-repo"
$ReadOnlySibling = Join-Path $TestRoot "sibling-ro"
$ReadWriteSibling = Join-Path $TestRoot "sibling-rw"
$UntrustedSibling = Join-Path $TestRoot "sibling-untrusted"
$OutsideDir = Join-Path $TestRoot "outside-secret"
$RegistryRoot = Join-Path $TestRoot "registry"

$savedEnv = @{}
foreach ($name in @(
    "AI_SOP_GUARD_ROOT",
    "AI_SOP_REGISTRY_ROOT",
    "AI_SOP_OWNER_REGISTRY",
    "AI_SOP_SESSION_REGISTRY",
    "AI_SOP_COMMAND_GRANT_REGISTRY",
    "AI_SOP_TRANSACTION_REGISTRY",
    "SERVER_NEW_HOOK_DEDUP_REGISTRY",
    "SERVER_NEW_HOOK_CORRELATION_REGISTRY",
    "AI_SOP_SKIP_OWNER_GUARD",
    "SERVER_NEW_SKIP_OWNER_GUARD"
)) {
    $savedEnv[$name] = [Environment]::GetEnvironmentVariable($name)
}

try {
    foreach ($dir in @(
        (Join-Path $Workspace ".ai-sop"),
        (Join-Path $Workspace ".ai-workspace/.runtime"),
        (Join-Path $Workspace "src"),
        $ReadOnlySibling,
        $ReadWriteSibling,
        $UntrustedSibling,
        $OutsideDir,
        $RegistryRoot
    )) {
        [System.IO.Directory]::CreateDirectory($dir) | Out-Null
    }

    $wsFile = Join-Path $Workspace "src/App.java"
    $roFile = Join-Path $ReadOnlySibling "notes.md"
    $rwFile = Join-Path $ReadWriteSibling "README.md"
    $untrustedFile = Join-Path $UntrustedSibling "secret.txt"
    $outsideFile = Join-Path $OutsideDir "cred.txt"
    [System.IO.File]::WriteAllText($wsFile, "class App {}")
    [System.IO.File]::WriteAllText($roFile, "readonly sibling")
    [System.IO.File]::WriteAllText($rwFile, "readwrite sibling")
    [System.IO.File]::WriteAllText($untrustedFile, "untrusted")
    [System.IO.File]::WriteAllText($outsideFile, "secret")

    $env:AI_SOP_GUARD_ROOT = Join-Path $Workspace ".ai-sop"
    $env:AI_SOP_REGISTRY_ROOT = $RegistryRoot
    $env:AI_SOP_OWNER_REGISTRY = Join-Path $RegistryRoot "owners"
    $env:AI_SOP_SESSION_REGISTRY = Join-Path $RegistryRoot "sessions"
    $env:AI_SOP_COMMAND_GRANT_REGISTRY = Join-Path $RegistryRoot "grants"
    $env:AI_SOP_TRANSACTION_REGISTRY = Join-Path $RegistryRoot "transactions"
    $env:SERVER_NEW_HOOK_DEDUP_REGISTRY = Join-Path $RegistryRoot "dedup"
    $env:SERVER_NEW_HOOK_CORRELATION_REGISTRY = Join-Path $RegistryRoot "correlation"
    $env:AI_SOP_SKIP_OWNER_GUARD = "0"
    $env:SERVER_NEW_SKIP_OWNER_GUARD = "0"

    $configPath = Join-Path $Workspace ".ai-workspace/.runtime/trusted-siblings.json"
    $now = [DateTimeOffset]::UtcNow
    $step = 0

    function New-AgToolRaw {
        param(
            [string]$ToolName,
            [hashtable]$ToolArgs,
            [string[]]$WorkspacePaths = @($ReadWriteSibling, $Workspace),
            [string]$SessionId = "ag-sibling-session"
        )
        $script:step++
        return ([ordered]@{
            conversationId = $SessionId
            workspacePaths = @($WorkspacePaths)
            stepIdx = $script:step
            toolCall = [ordered]@{
                name = $ToolName
                args = $ToolArgs
            }
        } | ConvertTo-Json -Compress -Depth 20)
    }

    # 1) Default (no .trusted-siblings.json): cross-repo read/edit remains denied (zero regression).
    $noCfgRead = Invoke-AiSopHookDispatcher `
        -RawPayload (New-AgToolRaw -ToolName "read_file" -ToolArgs @{ Path = $rwFile }) `
        -EventHint PRE_TOOL_USE `
        -TrustedWorkspaceRoot $Workspace `
        -AgentHint ANTIGRAVITY `
        -AcceptedAt $now
    Assert-Equal $noCfgRead.Decision "DENY" "Without config, sibling read must be denied"
    Assert-Equal $noCfgRead.ReasonCode "EDIT_PATH_OUTSIDE_WORKSPACE" "Without config, sibling read reason must be EDIT_PATH_OUTSIDE_WORKSPACE"

    # 2) Write valid .trusted-siblings.json with read + read_write siblings + nonexistent sibling (gracefully skipped).
    $missingSibling = Join-Path $TestRoot "temporarily-unmounted"
    [System.IO.File]::WriteAllText($configPath, ([ordered]@{
        schemaVersion = "1.0"
        siblings = @(
            [ordered]@{ path = $ReadOnlySibling; access = "read" },
            [ordered]@{ path = $ReadWriteSibling; access = "read_write" },
            [ordered]@{ path = $missingSibling; access = "read" }
        )
    } | ConvertTo-Json -Depth 5))

    # 3) Read-only sibling: read_file and read-only shell ALLOWED; edit_file and write shell DENIED.
    $roRead = Invoke-AiSopHookDispatcher `
        -RawPayload (New-AgToolRaw -ToolName "read_file" -ToolArgs @{ Path = $roFile } -WorkspacePaths @($ReadOnlySibling, $Workspace)) `
        -EventHint PRE_TOOL_USE `
        -TrustedWorkspaceRoot $Workspace `
        -AgentHint ANTIGRAVITY `
        -AcceptedAt $now.AddSeconds(1)
    Assert-Equal $roRead.Decision "ALLOW" "read sibling read_file must be allowed"
    Assert-Equal $roRead.ReasonCode "SAFE_NON_EDIT" "read sibling read_file must be SAFE_NON_EDIT"

    $roShell = Invoke-AiSopHookDispatcher `
        -RawPayload (New-AgToolRaw -ToolName "run_command" -ToolArgs @{ CommandLine = "Get-ChildItem . -File"; Cwd = $ReadOnlySibling; WaitMsBeforeAsync = 1000 } -WorkspacePaths @($ReadOnlySibling, $Workspace)) `
        -EventHint PRE_TOOL_USE `
        -TrustedWorkspaceRoot $Workspace `
        -AgentHint ANTIGRAVITY `
        -AcceptedAt $now.AddSeconds(2)
    Assert-Equal $roShell.Decision "ALLOW" "read sibling whitelisted read-only shell must be allowed"
    Assert-Equal $roShell.ReasonCode "READ_ONLY_SHELL_COMMAND" "read sibling shell reason must be READ_ONLY_SHELL_COMMAND"
    $roShellEnv = $roShell.Envelope | ConvertFrom-Json
    Assert-Equal $roShellEnv.overwrite.Cwd (Resolve-PhysicalPathIdentity $ReadOnlySibling) "read-only shell Cwd must pin to sibling physical path"

    $roEdit = Invoke-AiSopHookDispatcher `
        -RawPayload (New-AgToolRaw -ToolName "edit_file" -ToolArgs @{ Path = $roFile; Target = "readonly"; Replacement = "hacked" } -WorkspacePaths @($ReadOnlySibling, $Workspace)) `
        -EventHint PRE_TOOL_USE `
        -TrustedWorkspaceRoot $Workspace `
        -AgentHint ANTIGRAVITY `
        -AcceptedAt $now.AddSeconds(3)
    Assert-Equal $roEdit.Decision "DENY" "read-only sibling edit must be denied"
    Assert-Equal $roEdit.ReasonCode "EDIT_PATH_OUTSIDE_WORKSPACE" "read-only sibling edit must fail with EDIT_PATH_OUTSIDE_WORKSPACE"

    # 4) Read-write sibling: read_file, edit_file, write_file ALLOWED statelessly without workspace Task;
    #    session/owner registries in workspace remain completely untouched.
    $rwRead = Invoke-AiSopHookDispatcher `
        -RawPayload (New-AgToolRaw -ToolName "read_file" -ToolArgs @{ Path = $rwFile }) `
        -EventHint PRE_TOOL_USE `
        -TrustedWorkspaceRoot $Workspace `
        -AgentHint ANTIGRAVITY `
        -AcceptedAt $now.AddSeconds(4)
    Assert-Equal $rwRead.Decision "ALLOW" "read_write sibling read_file must be allowed"

    $rwEdit = Invoke-AiSopHookDispatcher `
        -RawPayload (New-AgToolRaw -ToolName "edit_file" -ToolArgs @{ Path = $rwFile; Target = "readwrite"; Replacement = "updated" }) `
        -EventHint PRE_TOOL_USE `
        -TrustedWorkspaceRoot $Workspace `
        -AgentHint ANTIGRAVITY `
        -AcceptedAt $now.AddSeconds(5)
    Assert-Equal $rwEdit.Decision "ALLOW" "read_write sibling edit_file must be allowed"
    Assert-Equal $rwEdit.ReasonCode "TRUSTED_SIBLING_EDIT" "read_write sibling edit reason must be TRUSTED_SIBLING_EDIT"

    $rwWrite = Invoke-AiSopHookDispatcher `
        -RawPayload (New-AgToolRaw -ToolName "write_file" -ToolArgs @{ Path = (Join-Path $ReadWriteSibling "new.md"); Content = "ok"; Overwrite = $true }) `
        -EventHint PRE_TOOL_USE `
        -TrustedWorkspaceRoot $Workspace `
        -AgentHint ANTIGRAVITY `
        -AcceptedAt $now.AddSeconds(6)
    Assert-Equal $rwWrite.Decision "ALLOW" "read_write sibling write_file must be allowed"
    Assert-Equal $rwWrite.ReasonCode "TRUSTED_SIBLING_EDIT" "read_write sibling write_file reason must be TRUSTED_SIBLING_EDIT"

    Assert-True (-not (Test-Path -LiteralPath $env:AI_SOP_OWNER_REGISTRY)) "Trusted sibling edits must not create host owner registry state"
    Assert-True (-not (Test-Path -LiteralPath $env:AI_SOP_SESSION_REGISTRY)) "Trusted sibling edits must not register host session state"

    # 5) Host workspace STILL strictly guarded (no Task -> DENY!).
    $wsEdit = Invoke-AiSopHookDispatcher `
        -RawPayload (New-AgToolRaw -ToolName "edit_file" -ToolArgs @{ Path = $wsFile; Target = "App"; Replacement = "Hacked" }) `
        -EventHint PRE_TOOL_USE `
        -TrustedWorkspaceRoot $Workspace `
        -AgentHint ANTIGRAVITY `
        -AcceptedAt $now.AddSeconds(7)
    Assert-Equal $wsEdit.Decision "DENY" "Host workspace edit without Task must still be denied"
    Assert-True ($wsEdit.ReasonCode -in @("SESSION_NOT_FOUND","SESSION_BINDING_INVALID","OWNER_REQUIRED","TASK_REQUIRED")) "Unexpected host edit deny reason: $($wsEdit.ReasonCode)"

    # 6) Write shell inside read_write sibling MUST STILL be denied (prevents ../host-repo bypass!).
    $rwWriteShell = Invoke-AiSopHookDispatcher `
        -RawPayload (New-AgToolRaw -ToolName "run_command" -ToolArgs @{ CommandLine = "Set-Content '../host-repo/src/App.java' 'PWNED'"; Cwd = $ReadWriteSibling; WaitMsBeforeAsync = 1000 }) `
        -EventHint PRE_TOOL_USE `
        -TrustedWorkspaceRoot $Workspace `
        -AgentHint ANTIGRAVITY `
        -AcceptedAt $now.AddSeconds(8)
    Assert-Equal $rwWriteShell.Decision "DENY" "Write shell inside read_write sibling must still be denied without host Task"
    Assert-True ($rwWriteShell.ReasonCode -in @("SESSION_NOT_FOUND","SESSION_BINDING_INVALID","OWNER_REQUIRED","TASK_REQUIRED")) "Unexpected write shell deny reason: $($rwWriteShell.ReasonCode)"

    # 7) Read-only shell inside sibling trying to escape to untrusted/outside path MUST be denied.
    $rwEscapeShell = Invoke-AiSopHookDispatcher `
        -RawPayload (New-AgToolRaw -ToolName "run_command" -ToolArgs @{ CommandLine = "Get-Content '../outside-secret/cred.txt'"; Cwd = $ReadWriteSibling; WaitMsBeforeAsync = 1000 }) `
        -EventHint PRE_TOOL_USE `
        -TrustedWorkspaceRoot $Workspace `
        -AgentHint ANTIGRAVITY `
        -AcceptedAt $now.AddSeconds(9)
    Assert-Equal $rwEscapeShell.Decision "DENY" "Read-only shell escaping sibling to outside dir must be denied"

    # 8) Untrusted sibling and outside paths remain denied even when trusted siblings exist.
    $untrustedRead = Invoke-AiSopHookDispatcher `
        -RawPayload (New-AgToolRaw -ToolName "read_file" -ToolArgs @{ Path = $untrustedFile } -WorkspacePaths @($UntrustedSibling, $Workspace)) `
        -EventHint PRE_TOOL_USE `
        -TrustedWorkspaceRoot $Workspace `
        -AgentHint ANTIGRAVITY `
        -AcceptedAt $now.AddSeconds(10)
    Assert-Equal $untrustedRead.Decision "DENY" "Untrusted sibling must still be denied"
    Assert-Equal $untrustedRead.ReasonCode "EDIT_PATH_OUTSIDE_WORKSPACE" "Untrusted sibling deny reason must be EDIT_PATH_OUTSIDE_WORKSPACE"

    # 9) Cached hook scenario: workspacePaths only lists trusted sibling (e.g. host removed from multi-root before reload).
    $cachedPre = Invoke-AiSopHookDispatcher `
        -RawPayload (([ordered]@{ conversationId = "ag-cached-hook"; workspacePaths = @($ReadWriteSibling); invocationNum = 1 }) | ConvertTo-Json -Compress) `
        -EventHint PRE_INVOCATION `
        -TrustedWorkspaceRoot $Workspace `
        -AgentHint ANTIGRAVITY `
        -AcceptedAt $now.AddSeconds(11)
    Assert-Equal $cachedPre.Decision "ALLOW" "Cached hook PRE_INVOCATION with trusted sibling workspacePaths must not lock out window"

    $cachedEdit = Invoke-AiSopHookDispatcher `
        -RawPayload (New-AgToolRaw -ToolName "edit_file" -ToolArgs @{ Path = $rwFile; Target = "readwrite"; Replacement = "ok" } -WorkspacePaths @($ReadWriteSibling) -SessionId "ag-cached-hook") `
        -EventHint PRE_TOOL_USE `
        -TrustedWorkspaceRoot $Workspace `
        -AgentHint ANTIGRAVITY `
        -AcceptedAt $now.AddSeconds(12)
    Assert-Equal $cachedEdit.Decision "ALLOW" "Cached hook edit in trusted read_write sibling must be allowed"
    Assert-Equal $cachedEdit.ReasonCode "TRUSTED_SIBLING_EDIT" "Cached hook edit reason must be TRUSTED_SIBLING_EDIT"

    # 10) Mixed multi-file edit (Codex apply_patch touching BOTH sibling AND host workspace) MUST be denied!
    $mixedPatch = "*** Begin Patch`n*** Update File: $rwFile`n@@`n-readwrite`n+ok`n*** Update File: $wsFile`n@@`n-class App {}`n+class App { int x; }`n*** End Patch"
    $codexMixedRaw = ([ordered]@{
        session_id = "codex-mixed"
        cwd = $Workspace
        hook_event_name = "PreToolUse"
        tool_name = "apply_patch"
        tool_use_id = "codex-mixed-1"
        tool_input = [ordered]@{ command = $mixedPatch }
    } | ConvertTo-Json -Compress -Depth 10)
    $codexMixedRes = Invoke-AiSopHookDispatcher `
        -RawPayload $codexMixedRaw `
        -EventHint PRE_TOOL_USE `
        -TrustedWorkspaceRoot $Workspace `
        -AgentHint CODEX `
        -AcceptedAt $now.AddSeconds(13)
    Assert-Equal $codexMixedRes.Decision "DENY" "Mixed cross-workspace apply_patch must be denied"
    Assert-Equal $codexMixedRes.ReasonCode "EDIT_PATH_OUTSIDE_WORKSPACE" "Mixed cross-workspace apply_patch must fail with EDIT_PATH_OUTSIDE_WORKSPACE"

    # Pure sibling Codex apply_patch IS allowed!
    $pureSiblingPatch = "*** Begin Patch`n*** Update File: $rwFile`n@@`n-readwrite`n+ok`n*** End Patch"
    $codexSibRaw = ([ordered]@{
        session_id = "codex-sib"
        cwd = $ReadWriteSibling
        hook_event_name = "PreToolUse"
        tool_name = "apply_patch"
        tool_use_id = "codex-sib-1"
        tool_input = [ordered]@{ command = $pureSiblingPatch }
    } | ConvertTo-Json -Compress -Depth 10)
    $codexSibRes = Invoke-AiSopHookDispatcher `
        -RawPayload $codexSibRaw `
        -EventHint PRE_TOOL_USE `
        -TrustedWorkspaceRoot $Workspace `
        -AgentHint CODEX `
        -AcceptedAt $now.AddSeconds(14)
    Assert-Equal $codexSibRes.Decision "ALLOW" "Pure read_write sibling apply_patch must be allowed"
    Assert-Equal $codexSibRes.ReasonCode "TRUSTED_SIBLING_EDIT" "Pure sibling apply_patch reason must be TRUSTED_SIBLING_EDIT"

    # 11) Cursor Grep / Glob / Edit inside trusted sibling
    $cursorGrepRaw = ([ordered]@{
        conversation_id = "cursor-sib"
        session_id = "cursor-sib"
        generation_id = "gen-1"
        tool_use_id = "cur-1"
        hook_event_name = "preToolUse"
        cursor_version = "3.15.19"
        workspace_roots = @($ReadWriteSibling, $Workspace)
        tool_name = "Grep"
        tool_input = [ordered]@{ pattern = "readwrite"; file_path = $rwFile }
    } | ConvertTo-Json -Compress -Depth 10)
    $cursorGrepRes = Invoke-AiSopHookDispatcher `
        -RawPayload $cursorGrepRaw `
        -EventHint PRE_TOOL_USE `
        -TrustedWorkspaceRoot $Workspace `
        -AgentHint CURSOR `
        -AcceptedAt $now.AddSeconds(15)
    Assert-Equal $cursorGrepRes.Decision "ALLOW" "Cursor Grep in trusted sibling must be allowed"

    # 12) GOVERNANCE_SWITCH_PROTECTED: AI cannot edit .ai-workspace/.runtime/trusted-siblings.json!
    Assert-True (Test-AiSopGuardGovernanceSwitchPath -Path $configPath -WorkspaceRoot $Workspace) ".trusted-siblings.json must be protected as governance switch"
    $tamperEvent = ConvertTo-AiSopHookEvent `
        -RawPayload (New-AgToolRaw -ToolName "write_file" -ToolArgs @{ Path = $configPath; Content = "{}"; Overwrite = $true }) `
        -EventHint PRE_TOOL_USE `
        -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $now.AddSeconds(16)
    $tamperDecision = Get-AiSopGuardTargetDecision -HookEvent $tamperEvent
    Assert-Equal $tamperDecision.Decision "DENY" "Editing .trusted-siblings.json must be denied"
    Assert-Equal $tamperDecision.ReasonCode "GOVERNANCE_SWITCH_PROTECTED" "Editing .trusted-siblings.json must return GOVERNANCE_SWITCH_PROTECTED"

    # 13) Symlink escape from trusted sibling into host workspace or outside MUST be denied!
    $linkPath = Join-Path $ReadWriteSibling "escape-to-host"
    $linkCreated = $false
    try {
        New-Item -ItemType Junction -Path $linkPath -Target $Workspace -ErrorAction Stop | Out-Null
        $linkCreated = $true
    } catch {
        try {
            New-Item -ItemType SymbolicLink -Path $linkPath -Target $Workspace -ErrorAction Stop | Out-Null
            $linkCreated = $true
        } catch {}
    }
    if ($linkCreated) {
        $escapedEdit = Invoke-AiSopHookDispatcher `
            -RawPayload (New-AgToolRaw -ToolName "edit_file" -ToolArgs @{ Path = (Join-Path $linkPath "src/App.java"); Target = "App"; Replacement = "Pwn" }) `
            -EventHint PRE_TOOL_USE `
            -TrustedWorkspaceRoot $Workspace `
            -AgentHint ANTIGRAVITY `
            -AcceptedAt $now.AddSeconds(17)
        Assert-Equal $escapedEdit.Decision "DENY" "Junction/symlink inside trusted sibling pointing to host workspace must be denied"
        Assert-Equal $escapedEdit.ReasonCode "EDIT_PATH_OUTSIDE_WORKSPACE" "Symlink escape must fail with EDIT_PATH_OUTSIDE_WORKSPACE"
        [System.IO.Directory]::Delete($linkPath)
    }

    # 14) Fail-closed invalid .trusted-siblings.json cases!
    $driveRoot = [System.IO.Path]::GetPathRoot($Workspace)
    $invalidConfigs = @(
        @{ Name = "malformed JSON"; Content = "{broken" },
        @{ Name = "wrong schemaVersion"; Content = '{"schemaVersion":"2.0","siblings":[]}' },
        @{ Name = "unknown access"; Content = (@{ schemaVersion = "1.0"; siblings = @(@{ path = $ReadOnlySibling; access = "admin" }) } | ConvertTo-Json -Compress) },
        @{ Name = "parent ancestor overlap"; Content = (@{ schemaVersion = "1.0"; siblings = @(@{ path = $TestRoot; access = "read" }) } | ConvertTo-Json -Compress) },
        @{ Name = "self workspace overlap"; Content = (@{ schemaVersion = "1.0"; siblings = @(@{ path = $Workspace; access = "read_write" }) } | ConvertTo-Json -Compress) },
        @{ Name = "filesystem root"; Content = (@{ schemaVersion = "1.0"; siblings = @(@{ path = $driveRoot; access = "read" }) } | ConvertTo-Json -Compress) },
        @{ Name = "registry overlap"; Content = (@{ schemaVersion = "1.0"; siblings = @(@{ path = $RegistryRoot; access = "read_write" }) } | ConvertTo-Json -Compress) },
        @{ Name = "conflicting duplicate access"; Content = (@{ schemaVersion = "1.0"; siblings = @(@{ path = $ReadOnlySibling; access = "read" }, @{ path = $ReadOnlySibling; access = "read_write" }) } | ConvertTo-Json -Compress) },
        @{ Name = "relative path"; Content = '{"schemaVersion":"1.0","siblings":[{"path":"../sibling-ro","access":"read"}]}' }
    )
    foreach ($bad in $invalidConfigs) {
        [System.IO.File]::WriteAllText($configPath, $bad.Content)
        $badRes = Invoke-AiSopHookDispatcher `
            -RawPayload (New-AgToolRaw -ToolName "read_file" -ToolArgs @{ Path = $wsFile }) `
            -EventHint PRE_TOOL_USE `
            -TrustedWorkspaceRoot $Workspace `
            -AgentHint ANTIGRAVITY `
            -AcceptedAt $now.AddSeconds(20)
        Assert-Equal $badRes.Decision "DENY" "Invalid config ($($bad.Name)) must fail-closed"
        Assert-Equal $badRes.ReasonCode "TRUSTED_SIBLINGS_CONFIG_INVALID" "Invalid config ($($bad.Name)) must return TRUSTED_SIBLINGS_CONFIG_INVALID"
    }

    Write-Output "PASS: all trusted-siblings read/read_write, isolation, governance protection, symlink escape and fail-closed config tests passed."
} finally {
    foreach ($name in $savedEnv.Keys) {
        if ($null -eq $savedEnv[$name]) {
            [Environment]::SetEnvironmentVariable($name, $null)
        } else {
            [Environment]::SetEnvironmentVariable($name, $savedEnv[$name])
        }
    }
    if (Test-Path -LiteralPath $TestRoot) {
        Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
