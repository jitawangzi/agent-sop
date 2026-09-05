#requires -Version 7.0

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$ScriptsRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $ScriptsRoot "hidden-process.ps1")
$ClaudeRoot = Split-Path -Parent $ScriptsRoot
$DispatcherScript = Join-Path $ScriptsRoot "hook-dispatcher.ps1"
$OwnerScript = Join-Path $ScriptsRoot "workflow-owner.ps1"
$SessionScript = Join-Path $ScriptsRoot "workflow-session.ps1"
$VerifyScript = Join-Path $ScriptsRoot "verify-guard-live.ps1"
$FixtureRoot = Join-Path $PSScriptRoot "fixtures\hooks"
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "dispatcher-tests-" + [guid]::NewGuid().ToString("N")
)
$Workspace = Join-Path $TestRoot "workspace"
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$SavedEnvironment = @{}
$RegistryVariables = @(
    "SERVER_NEW_WORKFLOW_REGISTRY",
    "SERVER_NEW_WORKFLOW_SESSION_REGISTRY",
    "SERVER_NEW_WORKFLOW_COMMAND_GRANT_REGISTRY",
    "SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY",
    "SERVER_NEW_HOOK_DEDUP_REGISTRY",
    "SERVER_NEW_HOOK_CORRELATION_REGISTRY",
    "SERVER_NEW_SKIP_OWNER_GUARD"
)

function Assert-Equal {
    param(
        [AllowNull()]
        [object]$Actual,
        [AllowNull()]
        [object]$Expected,
        [string]$Message
    )

    if ($Actual -cne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function ConvertTo-TestJson {
    param([object]$Value)

    return $Value | ConvertTo-Json -Compress -Depth 40
}

function Invoke-Dispatch {
    param(
        [string]$RawPayload,
        [ValidateSet(
            "SESSION_START",
            "PRE_INVOCATION",
            "PRE_TOOL_USE",
            "SESSION_END",
            "STOP"
        )]
        [string]$EventHint,
        [DateTimeOffset]$AcceptedAt
    )

    return Invoke-AiSopHookDispatcher `
        -RawPayload $RawPayload `
        -EventHint $EventHint `
        -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt
}

function New-ClaudePayload {
    param(
        [ValidateSet("SESSION_START", "PRE_TOOL_USE", "SESSION_END")]
        [string]$Event,
        [string]$SessionId,
        [string]$ToolName = "",
        [hashtable]$ToolInput = @{},
        [string]$Occurrence = "toolu_dispatcher"
    )

    switch ($Event) {
        "SESSION_START" {
            return ConvertTo-TestJson ([ordered]@{
                session_id = $SessionId
                cwd = $Workspace
                hook_event_name = "SessionStart"
                source = "startup"
            })
        }
        "SESSION_END" {
            return ConvertTo-TestJson ([ordered]@{
                session_id = $SessionId
                cwd = $Workspace
                hook_event_name = "SessionEnd"
                reason = "other"
            })
        }
        "PRE_TOOL_USE" {
            return ConvertTo-TestJson ([ordered]@{
                session_id = $SessionId
                cwd = $Workspace
                hook_event_name = "PreToolUse"
                tool_name = $ToolName
                tool_input = $ToolInput
                tool_use_id = $Occurrence
            })
        }
    }
}

function New-CopilotCompatPayload {
    param(
        [ValidateSet("SESSION_START", "PRE_TOOL_USE", "SESSION_END")]
        [string]$Event,
        [string]$SessionId,
        [DateTimeOffset]$AcceptedAt,
        [string]$ToolName = "",
        [hashtable]$ToolInput = @{}
    )

    $payload = [ordered]@{
        hook_event_name = switch ($Event) {
            "SESSION_START" { "SessionStart" }
            "SESSION_END" { "SessionEnd" }
            default { "PreToolUse" }
        }
        session_id = $SessionId
        timestamp = $AcceptedAt.ToUniversalTime().ToString("o")
        cwd = $Workspace
    }
    if ($Event -eq "PRE_TOOL_USE") {
        $payload.tool_name = $ToolName
        $payload.tool_input = $ToolInput
    }
    return ConvertTo-TestJson $payload
}

function New-CopilotNativePayload {
    param(
        [ValidateSet("SESSION_START", "PRE_TOOL_USE", "SESSION_END")]
        [string]$Event,
        [string]$SessionId,
        [DateTimeOffset]$AcceptedAt,
        [string]$ToolName = "",
        [hashtable]$ToolInput = @{},
        [switch]$StringArguments
    )

    $payload = [ordered]@{
        sessionId = $SessionId
        timestamp = $AcceptedAt.ToUnixTimeMilliseconds()
        cwd = $Workspace
    }
    if ($Event -eq "PRE_TOOL_USE") {
        $payload.toolName = $ToolName
        $payload.toolArgs = if ($StringArguments) {
            ConvertTo-TestJson $ToolInput
        } else {
            $ToolInput
        }
    }
    return ConvertTo-TestJson $payload
}

function New-CursorPayload {
    param(
        [ValidateSet("SESSION_START", "PRE_TOOL_USE", "SESSION_END")]
        [string]$Event,
        [string]$SessionId,
        [string]$ToolName = "",
        [hashtable]$ToolInput = @{},
        [string]$Occurrence = "cursor-tool"
    )

    switch ($Event) {
        "SESSION_START" {
            return ConvertTo-TestJson ([ordered]@{
                session_id = $SessionId
                is_background_agent = $false
                composer_mode = "agent"
            })
        }
        "SESSION_END" {
            return ConvertTo-TestJson ([ordered]@{
                session_id = $SessionId
                reason = "completed"
                duration_ms = 10
                is_background_agent = $false
                final_status = "completed"
            })
        }
        "PRE_TOOL_USE" {
            return ConvertTo-TestJson ([ordered]@{
                conversation_id = $SessionId
                generation_id = "generation-$Occurrence"
                hook_event_name = "preToolUse"
                workspace_roots = @($Workspace)
                tool_name = $ToolName
                tool_input = $ToolInput
                tool_use_id = $Occurrence
                cwd = $Workspace
            })
        }
    }
}

function New-AntigravityPayload {
    param(
        [ValidateSet("PRE_INVOCATION", "PRE_TOOL_USE", "STOP")]
        [string]$Event,
        [string]$SessionId,
        [string]$ToolName = "",
        [hashtable]$ToolInput = @{},
        [Nullable[bool]]$FullyIdle
    )

    $payload = [ordered]@{
        conversationId = $SessionId
        workspacePaths = @($Workspace)
    }
    switch ($Event) {
        "PRE_TOOL_USE" {
            $payload.toolCall = [ordered]@{
                name = $ToolName
                args = $ToolInput
            }
        }
        "STOP" {
            if ($null -ne $FullyIdle) {
                $payload.fullyIdle = [bool]$FullyIdle
            }
        }
    }
    return ConvertTo-TestJson $payload
}

function New-OwnerCommand {
    param(
        [string]$Operation,
        [string]$Feature,
        [string]$Agent,
        [string]$OwnerId
    )

    return (
        "pwsh -NoProfile -File '.\.ai-sop\scripts\workflow-owner.ps1' " +
        "-Operation '$Operation' " +
        "-SpecDirectory '.ai-workspace\specs\features\$Feature' " +
        "-Feature '$Feature' " +
        "-Workflow 'SUPERPOWERS' " +
        "-Agent '$Agent' " +
        "-OwnerId '$OwnerId'"
    )
}

function Assert-NativeEnvelope {
    param(
        [object]$Result,
        [string]$Message
    )

    try {
        $parsed = $Result.Envelope | ConvertFrom-Json
    } catch {
        throw "$Message Dispatcher emitted invalid JSON: $($Result.Envelope)"
    }
    Assert-True ($null -ne $parsed) $Message
}

function Get-SessionRecordFor {
    param(
        [string]$Agent,
        [string]$NativeSessionId
    )

    $key = Get-AiSopWorkflowSessionKey `
        -Agent $Agent `
        -NativeSessionId $NativeSessionId `
        -WorkspacePath $Workspace
    $result = Get-AiSopWorkflowSession `
        -SessionKey $key `
        -AcceptedAt ([DateTimeOffset]::UtcNow)
    return $result.Record
}

try {
    foreach ($name in $RegistryVariables) {
        $SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    $env:SERVER_NEW_WORKFLOW_REGISTRY = Join-Path $TestRoot "owners"
    $env:SERVER_NEW_WORKFLOW_SESSION_REGISTRY = Join-Path $TestRoot "sessions"
    $env:SERVER_NEW_WORKFLOW_COMMAND_GRANT_REGISTRY =
        Join-Path $TestRoot "grants"
    $env:SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY =
        Join-Path $TestRoot "transactions"
    $env:SERVER_NEW_HOOK_DEDUP_REGISTRY = Join-Path $TestRoot "dedup"
    $env:SERVER_NEW_HOOK_CORRELATION_REGISTRY =
        Join-Path $TestRoot "correlation"
    Remove-Item Env:SERVER_NEW_SKIP_OWNER_GUARD -ErrorAction SilentlyContinue

    foreach ($path in @(
        $Workspace,
        (Join-Path $Workspace ".ai-sop\scripts"),
        (Join-Path $Workspace ".claude\scratch"),
        (Join-Path $Workspace ".ai-workspace\specs\features"),
        (Join-Path $Workspace "src\com"),
        (Join-Path $Workspace "WebRoot"),
        (Join-Path $Workspace "config")
    )) {
        [System.IO.Directory]::CreateDirectory($path) | Out-Null
    }
    Copy-Item `
        -LiteralPath $OwnerScript `
        -Destination (Join-Path $Workspace ".ai-sop\scripts\workflow-owner.ps1")

    if (-not (Test-Path -LiteralPath $DispatcherScript -PathType Leaf)) {
        throw "Required Task 4 artifact does not exist: $DispatcherScript"
    }
    $dispatcherSource = [System.IO.File]::ReadAllText($DispatcherScript)
    if ($dispatcherSource -notmatch "(?m)^function Invoke-AiSopHookDispatcher") {
        throw "Task 4 dispatcher interface is missing."
    }

    . $DispatcherScript
    . $SessionScript

    Assert-Equal (Get-AiSopDispatcherShellCommandText @{ command = "a" }) "a" (
        "command alias must be read."
    )
    Assert-Equal (Get-AiSopDispatcherShellCommandText @{ CommandLine = "b" }) "b" (
        "CommandLine alias must be read."
    )
    Assert-Equal (Get-AiSopDispatcherShellCommandText @{ commandLine = "c" }) "c" (
        "commandLine alias must be read."
    )
    Assert-Equal (Get-AiSopDispatcherShellCommandText @{ cmd = "d" }) "d" (
        "cmd alias must be read."
    )
    Assert-Equal (
        Get-AiSopDispatcherShellCommandText @{ command = "a"; cmd = "z" }
    ) "a" "command must win over later aliases."
    Assert-Equal (
        Get-AiSopDispatcherShellCommandText ([pscustomobject]@{ CommandLine = "e" })
    ) "e" "PSCustomObject CommandLine must be read."
    Assert-Equal (Get-AiSopDispatcherShellCommandText @{}) $null (
        "empty arguments must yield no command text."
    )

    $now = [DateTimeOffset]::UtcNow

    $env:SERVER_NEW_SKIP_OWNER_GUARD = "1"
    $escapeSessionCountBefore = @(
        Get-ChildItem `
            -LiteralPath $env:SERVER_NEW_WORKFLOW_SESSION_REGISTRY `
            -Filter *.json -File -ErrorAction SilentlyContinue
    ).Count
    $escape = Invoke-Dispatch `
        -RawPayload "not-json" `
        -EventHint PRE_TOOL_USE `
        -AcceptedAt $now
    Assert-Equal $escape.Decision "ALLOW" "Exact T1 escape did not allow."
    Assert-Equal @(
        Get-ChildItem `
            -LiteralPath $env:SERVER_NEW_WORKFLOW_SESSION_REGISTRY `
            -Filter *.json -File -ErrorAction SilentlyContinue
    ).Count $escapeSessionCountBefore "T1 escape performed a side effect."

    $agEscape = Invoke-Dispatch `
        -RawPayload (New-AntigravityPayload `
            -Event PRE_INVOCATION `
            -SessionId "t1-antigravity") `
        -EventHint PRE_INVOCATION `
        -AcceptedAt $now
    Assert-Equal $agEscape.Decision "ALLOW" (
        "T1 Antigravity PRE_INVOCATION did not allow."
    )
    Assert-Equal $agEscape.Envelope "{}" (
        "T1 Antigravity PRE_INVOCATION must return empty JSON, not decision: $($agEscape.Envelope)"
    )
    $agToolEscape = Invoke-Dispatch `
        -RawPayload (New-AntigravityPayload `
            -Event PRE_TOOL_USE `
            -SessionId "t1-antigravity" `
            -ToolName "read_file" `
            -ToolInput @{ path = (Join-Path $Workspace ".claude\scratch\r") }) `
        -EventHint PRE_TOOL_USE `
        -AcceptedAt $now
    Assert-Equal $agToolEscape.Decision "ALLOW" (
        "T1 Antigravity PRE_TOOL_USE did not allow."
    )
    Assert-True ($agToolEscape.Envelope -match '"decision"\s*:') (
        "T1 Antigravity PRE_TOOL_USE envelope missing decision: $($agToolEscape.Envelope)"
    )
    Assert-Equal $escape.ReasonCode "T1_ESCAPE" (
        "T1 malformed payload must still ALLOW after parse failure."
    )
    # Explicit 0 beats .ai-sop/.guard-disabled so later assertions exercise Guard.
    $env:SERVER_NEW_SKIP_OWNER_GUARD = "0"

    foreach ($reject in @(
        @{
            Name = "malformed"
            Raw = "{"
            Hint = "PRE_TOOL_USE"
        },
        @{
            Name = "ambiguous"
            Raw = (
                [System.IO.File]::ReadAllText(
                    (Join-Path $FixtureRoot "ambiguous-shape.json")
                ) -replace "__WORKSPACE__", (
                    $Workspace -replace "\\", "\\"
                )
            )
            Hint = "PRE_TOOL_USE"
        },
        @{
            Name = "unknown shape"
            Raw = [System.IO.File]::ReadAllText(
                (Join-Path $FixtureRoot "unknown-shape.json")
            )
            Hint = "PRE_TOOL_USE"
        }
    )) {
        $result = Invoke-Dispatch `
            -RawPayload $reject.Raw `
            -EventHint $reject.Hint `
            -AcceptedAt $now
        Assert-Equal $result.Decision "DENY" (
            "$($reject.Name) payload unexpectedly allowed."
        )
        Assert-NativeEnvelope $result (
            "$($reject.Name) did not return a native deny envelope."
        )
    }

    $matrix = @(
        @{
            Agent = "CLAUDE_CODE"
            Session = "matrix-claude"
            StartHint = "SESSION_START"
            Start = {
                param($at)
                New-ClaudePayload -Event SESSION_START -SessionId "matrix-claude"
            }
            Tool = {
                param($class, $at)
                $name = @{
                    SAFE_NON_EDIT = "Read"
                    FILE_EDIT = "Edit"
                    OWNER_REQUIRED = "Bash"
                    UNKNOWN = "mystery"
                }[$class]
                $args = switch ($class) {
                    "SAFE_NON_EDIT" {
                        @{ file_path = (Join-Path $Workspace ".claude\scratch\r") }
                    }
                    "FILE_EDIT" {
                        @{
                            file_path = (Join-Path $Workspace ".claude\scratch\e")
                            old_string = "a"
                            new_string = "b"
                        }
                    }
                    "OWNER_REQUIRED" { @{ command = "Get-Location" } }
                    default { @{} }
                }
                New-ClaudePayload `
                    -Event PRE_TOOL_USE `
                    -SessionId "matrix-claude" `
                    -ToolName $name `
                    -ToolInput $args `
                    -Occurrence "claude-$class"
            }
        },
        @{
            Agent = "COPILOT"
            Session = "matrix-copilot"
            StartHint = "SESSION_START"
            Start = {
                param($at)
                New-CopilotCompatPayload `
                    -Event SESSION_START `
                    -SessionId "matrix-copilot" `
                    -AcceptedAt $at
            }
            Tool = {
                param($class, $at)
                $name = @{
                    SAFE_NON_EDIT = "Read"
                    FILE_EDIT = "Edit"
                    OWNER_REQUIRED = "Bash"
                    UNKNOWN = "mystery"
                }[$class]
                $args = switch ($class) {
                    "SAFE_NON_EDIT" {
                        @{ file_path = (Join-Path $Workspace ".claude\scratch\r") }
                    }
                    "FILE_EDIT" {
                        @{
                            file_path = (Join-Path $Workspace ".claude\scratch\e")
                            old_string = "a"
                            new_string = "b"
                        }
                    }
                    "OWNER_REQUIRED" { @{ command = "Get-Location" } }
                    default { @{} }
                }
                New-CopilotCompatPayload `
                    -Event PRE_TOOL_USE `
                    -SessionId "matrix-copilot" `
                    -AcceptedAt $at `
                    -ToolName $name `
                    -ToolInput $args
            }
        },
        @{
            Agent = "CURSOR"
            Session = "matrix-cursor"
            StartHint = "SESSION_START"
            Start = {
                param($at)
                New-CursorPayload -Event SESSION_START -SessionId "matrix-cursor"
            }
            Tool = {
                param($class, $at)
                $name = @{
                    SAFE_NON_EDIT = "ReadFile"
                    FILE_EDIT = "Edit"
                    OWNER_REQUIRED = "Shell"
                    UNKNOWN = "mystery"
                }[$class]
                $args = switch ($class) {
                    "SAFE_NON_EDIT" {
                        @{ path = (Join-Path $Workspace ".claude\scratch\r") }
                    }
                    "FILE_EDIT" {
                        @{
                            file_path = (Join-Path $Workspace ".claude\scratch\e")
                            old_string = "a"
                            new_string = "b"
                        }
                    }
                    "OWNER_REQUIRED" { @{ command = "Get-Location" } }
                    default { @{} }
                }
                New-CursorPayload `
                    -Event PRE_TOOL_USE `
                    -SessionId "matrix-cursor" `
                    -ToolName $name `
                    -ToolInput $args `
                    -Occurrence "cursor-$class"
            }
        },
        @{
            Agent = "ANTIGRAVITY"
            Session = "matrix-antigravity"
            StartHint = "PRE_INVOCATION"
            Start = {
                param($at)
                New-AntigravityPayload `
                    -Event PRE_INVOCATION `
                    -SessionId "matrix-antigravity"
            }
            Tool = {
                param($class, $at)
                $name = @{
                    SAFE_NON_EDIT = "read_file"
                    FILE_EDIT = "edit_file"
                    OWNER_REQUIRED = "run_command"
                    UNKNOWN = "mystery"
                }[$class]
                $args = switch ($class) {
                    "SAFE_NON_EDIT" {
                        @{ path = (Join-Path $Workspace ".claude\scratch\r") }
                    }
                    "FILE_EDIT" {
                        @{
                            file_path = (Join-Path $Workspace ".claude\scratch\e")
                            old_string = "a"
                            new_string = "b"
                        }
                    }
                    "OWNER_REQUIRED" { @{ command = "Get-Location" } }
                    default { @{} }
                }
                New-AntigravityPayload `
                    -Event PRE_TOOL_USE `
                    -SessionId "matrix-antigravity" `
                    -ToolName $name `
                    -ToolInput $args
            }
        }
    )
    $matrixRows = 0
    foreach ($adapter in $matrix) {
        $startAt = $now.AddSeconds($matrixRows + 1)
        $startResult = Invoke-Dispatch `
            -RawPayload (& $adapter.Start $startAt) `
            -EventHint $adapter.StartHint `
            -AcceptedAt $startAt
        Assert-Equal $startResult.Decision "ALLOW" (
            "$($adapter.Agent) lifecycle did not register."
        )
        if ($adapter.Agent -eq "ANTIGRAVITY") {
            Assert-Equal $startResult.Envelope "{}" (
                "Antigravity PRE_INVOCATION must return empty JSON: $($startResult.Envelope)"
            )
        }
        foreach ($class in @(
            "SAFE_NON_EDIT",
            "FILE_EDIT",
            "OWNER_REQUIRED",
            "UNKNOWN"
        )) {
            $at = $startAt.AddMilliseconds(100 + $matrixRows)
            $result = Invoke-Dispatch `
                -RawPayload (& $adapter.Tool $class $at) `
                -EventHint PRE_TOOL_USE `
                -AcceptedAt $at
            $expected = if ($class -in @("SAFE_NON_EDIT", "FILE_EDIT")) {
                "ALLOW"
            } else {
                "DENY"
            }
            Assert-Equal $result.Decision $expected (
                "$($adapter.Agent) $class matrix decision mismatch."
            )
            Assert-NativeEnvelope $result (
                "$($adapter.Agent) $class returned an invalid envelope."
            )
            $matrixRows++
        }
    }
    Assert-Equal $matrixRows 16 "Four-agent/four-state matrix was incomplete."

    $cursorPendingId = "cursor-pending"
    $pendingCommand = New-OwnerCommand `
        -Operation Claim `
        -Feature "CursorPending" `
        -Agent CURSOR `
        -OwnerId "cursor-pending-owner"
    [System.IO.Directory]::CreateDirectory(
        (Join-Path $Workspace ".ai-workspace\specs\features\CursorPending")
    ) | Out-Null
    $pendingFirst = Invoke-Dispatch `
        -RawPayload (
            New-CursorPayload `
                -Event PRE_TOOL_USE `
                -SessionId $cursorPendingId `
                -ToolName Shell `
                -ToolInput @{ command = $pendingCommand } `
                -Occurrence "pending-first"
        ) `
        -EventHint PRE_TOOL_USE `
        -AcceptedAt $now.AddMinutes(1)
    Assert-Equal $pendingFirst.Decision "DENY" (
        "Cursor Claim before lifecycle unexpectedly allowed."
    )
    Assert-Equal $pendingFirst.ReasonCode "CURSOR_LIFECYCLE_PENDING" (
        "Cursor first-tool race returned the wrong stable reason."
    )
    $pendingSession = Get-SessionRecordFor `
        -Agent CURSOR `
        -NativeSessionId $cursorPendingId
    Assert-Equal $pendingSession.lifecycleProof "PENDING" (
        "Cursor first-tool race did not persist PENDING."
    )
    $pendingStart = Invoke-Dispatch `
        -RawPayload (
            New-CursorPayload `
                -Event SESSION_START `
                -SessionId $cursorPendingId
        ) `
        -EventHint SESSION_START `
        -AcceptedAt $now.AddMinutes(1).AddSeconds(1)
    Assert-Equal $pendingStart.Decision "ALLOW" (
        "Matching Cursor lifecycle did not confirm PENDING."
    )
    $pendingRetry = Invoke-Dispatch `
        -RawPayload (
            New-CursorPayload `
                -Event PRE_TOOL_USE `
                -SessionId $cursorPendingId `
                -ToolName Shell `
                -ToolInput @{ command = $pendingCommand } `
                -Occurrence "pending-retry"
        ) `
        -EventHint PRE_TOOL_USE `
        -AcceptedAt $now.AddMinutes(1).AddSeconds(2)
    Assert-Equal $pendingRetry.Decision "ALLOW" (
        "Cursor exact Claim retry did not issue a grant."
    )
    Assert-True (
        [string]$pendingRetry.GrantId -match "^[0-9a-f]{64}$"
    ) "Cursor Claim retry did not return the deterministic grantId."

    $aliasFeature = "CmdAliasFeature"
    $aliasOwnerId = "cmd-alias-owner"
    $aliasSession = "cursor-cmd-alias"
    [System.IO.Directory]::CreateDirectory(
        (Join-Path $Workspace ".ai-workspace\specs\features\$aliasFeature")
    ) | Out-Null
    $aliasStartAt = $now.AddMinutes(1).AddSeconds(10)
    Invoke-Dispatch `
        -RawPayload (
            New-CursorPayload -Event SESSION_START -SessionId $aliasSession
        ) `
        -EventHint SESSION_START `
        -AcceptedAt $aliasStartAt | Out-Null
    $aliasCommand = New-OwnerCommand `
        -Operation Claim `
        -Feature $aliasFeature `
        -Agent CURSOR `
        -OwnerId $aliasOwnerId
    $aliasGrant = Invoke-Dispatch `
        -RawPayload (
            New-CursorPayload `
                -Event PRE_TOOL_USE `
                -SessionId $aliasSession `
                -ToolName Shell `
                -ToolInput @{ CommandLine = $aliasCommand } `
                -Occurrence "cmd-alias"
        ) `
        -EventHint PRE_TOOL_USE `
        -AcceptedAt $aliasStartAt.AddSeconds(1)
    Assert-Equal $aliasGrant.Decision "ALLOW" (
        "Shell CommandLine alias did not issue a grant."
    )
    Assert-True (
        [string]$aliasGrant.GrantId -match "^[0-9a-f]{64}$"
    ) "CommandLine grant did not return a grantId."

    $claimFeature = "DispatcherExact"
    $claimOwnerId = "dispatcher-owner"
    $claimSession = "dispatcher-claude-owner"
    $claimSpec = Join-Path $Workspace ".ai-workspace\specs\features\$claimFeature"
    [System.IO.Directory]::CreateDirectory($claimSpec) | Out-Null
    $claimStartAt = $now.AddMinutes(2)
    Invoke-Dispatch `
        -RawPayload (
            New-ClaudePayload -Event SESSION_START -SessionId $claimSession
        ) `
        -EventHint SESSION_START `
        -AcceptedAt $claimStartAt | Out-Null
    $claimCommand = New-OwnerCommand `
        -Operation Claim `
        -Feature $claimFeature `
        -Agent CLAUDE_CODE `
        -OwnerId $claimOwnerId
    $claimHook = Invoke-Dispatch `
        -RawPayload (
            New-ClaudePayload `
                -Event PRE_TOOL_USE `
                -SessionId $claimSession `
                -ToolName Bash `
                -ToolInput @{ command = $claimCommand } `
                -Occurrence "claim-owner"
        ) `
        -EventHint PRE_TOOL_USE `
        -AcceptedAt $claimStartAt.AddSeconds(1)
    Assert-Equal $claimHook.Decision "ALLOW" (
        "Canonical Claim did not receive the bootstrap exception."
    )
    Assert-Equal $claimHook.ReasonCode "COMMAND_GRANT_ISSUED" (
        "Canonical Claim returned the wrong reason."
    )
    & $OwnerScript `
        -Operation Claim `
        -SpecDirectory $claimSpec `
        -Feature $claimFeature `
        -Workflow SUPERPOWERS `
        -Agent CLAUDE_CODE `
        -OwnerId $claimOwnerId | Out-Null
    $ownerJson = [System.IO.File]::ReadAllText(
        (Join-Path $env:SERVER_NEW_WORKFLOW_REGISTRY (
            $claimFeature.ToLowerInvariant() + ".json"
        ))
    ) | ConvertFrom-Json
    Assert-Equal $ownerJson.schemaVersion "1.1" (
        "Dispatcher bootstrap did not create isolated Owner 1.1."
    )

    $productionHook = Invoke-Dispatch `
        -RawPayload (
            New-ClaudePayload `
                -Event PRE_TOOL_USE `
                -SessionId $claimSession `
                -ToolName Edit `
                -ToolInput @{
                    file_path = (Join-Path $Workspace "src\com\Exact.java")
                    old_string = "a"
                    new_string = "b"
                } `
                -Occurrence "exact-production"
        ) `
        -EventHint PRE_TOOL_USE `
        -AcceptedAt $claimStartAt.AddSeconds(2)
    Assert-Equal $productionHook.Decision "ALLOW" (
        "Exact Owner 1.1 did not allow production FILE_EDIT."
    )
    Assert-Equal $productionHook.ReasonCode "EXACT_OWNER_AUTHORIZED" (
        "Production exact-owner allow returned the wrong reason."
    )

    $copilotSession = "copilot-dual-load"
    $dualStartAt = $now.AddMinutes(3)
    $compatStart = Invoke-Dispatch `
        -RawPayload (
            New-CopilotCompatPayload `
                -Event SESSION_START `
                -SessionId $copilotSession `
                -AcceptedAt $dualStartAt
        ) `
        -EventHint SESSION_START `
        -AcceptedAt $dualStartAt
    $nativeStart = Invoke-Dispatch `
        -RawPayload (
            New-CopilotNativePayload `
                -Event SESSION_START `
                -SessionId $copilotSession `
                -AcceptedAt $dualStartAt
        ) `
        -EventHint SESSION_START `
        -AcceptedAt $dualStartAt.AddMilliseconds(1)
    Assert-Equal $compatStart.Agent "COPILOT" (
        "Copilot compat lifecycle mapped to the wrong Agent."
    )
    Assert-Equal $nativeStart.Agent "COPILOT" (
        "Copilot native lifecycle mapped to the wrong Agent."
    )
    Assert-Equal $compatStart.DedupKey $nativeStart.DedupKey (
        "Copilot dual lifecycle did not share a semantic dedup key."
    )
    Assert-True $nativeStart.IsDuplicate (
        "Copilot second lifecycle configuration was not deduplicated."
    )

    $dualFeature = "CopilotDual"
    [System.IO.Directory]::CreateDirectory(
        (Join-Path $Workspace ".ai-workspace\specs\features\$dualFeature")
    ) | Out-Null
    $dualCommand = New-OwnerCommand `
        -Operation Claim `
        -Feature $dualFeature `
        -Agent COPILOT `
        -OwnerId "copilot-dual-owner"
    $dualToolAt = $dualStartAt.AddSeconds(1)
    $compatGrant = Invoke-Dispatch `
        -RawPayload (
            New-CopilotCompatPayload `
                -Event PRE_TOOL_USE `
                -SessionId $copilotSession `
                -AcceptedAt $dualToolAt `
                -ToolName Bash `
                -ToolInput @{ command = $dualCommand }
        ) `
        -EventHint PRE_TOOL_USE `
        -AcceptedAt $dualToolAt
    $sessionBeforeDuplicate = Get-SessionRecordFor `
        -Agent COPILOT `
        -NativeSessionId $copilotSession
    $nativeGrant = Invoke-Dispatch `
        -RawPayload (
            New-CopilotNativePayload `
                -Event PRE_TOOL_USE `
                -SessionId $copilotSession `
                -AcceptedAt $dualToolAt `
                -ToolName bash `
                -ToolInput @{ command = $dualCommand } `
                -StringArguments
        ) `
        -EventHint PRE_TOOL_USE `
        -AcceptedAt $dualToolAt.AddMilliseconds(1)
    $sessionAfterDuplicate = Get-SessionRecordFor `
        -Agent COPILOT `
        -NativeSessionId $copilotSession
    Assert-Equal $compatGrant.Decision $nativeGrant.Decision (
        "Copilot dual grant decisions differ."
    )
    Assert-Equal $compatGrant.ReasonCode $nativeGrant.ReasonCode (
        "Copilot dual grant reasons differ."
    )
    Assert-Equal $compatGrant.GrantId $nativeGrant.GrantId (
        "Copilot dual grant IDs differ."
    )
    Assert-Equal $compatGrant.DedupKey $nativeGrant.DedupKey (
        "Copilot dual grant dedup keys differ."
    )
    Assert-True $nativeGrant.IsDuplicate (
        "Copilot duplicate grant was not replayed."
    )
    Assert-Equal $sessionAfterDuplicate.lastSeenAt (
        $sessionBeforeDuplicate.lastSeenAt
    ) "Copilot duplicate grant touched the session."
    Assert-Equal $sessionAfterDuplicate.expiresAt (
        $sessionBeforeDuplicate.expiresAt
    ) "Copilot duplicate grant renewed TTL."

    $dualDedupPath = Join-Path (
        Join-Path (
            $env:SERVER_NEW_HOOK_DEDUP_REGISTRY
        ) $compatGrant.SessionKey
    ) "$($compatGrant.DedupKey).json"
    $preparedDedup = [System.IO.File]::ReadAllText($dualDedupPath) |
        ConvertFrom-Json -AsHashtable -Depth 30
    $preparedDedup.state = "PREPARED"
    $preparedDedup.sideEffectsApplied = $false
    [System.IO.File]::WriteAllText(
        $dualDedupPath,
        ($preparedDedup | ConvertTo-Json -Compress -Depth 30),
        $Utf8NoBom
    )
    $preparedReplay = Invoke-Dispatch `
        -RawPayload (
            New-CopilotNativePayload `
                -Event PRE_TOOL_USE `
                -SessionId $copilotSession `
                -AcceptedAt $dualToolAt `
                -ToolName bash `
                -ToolInput @{ command = $dualCommand } `
                -StringArguments
        ) `
        -EventHint PRE_TOOL_USE `
        -AcceptedAt $dualToolAt.AddMilliseconds(2)
    Assert-Equal $preparedReplay.Decision "ALLOW" (
        "Durably issued command grant PREPARED replay did not recover."
    )
    Assert-Equal $preparedReplay.GrantId $compatGrant.GrantId (
        "PREPARED replay changed the deterministic grantId."
    )
    $recoveredDedup = [System.IO.File]::ReadAllText($dualDedupPath) |
        ConvertFrom-Json
    Assert-Equal $recoveredDedup.state "APPLIED" (
        "PREPARED command-grant replay did not converge to APPLIED."
    )

    $configPaths = @(
        (Join-Path $ClaudeRoot "settings.json"),
        (Join-Path $ClaudeRoot "distribution\templates\hooks\agents-hooks.json"),
        (Join-Path $ClaudeRoot "distribution\templates\hooks\cursor-hooks.json"),
        (Join-Path $ClaudeRoot "distribution\templates\hooks\copilot-hooks.json")
    )
    foreach ($configPath in $configPaths) {
        Assert-True (
            Test-Path -LiteralPath $configPath -PathType Leaf
        ) "Required native hook projection is missing: $configPath"
        $rawConfig = [System.IO.File]::ReadAllText($configPath)
        try {
            $rawConfig | ConvertFrom-Json -Depth 40 | Out-Null
        } catch {
            throw "Hook projection is invalid JSON: $configPath"
        }
        # Projection may invoke the dispatcher directly OR via the anti-self-lock
        # wrapper (hook-wrapper.ps1 forwards to hook-dispatcher.ps1, and degrades to
        # ALLOW when the submodule is uninitialized — breaking the self-lock where a
        # missing dispatcher blocks the very command that initializes it).
        $usesDispatcher = $rawConfig -match [regex]::Escape("hook-dispatcher.ps1")
        $usesWrapper = $rawConfig -match [regex]::Escape("hook-wrapper.ps1")
        Assert-True (
            $usesDispatcher -or $usesWrapper
        ) "Hook projection does not route through the shared dispatcher (directly or via hook-wrapper.ps1): $configPath"
        Assert-True (
            $rawConfig -notmatch "(?i)-(?:Harness|Agent)\b"
        ) "Hook projection contains a fixed identity argument: $configPath"
        Assert-True (
            $rawConfig -match "(?i)PRE_TOOL_USE"
        ) "Hook projection is missing all-tool PreToolUse: $configPath"
        # Hook deadline defaults to 10s (SERVER_NEW_WORKFLOW_HOOK_DEADLINE_MS override);
        # projection timeout must be >= that to avoid spuriously killing healthy hooks.
        $timeoutMatch = [regex]::Match($rawConfig, '(?i)"timeout"\s*:\s*(\d+)|"timeoutSec"\s*:\s*(\d+)')
        Assert-True (
            $timeoutMatch.Success -and
            ([int]($timeoutMatch.Groups[1].Value + $timeoutMatch.Groups[2].Value) -ge 5)
        ) "Hook projection does not configure a >=5s timeout: $configPath"
    }
    $cursorTemplate = [System.IO.File]::ReadAllText($configPaths[2])
    # failClosed may be false by design: the anti-self-lock wrapper degrades to ALLOW
    # when the dispatcher submodule is uninitialized, and Cursor mirrors that by not
    # failing closed (so a missing wrapper does not block all tool calls). The
    # contract is that the field is present and consistent, not that it is true.
    Assert-True (
        $cursorTemplate -match '"failClosed"\s*:\s*(true|false)'
    ) "Cursor projection is missing the failClosed field."

    $verifySource = [System.IO.File]::ReadAllText($VerifyScript)
    Assert-True (
        $verifySource -match [regex]::Escape("hook-dispatcher.ps1")
    ) "Live verification still bypasses the shared dispatcher."
    foreach ($registryVariable in @(
        "SERVER_NEW_WORKFLOW_REGISTRY",
        "SERVER_NEW_WORKFLOW_SESSION_REGISTRY",
        "SERVER_NEW_WORKFLOW_COMMAND_GRANT_REGISTRY",
        "SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY",
        "SERVER_NEW_HOOK_DEDUP_REGISTRY"
    )) {
        Assert-True (
            $verifySource -match [regex]::Escape($registryVariable)
        ) "Live verification does not isolate $registryVariable."
    }
    Assert-True (
        $verifySource -notmatch "cursor-p0-7bb519c61ff3"
    ) "Live verification references the current real Owner 1.0."
    Assert-True (
        $verifySource -match "normalPathMaxMs"
    ) "Live verification does not report normal-path performance."

    $perfSession = "dispatcher-performance"
    $perfStartAt = $now.AddMinutes(4)
    Invoke-Dispatch `
        -RawPayload (
            New-CursorPayload -Event SESSION_START -SessionId $perfSession
        ) `
        -EventHint SESSION_START `
        -AcceptedAt $perfStartAt | Out-Null
    $samples = @()
    foreach ($index in 1..12) {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $perf = Invoke-Dispatch `
            -RawPayload (
                New-CursorPayload `
                    -Event PRE_TOOL_USE `
                    -SessionId $perfSession `
                    -ToolName Edit `
                    -ToolInput @{
                        file_path = (
                            Join-Path $Workspace ".claude\scratch\perf-$index.txt"
                        )
                        old_string = "a"
                        new_string = "b"
                    } `
                    -Occurrence "perf-$index"
            ) `
            -EventHint PRE_TOOL_USE `
            -AcceptedAt $perfStartAt.AddSeconds($index)
        $watch.Stop()
        Assert-Equal $perf.Decision "ALLOW" (
            "Normal performance fixture unexpectedly denied."
        )
        $samples += $watch.ElapsedMilliseconds
    }
    $normalMax = ($samples | Measure-Object -Maximum).Maximum
    Assert-True ($normalMax -lt 1000) (
        "Normal dispatcher path exceeded 1000ms: max=${normalMax}ms."
    )

    $missingDepsDir = Join-Path $TestRoot "missing-deps"
    [System.IO.Directory]::CreateDirectory($missingDepsDir) | Out-Null
    Copy-Item -LiteralPath $DispatcherScript -Destination (Join-Path $missingDepsDir "hook-dispatcher.ps1")
    $missingDispatcher = Join-Path $missingDepsDir "hook-dispatcher.ps1"
    $pwshExe = (Get-Process -Id $PID).Path

    function Invoke-HiddenHookScript {
        param(
            [string]$File,
            [string]$EventHint,
            [string]$OutName
        )
        $outFile = Join-Path $TestRoot "$OutName.out"
        $errFile = Join-Path $TestRoot "$OutName.err"
        $proc = Start-AiSopHiddenProcess `
            -FilePath $pwshExe `
            -ArgumentList @("-NoProfile", "-File", $File, "-EventHint", $EventHint) `
            -RedirectStandardOutput $outFile `
            -RedirectStandardError $errFile `
            -PassThru
        $proc.WaitForExit()
        return [pscustomobject]@{
            ExitCode = $proc.ExitCode
            Output = [System.IO.File]::ReadAllText($outFile)
        }
    }

    $deny = Invoke-HiddenHookScript -File $missingDispatcher -EventHint PRE_TOOL_USE -OutName missing-deps-deny
    Assert-Equal $deny.ExitCode 2 "missing deps PRE_TOOL_USE must exit 2"
    Assert-True ($deny.Output -match "SOP_DEGRADED_MISSING_DEPS") "missing deps PRE_TOOL_USE must name reason"
    Assert-True ($deny.Output -match '"decision"\s*:\s*"deny"') "missing deps PRE_TOOL_USE must DENY"
    $allow = Invoke-HiddenHookScript -File $missingDispatcher -EventHint SESSION_START -OutName missing-deps-allow
    Assert-Equal $allow.ExitCode 0 "missing deps SESSION_START must exit 0"
    Assert-True ($allow.Output -match '"decision"\s*:\s*"ALLOW"') "missing deps SESSION_START must ALLOW"

    $wrapRoot = Join-Path $TestRoot "wrapper-ws"
    [System.IO.Directory]::CreateDirectory((Join-Path $wrapRoot ".agents")) | Out-Null
    $wrapperSrc = Join-Path $ClaudeRoot "distribution\templates\hooks\hook-wrapper.ps1"
    Copy-Item -LiteralPath $wrapperSrc -Destination (Join-Path $wrapRoot ".agents\hook-wrapper.ps1")
    $wrapperPath = Join-Path $wrapRoot ".agents\hook-wrapper.ps1"
    $wrapDeny = Invoke-HiddenHookScript -File $wrapperPath -EventHint PRE_TOOL_USE -OutName wrap-deny
    Assert-Equal $wrapDeny.ExitCode 2 "wrapper missing dispatcher PRE_TOOL_USE must exit 2"
    Assert-True ($wrapDeny.Output -match '"decision"\s*:\s*"deny"') (
        "wrapper missing dispatcher PRE_TOOL_USE must DENY"
    )
    $wrapAllow = Invoke-HiddenHookScript -File $wrapperPath -EventHint SESSION_START -OutName wrap-allow
    Assert-Equal $wrapAllow.ExitCode 0 "wrapper missing dispatcher SESSION_START must exit 0"
    Assert-True ($wrapAllow.Output -match '"decision"\s*:\s*"ALLOW"') (
        "wrapper missing dispatcher SESSION_START must ALLOW"
    )

    Write-Output (
        "All hook dispatcher tests passed. " +
        "normalPathMaxMs=$normalMax matrixRows=$matrixRows"
    )
} finally {
    foreach ($name in $RegistryVariables) {
        [Environment]::SetEnvironmentVariable(
            $name,
            [string]$SavedEnvironment[$name]
        )
    }
    if (Test-Path -LiteralPath $TestRoot) {
        [System.IO.Directory]::Delete($TestRoot, $true)
    }
}
