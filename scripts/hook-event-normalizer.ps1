#requires -Version 7.0

# Strictly recognizes certified native hook payloads and produces the
# authorization-neutral HookEvent described by DC-023. This file deliberately
# does not inspect hook configuration paths, environment-reported harness
# identity, Owner state, sessions, or grants.

$script:HookEventSchemaPath = Join-Path (
    Split-Path -Parent $PSScriptRoot
) "schemas\hook-event.schema.json"
$script:HookToolPolicyPath = Join-Path (
    Split-Path -Parent $PSScriptRoot
) "config\hook-tool-policy.json"
$script:HookToolPolicySchemaPath = Join-Path (
    Split-Path -Parent $PSScriptRoot
) "schemas\hook-tool-policy.schema.json"
$script:HookDedupSchemaPath = Join-Path (
    Split-Path -Parent $PSScriptRoot
) "schemas\hook-dedup.schema.json"
$script:PathIdentityScript = Join-Path $PSScriptRoot "path-identity.ps1"
$script:HookToolPolicyCache = @{}
$script:HookToolPolicyCacheLock = [object]::new()
$script:HookCorrelationSchema = @'
{
  "$schema":"https://json-schema.org/draft/2020-12/schema",
  "type":"object",
  "additionalProperties":false,
  "required":["correlationKey","normalizedTimestampEpochMs","expiresAt"],
  "properties":{
    "correlationKey":{"type":"string","pattern":"^[0-9a-f]{64}$"},
    "normalizedTimestampEpochMs":{"type":"integer","minimum":0},
    "expiresAt":{"type":"string","format":"date-time"}
  }
}
'@

if (-not (Get-Command Resolve-PhysicalPathIdentity -ErrorAction SilentlyContinue)) {
    . $script:PathIdentityScript
}

function Throw-AiSopHookError {
    param(
        [Parameter(Mandatory)]
        [string]$Code
    )

    throw [System.InvalidOperationException]::new($Code)
}

function Test-MapHasKey {
    param(
        [System.Collections.IDictionary]$Map,
        [string]$Key
    )

    return $Map.Contains($Key)
}

function ConvertFrom-AiSopJson {
    param(
        [Parameter(Mandatory)]
        [string]$Json
    )

    if ((Get-Command ConvertFrom-Json).Parameters.ContainsKey("DateKind")) {
        return $Json |
            ConvertFrom-Json -AsHashtable -Depth 100 -DateKind String
    }
    return $Json | ConvertFrom-Json -AsHashtable -Depth 100
}

function Test-StringValue {
    param(
        [AllowNull()]
        [object]$Value,
        [switch]$AllowEmpty
    )

    if ($Value -isnot [string]) {
        return $false
    }
    return $AllowEmpty -or -not [string]::IsNullOrWhiteSpace($Value)
}

function Test-IntegerValue {
    param([AllowNull()][object]$Value)

    return (
        $Value -is [byte] -or
        $Value -is [sbyte] -or
        $Value -is [int16] -or
        $Value -is [uint16] -or
        $Value -is [int32] -or
        $Value -is [uint32] -or
        $Value -is [int64] -or
        $Value -is [uint64]
    )
}

function Test-NumberValue {
    param([AllowNull()][object]$Value)

    return (
        (Test-IntegerValue $Value) -or
        $Value -is [single] -or
        $Value -is [double] -or
        $Value -is [decimal]
    )
}

function Test-ArrayValue {
    param([AllowNull()][object]$Value)

    return (
        $null -ne $Value -and
        $Value -isnot [string] -and
        $Value -isnot [System.Collections.IDictionary] -and
        $Value -is [System.Collections.IEnumerable]
    )
}

function Test-StringArrayValue {
    param(
        [AllowNull()]
        [object]$Value,
        [switch]$AllowEmpty
    )

    if (-not (Test-ArrayValue $Value)) {
        return $false
    }
    $items = @($Value)
    if (-not $AllowEmpty -and $items.Count -eq 0) {
        return $false
    }
    foreach ($item in $items) {
        if (-not (Test-StringValue $item)) {
            return $false
        }
    }
    return $true
}

function Test-OnlyAllowedFields {
    param(
        [System.Collections.IDictionary]$Payload,
        [string[]]$AllowedFields
    )

    $allowed = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($field in $AllowedFields) {
        [void]$allowed.Add($field)
    }
    foreach ($key in $Payload.Keys) {
        if (-not $allowed.Contains([string]$key)) {
            return $false
        }
    }
    return $true
}

function Test-RequiredStringFields {
    param(
        [System.Collections.IDictionary]$Payload,
        [string[]]$Fields
    )

    foreach ($field in $Fields) {
        if (
            -not (Test-MapHasKey $Payload $field) -or
            -not (Test-StringValue $Payload[$field])
        ) {
            return $false
        }
    }
    return $true
}

function Test-OptionalStringField {
    param(
        [System.Collections.IDictionary]$Payload,
        [string]$Field,
        [switch]$AllowNull
    )

    if (-not (Test-MapHasKey $Payload $Field)) {
        return $true
    }
    if ($AllowNull -and $null -eq $Payload[$Field]) {
        return $true
    }
    return Test-StringValue $Payload[$Field]
}

function Test-OptionalClaudeCommonFields {
    param([System.Collections.IDictionary]$Payload)

    foreach ($field in @(
        "prompt_id",
        "transcript_path",
        "agent_id",
        "agent_type"
    )) {
        if (-not (Test-OptionalStringField $Payload $field)) {
            return $false
        }
    }
    if (Test-MapHasKey $Payload "permission_mode") {
        if (
            $Payload.permission_mode -isnot [string] -or
            $Payload.permission_mode -notin @(
                "default",
                "plan",
                "acceptEdits",
                "auto",
                "dontAsk",
                "bypassPermissions"
            )
        ) {
            return $false
        }
    }
    if (Test-MapHasKey $Payload "effort") {
        $effort = $Payload.effort
        if (
            $effort -isnot [System.Collections.IDictionary] -or
            -not (Test-OnlyAllowedFields $effort @("level")) -or
            -not (Test-MapHasKey $effort "level") -or
            $effort.level -notin @("low", "medium", "high", "xhigh", "max")
        ) {
            return $false
        }
    }
    return $true
}

function Test-ClaudeSessionStartShape {
    param([System.Collections.IDictionary]$Payload)

    $allowed = @(
        "session_id",
        "prompt_id",
        "transcript_path",
        "cwd",
        "permission_mode",
        "effort",
        "hook_event_name",
        "agent_id",
        "agent_type",
        "source",
        "model",
        "session_title"
    )
    if (-not (Test-OnlyAllowedFields $Payload $allowed)) {
        return $false
    }
    if (-not (Test-RequiredStringFields $Payload @(
        "session_id",
        "cwd",
        "hook_event_name",
        "source"
    ))) {
        return $false
    }
    if ($Payload.hook_event_name -ne "SessionStart") {
        return $false
    }
    if ($Payload.source -notin @("startup", "resume", "clear", "compact", "fork")) {
        return $false
    }
    if (
        -not (Test-OptionalStringField $Payload "model") -or
        -not (Test-OptionalStringField $Payload "session_title")
    ) {
        return $false
    }
    return Test-OptionalClaudeCommonFields $Payload
}

function Test-ClaudeSessionEndShape {
    param([System.Collections.IDictionary]$Payload)

    $allowed = @(
        "session_id",
        "prompt_id",
        "transcript_path",
        "cwd",
        "permission_mode",
        "effort",
        "hook_event_name",
        "agent_id",
        "agent_type",
        "reason"
    )
    if (-not (Test-OnlyAllowedFields $Payload $allowed)) {
        return $false
    }
    if (-not (Test-RequiredStringFields $Payload @(
        "session_id",
        "cwd",
        "hook_event_name",
        "reason"
    ))) {
        return $false
    }
    if ($Payload.hook_event_name -ne "SessionEnd") {
        return $false
    }
    if ($Payload.reason -notin @(
        "clear",
        "resume",
        "logout",
        "prompt_input_exit",
        "bypass_permissions_disabled",
        "other"
    )) {
        return $false
    }
    return Test-OptionalClaudeCommonFields $Payload
}

function Test-ClaudePreToolUseShape {
    param([System.Collections.IDictionary]$Payload)

    $allowed = @(
        "session_id",
        "prompt_id",
        "transcript_path",
        "cwd",
        "permission_mode",
        "effort",
        "hook_event_name",
        "agent_id",
        "agent_type",
        "tool_name",
        "tool_input",
        "tool_use_id"
    )
    if (-not (Test-OnlyAllowedFields $Payload $allowed)) {
        return $false
    }
    if (-not (Test-RequiredStringFields $Payload @(
        "session_id",
        "cwd",
        "hook_event_name",
        "tool_name",
        "tool_use_id"
    ))) {
        return $false
    }
    if (
        $Payload.hook_event_name -ne "PreToolUse" -or
        $Payload.tool_input -isnot [System.Collections.IDictionary]
    ) {
        return $false
    }
    return Test-OptionalClaudeCommonFields $Payload
}

function Test-IsoTimestampWithZone {
    param([AllowNull()][object]$Value)

    if (
        $Value -isnot [string] -or
        $Value -notmatch "(?:Z|[+-][0-9]{2}:[0-9]{2})$"
    ) {
        return $false
    }
    $parsed = [DateTimeOffset]::MinValue
    return [DateTimeOffset]::TryParse($Value, [ref]$parsed)
}

function Test-CopilotCompatShape {
    param(
        [System.Collections.IDictionary]$Payload,
        [string]$EventHint
    )

    switch ($EventHint) {
        "SESSION_START" {
            $allowed = @(
                "hook_event_name",
                "session_id",
                "timestamp",
                "cwd",
                "source",
                "initial_prompt"
            )
            if (-not (Test-OnlyAllowedFields $Payload $allowed)) {
                return $false
            }
            if (-not (Test-RequiredStringFields $Payload @(
                "hook_event_name",
                "session_id",
                "timestamp",
                "cwd"
            ))) {
                return $false
            }
            return (
                $Payload.hook_event_name -eq "SessionStart" -and
                (Test-IsoTimestampWithZone $Payload.timestamp) -and
                (Test-OptionalStringField $Payload "initial_prompt") -and
                (Test-OptionalStringField $Payload "source") -and
                (
                    -not (Test-MapHasKey $Payload "source") -or
                    $Payload.source -in @("startup", "resume", "new")
                )
            )
        }
        "SESSION_END" {
            $allowed = @(
                "hook_event_name",
                "session_id",
                "timestamp",
                "cwd",
                "reason"
            )
            if (-not (Test-OnlyAllowedFields $Payload $allowed)) {
                return $false
            }
            if (-not (Test-RequiredStringFields $Payload @(
                "hook_event_name",
                "session_id",
                "timestamp",
                "cwd"
            ))) {
                return $false
            }
            return (
                $Payload.hook_event_name -eq "SessionEnd" -and
                (Test-IsoTimestampWithZone $Payload.timestamp) -and
                (Test-OptionalStringField $Payload "reason") -and
                (
                    -not (Test-MapHasKey $Payload "reason") -or
                    $Payload.reason -in @("complete", "error", "abort", "timeout", "user_exit")
                )
            )
        }
        "PRE_TOOL_USE" {
            $allowed = @(
                "hook_event_name",
                "session_id",
                "timestamp",
                "cwd",
                "tool_name",
                "tool_input"
            )
            if (-not (Test-OnlyAllowedFields $Payload $allowed)) {
                return $false
            }
            if (-not (Test-RequiredStringFields $Payload @(
                "hook_event_name",
                "session_id",
                "timestamp",
                "cwd",
                "tool_name"
            ))) {
                return $false
            }
            return (
                $Payload.hook_event_name -eq "PreToolUse" -and
                $Payload.tool_input -is [System.Collections.IDictionary] -and
                (Test-IsoTimestampWithZone $Payload.timestamp)
            )
        }
        default {
            return $false
        }
    }
}

function Test-CopilotNativeShape {
    param(
        [System.Collections.IDictionary]$Payload,
        [string]$EventHint
    )

    switch ($EventHint) {
        "SESSION_START" {
            $allowed = @("sessionId", "timestamp", "cwd", "source", "initialPrompt")
            if (-not (Test-OnlyAllowedFields $Payload $allowed)) {
                return $false
            }
            if (-not (Test-RequiredStringFields $Payload @("sessionId", "cwd"))) {
                return $false
            }
            return (
                (Test-MapHasKey $Payload "timestamp") -and
                (Test-IntegerValue $Payload.timestamp) -and
                (Test-OptionalStringField $Payload "initialPrompt") -and
                (Test-OptionalStringField $Payload "source") -and
                (
                    -not (Test-MapHasKey $Payload "source") -or
                    $Payload.source -in @("startup", "resume", "new")
                )
            )
        }
        "SESSION_END" {
            $allowed = @("sessionId", "timestamp", "cwd", "reason")
            if (-not (Test-OnlyAllowedFields $Payload $allowed)) {
                return $false
            }
            if (-not (Test-RequiredStringFields $Payload @("sessionId", "cwd"))) {
                return $false
            }
            return (
                (Test-MapHasKey $Payload "timestamp") -and
                (Test-IntegerValue $Payload.timestamp) -and
                (Test-OptionalStringField $Payload "reason") -and
                (
                    -not (Test-MapHasKey $Payload "reason") -or
                    $Payload.reason -in @("complete", "error", "abort", "timeout", "user_exit")
                )
            )
        }
        "PRE_TOOL_USE" {
            $allowed = @("sessionId", "timestamp", "cwd", "toolName", "toolArgs")
            if (-not (Test-OnlyAllowedFields $Payload $allowed)) {
                return $false
            }
            if (-not (Test-RequiredStringFields $Payload @("sessionId", "cwd", "toolName"))) {
                return $false
            }
            return (
                (Test-MapHasKey $Payload "timestamp") -and
                (Test-IntegerValue $Payload.timestamp) -and
                (Test-MapHasKey $Payload "toolArgs") -and
                (
                    $Payload.toolArgs -is [System.Collections.IDictionary] -or
                    $Payload.toolArgs -is [string]
                )
            )
        }
        default {
            return $false
        }
    }
}

function Test-CursorSessionStartShape {
    param([System.Collections.IDictionary]$Payload)

    if (-not (Test-OnlyAllowedFields $Payload @(
        "session_id",
        "is_background_agent",
        "composer_mode"
    ))) {
        return $false
    }
    if (
        -not (Test-RequiredStringFields $Payload @("session_id")) -or
        -not (Test-MapHasKey $Payload "is_background_agent") -or
        $Payload.is_background_agent -isnot [bool]
    ) {
        return $false
    }
    if (Test-MapHasKey $Payload "composer_mode") {
        return (
            $Payload.composer_mode -is [string] -and
            $Payload.composer_mode -in @("agent", "ask", "edit")
        )
    }
    return $true
}

function Test-CursorSessionEndShape {
    param([System.Collections.IDictionary]$Payload)

    if (-not (Test-OnlyAllowedFields $Payload @(
        "session_id",
        "reason",
        "duration_ms",
        "is_background_agent",
        "final_status",
        "error_message"
    ))) {
        return $false
    }
    if (-not (Test-RequiredStringFields $Payload @(
        "session_id",
        "reason",
        "final_status"
    ))) {
        return $false
    }
    if (
        -not (Test-MapHasKey $Payload "duration_ms") -or
        -not (Test-NumberValue $Payload.duration_ms) -or
        [decimal]$Payload.duration_ms -lt 0 -or
        -not (Test-MapHasKey $Payload "is_background_agent") -or
        $Payload.is_background_agent -isnot [bool] -or
        $Payload.reason -notin @(
            "completed",
            "aborted",
            "error",
            "window_close",
            "user_close"
        ) -or
        -not (Test-OptionalStringField $Payload "error_message")
    ) {
        return $false
    }
    return $true
}

function Test-CursorModelParams {
    param([AllowNull()][object]$Value)

    if (-not (Test-ArrayValue $Value)) {
        return $false
    }
    foreach ($item in @($Value)) {
        if (
            $item -isnot [System.Collections.IDictionary] -or
            -not (Test-OnlyAllowedFields $item @("id", "value")) -or
            -not (Test-RequiredStringFields $item @("id", "value"))
        ) {
            return $false
        }
    }
    return $true
}

function Test-CursorPreToolUseShape {
    param([System.Collections.IDictionary]$Payload)

    $allowed = @(
        "conversation_id",
        "generation_id",
        "model",
        "model_id",
        "model_params",
        "hook_event_name",
        "cursor_version",
        "workspace_roots",
        "user_email",
        "transcript_path",
        "tool_name",
        "tool_input",
        "tool_use_id",
        "cwd",
        "agent_message"
    )
    if (-not (Test-OnlyAllowedFields $Payload $allowed)) {
        return $false
    }
    if (-not (Test-RequiredStringFields $Payload @(
        "conversation_id",
        "generation_id",
        "cwd",
        "tool_name"
    ))) {
        return $false
    }
    if (
        -not (Test-MapHasKey $Payload "workspace_roots") -or
        -not (Test-StringArrayValue $Payload.workspace_roots) -or
        -not (Test-MapHasKey $Payload "tool_input") -or
        $Payload.tool_input -isnot [System.Collections.IDictionary]
    ) {
        return $false
    }
    foreach ($field in @(
        "model",
        "model_id",
        "cursor_version",
        "tool_use_id",
        "agent_message"
    )) {
        if (-not (Test-OptionalStringField $Payload $field)) {
            return $false
        }
    }
    foreach ($field in @("user_email", "transcript_path")) {
        if (-not (Test-OptionalStringField $Payload $field -AllowNull)) {
            return $false
        }
    }
    if (
        (Test-MapHasKey $Payload "model_params") -and
        -not (Test-CursorModelParams $Payload.model_params)
    ) {
        return $false
    }
    if (
        (Test-MapHasKey $Payload "hook_event_name") -and
        $Payload.hook_event_name -ne "preToolUse"
    ) {
        return $false
    }
    return $true
}

function Test-AntigravityShape {
    param(
        [System.Collections.IDictionary]$Payload,
        [string]$EventHint
    )

    # Real Antigravity payloads include product metadata beyond the
    # session/roots discriminators (transcriptPath, modelName, stepIdx, ...).
    # Reject only cross-harness fields; extra native keys are allowed.
    foreach ($foreign in @(
        "session_id",
        "sessionId",
        "conversation_id",
        "workspace_roots",
        "tool_name",
        "tool_input",
        "hook_event_name",
        "toolName",
        "toolArgs"
    )) {
        if (Test-MapHasKey $Payload $foreign) {
            return $false
        }
    }

    switch ($EventHint) {
        "PRE_INVOCATION" {
            if (
                (Test-MapHasKey $Payload "toolCall") -or
                (Test-MapHasKey $Payload "fullyIdle")
            ) {
                return $false
            }
        }
        "PRE_TOOL_USE" {
            if (
                -not (Test-MapHasKey $Payload "toolCall") -or
                $Payload.toolCall -isnot [System.Collections.IDictionary] -or
                -not (Test-RequiredStringFields $Payload.toolCall @("name")) -or
                -not (Test-MapHasKey $Payload.toolCall "args") -or
                $Payload.toolCall.args -isnot [System.Collections.IDictionary]
            ) {
                return $false
            }
        }
        "STOP" {
            if (
                -not (Test-MapHasKey $Payload "fullyIdle") -or
                $Payload.fullyIdle -isnot [bool]
            ) {
                return $false
            }
        }
        default {
            return $false
        }
    }
    return (
        (Test-RequiredStringFields $Payload @("conversationId")) -and
        (Test-MapHasKey $Payload "workspacePaths") -and
        (Test-StringArrayValue $Payload.workspacePaths)
    )
}

function Test-KnownPayloadSignal {
    param([System.Collections.IDictionary]$Payload)

    foreach ($field in @(
        "session_id",
        "hook_event_name",
        "sessionId",
        "conversation_id",
        "generation_id",
        "is_background_agent",
        "conversationId",
        "workspacePaths",
        "toolCall",
        "fullyIdle"
    )) {
        if (Test-MapHasKey $Payload $field) {
            return $true
        }
    }
    return $false
}

function Test-HybridPayloadSignals {
    param([System.Collections.IDictionary]$Payload)

    $hasSnakeSession = (
        (Test-MapHasKey $Payload "session_id") -or
        (Test-MapHasKey $Payload "hook_event_name")
    )
    $hasCopilotCamel = (
        (Test-MapHasKey $Payload "sessionId") -or
        (Test-MapHasKey $Payload "toolName") -or
        (Test-MapHasKey $Payload "toolArgs")
    )
    if ($hasSnakeSession -and $hasCopilotCamel) {
        return $true
    }
    if (
        (Test-MapHasKey $Payload "timestamp") -and
        (
            (Test-MapHasKey $Payload "tool_use_id") -or
            (Test-MapHasKey $Payload "permission_mode") -or
            (Test-MapHasKey $Payload "transcript_path")
        )
    ) {
        return $true
    }
    if (
        (Test-MapHasKey $Payload "conversation_id") -and
        (
            (Test-MapHasKey $Payload "session_id") -or
            (Test-MapHasKey $Payload "sessionId") -or
            (Test-MapHasKey $Payload "conversationId")
        )
    ) {
        return $true
    }
    if (
        (Test-MapHasKey $Payload "toolCall") -and
        (
            (Test-MapHasKey $Payload "tool_name") -or
            (Test-MapHasKey $Payload "toolName")
        )
    ) {
        return $true
    }
    return $false
}

function Assert-AiSopEventHint {
    param(
        [System.Collections.IDictionary]$Payload,
        [string]$EventHint
    )

    if ($EventHint -notin @(
        "SESSION_START",
        "PRE_INVOCATION",
        "PRE_TOOL_USE",
        "SESSION_END",
        "STOP"
    )) {
        Throw-AiSopHookError "EVENT_HINT_MISMATCH"
    }

    if (Test-MapHasKey $Payload "hook_event_name") {
        $nativeEvent = switch ($Payload.hook_event_name) {
            "SessionStart" { "SESSION_START" }
            "SessionEnd" { "SESSION_END" }
            "PreToolUse" { "PRE_TOOL_USE" }
            "sessionStart" { "SESSION_START" }
            "sessionEnd" { "SESSION_END" }
            "preToolUse" { "PRE_TOOL_USE" }
            default { "" }
        }
        if ($nativeEvent -and $nativeEvent -ne $EventHint) {
            Throw-AiSopHookError "EVENT_HINT_MISMATCH"
        }
    }
    if (Test-MapHasKey $Payload "sessionId") {
        if (
            (
                (Test-MapHasKey $Payload "toolName") -or
                (Test-MapHasKey $Payload "toolArgs")
            ) -and
            $EventHint -ne "PRE_TOOL_USE"
        ) {
            Throw-AiSopHookError "EVENT_HINT_MISMATCH"
        }
        if (
            (Test-MapHasKey $Payload "source") -and
            $EventHint -ne "SESSION_START"
        ) {
            Throw-AiSopHookError "EVENT_HINT_MISMATCH"
        }
        if (
            (Test-MapHasKey $Payload "reason") -and
            $EventHint -ne "SESSION_END"
        ) {
            Throw-AiSopHookError "EVENT_HINT_MISMATCH"
        }
    }
    if (
        (Test-MapHasKey $Payload "conversation_id") -and
        $EventHint -ne "PRE_TOOL_USE"
    ) {
        Throw-AiSopHookError "EVENT_HINT_MISMATCH"
    }
    if (Test-MapHasKey $Payload "is_background_agent") {
        $looksLikeEnd = (
            (Test-MapHasKey $Payload "duration_ms") -or
            (Test-MapHasKey $Payload "final_status") -or
            (Test-MapHasKey $Payload "reason")
        )
        if ($looksLikeEnd -and $EventHint -ne "SESSION_END") {
            Throw-AiSopHookError "EVENT_HINT_MISMATCH"
        }
        if (-not $looksLikeEnd -and $EventHint -ne "SESSION_START") {
            Throw-AiSopHookError "EVENT_HINT_MISMATCH"
        }
    }
    if (
        (Test-MapHasKey $Payload "toolCall") -and
        $EventHint -ne "PRE_TOOL_USE"
    ) {
        Throw-AiSopHookError "EVENT_HINT_MISMATCH"
    }
    if (
        (Test-MapHasKey $Payload "fullyIdle") -and
        $EventHint -ne "STOP"
    ) {
        Throw-AiSopHookError "EVENT_HINT_MISMATCH"
    }
}

function Resolve-AiSopNativeShape {
    param(
        [System.Collections.IDictionary]$Payload,
        [string]$EventHint
    )

    Assert-AiSopEventHint $Payload $EventHint
    if (Test-HybridPayloadSignals $Payload) {
        Throw-AiSopHookError "PAYLOAD_SHAPE_AMBIGUOUS"
    }

    $matches = @()
    if ($EventHint -eq "SESSION_START") {
        if (Test-ClaudeSessionStartShape $Payload) {
            $matches += [pscustomobject]@{
                Agent = "CLAUDE_CODE"
                NativeShape = "CLAUDE_SESSION_START"
            }
        }
        if (Test-CopilotCompatShape $Payload $EventHint) {
            $matches += [pscustomobject]@{
                Agent = "COPILOT"
                NativeShape = "COPILOT_CLAUDE_COMPAT"
            }
        }
        if (Test-CopilotNativeShape $Payload $EventHint) {
            $matches += [pscustomobject]@{
                Agent = "COPILOT"
                NativeShape = "COPILOT_GITHUB_NATIVE"
            }
        }
        if (Test-CursorSessionStartShape $Payload) {
            $matches += [pscustomobject]@{
                Agent = "CURSOR"
                NativeShape = "CURSOR_SESSION_START"
            }
        }
    } elseif ($EventHint -eq "SESSION_END") {
        if (Test-ClaudeSessionEndShape $Payload) {
            $matches += [pscustomobject]@{
                Agent = "CLAUDE_CODE"
                NativeShape = "CLAUDE_SESSION_END"
            }
        }
        if (Test-CopilotCompatShape $Payload $EventHint) {
            $matches += [pscustomobject]@{
                Agent = "COPILOT"
                NativeShape = "COPILOT_CLAUDE_COMPAT"
            }
        }
        if (Test-CopilotNativeShape $Payload $EventHint) {
            $matches += [pscustomobject]@{
                Agent = "COPILOT"
                NativeShape = "COPILOT_GITHUB_NATIVE"
            }
        }
        if (Test-CursorSessionEndShape $Payload) {
            $matches += [pscustomobject]@{
                Agent = "CURSOR"
                NativeShape = "CURSOR_SESSION_END"
            }
        }
    } elseif ($EventHint -eq "PRE_TOOL_USE") {
        if (Test-ClaudePreToolUseShape $Payload) {
            $matches += [pscustomobject]@{
                Agent = "CLAUDE_CODE"
                NativeShape = "CLAUDE_PRE_TOOL_USE"
            }
        }
        if (Test-CopilotCompatShape $Payload $EventHint) {
            $matches += [pscustomobject]@{
                Agent = "COPILOT"
                NativeShape = "COPILOT_CLAUDE_COMPAT"
            }
        }
        if (Test-CopilotNativeShape $Payload $EventHint) {
            $matches += [pscustomobject]@{
                Agent = "COPILOT"
                NativeShape = "COPILOT_GITHUB_NATIVE"
            }
        }
        if (Test-CursorPreToolUseShape $Payload) {
            $matches += [pscustomobject]@{
                Agent = "CURSOR"
                NativeShape = "CURSOR_PRE_TOOL_USE"
            }
        }
        if (Test-AntigravityShape $Payload $EventHint) {
            $matches += [pscustomobject]@{
                Agent = "ANTIGRAVITY"
                NativeShape = "ANTIGRAVITY"
            }
        }
    } elseif ($EventHint -in @("PRE_INVOCATION", "STOP")) {
        if (Test-AntigravityShape $Payload $EventHint) {
            $matches += [pscustomobject]@{
                Agent = "ANTIGRAVITY"
                NativeShape = "ANTIGRAVITY"
            }
        }
    }

    if ($matches.Count -gt 1) {
        Throw-AiSopHookError "PAYLOAD_SHAPE_AMBIGUOUS"
    }
    if ($matches.Count -eq 0) {
        if (Test-KnownPayloadSignal $Payload) {
            Throw-AiSopHookError "PAYLOAD_SHAPE_INVALID"
        }
        Throw-AiSopHookError "PAYLOAD_SHAPE_UNKNOWN"
    }
    return $matches[0]
}

function Get-AiSopSha256Hex {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Value)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash($bytes)
    } finally {
        $sha.Dispose()
    }
    return ([System.BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
}

function ConvertTo-AiSopCanonicalNode {
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object]$Value
    )

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $canonical = [ordered]@{}
        $keys = [string[]]@($Value.Keys | ForEach-Object { [string]$_ })
        [System.Array]::Sort($keys, [System.StringComparer]::Ordinal)
        foreach ($key in $keys) {
            $canonical[$key] = ConvertTo-AiSopCanonicalNode -Value $Value[$key]
        }
        return $canonical
    }
    if (Test-ArrayValue $Value) {
        return ,@(
            foreach ($item in @($Value)) {
                ConvertTo-AiSopCanonicalNode -Value $item
            }
        )
    }
    if ($Value -is [DateTimeOffset]) {
        return $Value.ToUniversalTime().ToString("o")
    }
    return $Value
}

function ConvertTo-AiSopCanonicalJson {
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object]$Value
    )

    $canonical = ConvertTo-AiSopCanonicalNode -Value $Value
    return ConvertTo-Json -InputObject $canonical -Compress -Depth 100
}

function Test-AiSopPathWithinRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    if ($Path.Equals($Root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $rootPrefix = $Root.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    ) + [System.IO.Path]::DirectorySeparatorChar
    return $Path.StartsWith(
        $rootPrefix,
        [System.StringComparison]::OrdinalIgnoreCase
    )
}

function Resolve-AiSopWorkspacePathIdentity {
    param(
        [string]$Path,
        [string]$WorkspaceRoot,
        [string]$BasePath,
        [string]$OutsideErrorCode = "EDIT_PATH_OUTSIDE_WORKSPACE"
    )

    try {
        $lexical = if ([System.IO.Path]::IsPathRooted($Path)) {
            [System.IO.Path]::GetFullPath($Path)
        } else {
            [System.IO.Path]::GetFullPath((Join-Path $BasePath $Path))
        }
    } catch {
        Throw-AiSopHookError "EDIT_PATH_AMBIGUOUS"
    }
    if (-not (Test-AiSopPathWithinRoot $lexical $WorkspaceRoot)) {
        Throw-AiSopHookError $OutsideErrorCode
    }
    try {
        $physical = Resolve-PhysicalPathIdentity -Path $lexical
    } catch {
        Throw-AiSopHookError "EDIT_PATH_AMBIGUOUS"
    }
    if (-not (Test-AiSopPathWithinRoot $physical $WorkspaceRoot)) {
        Throw-AiSopHookError $OutsideErrorCode
    }
    return [pscustomobject]@{
        Lexical = $lexical
        Physical = $physical
    }
}

function Resolve-AiSopWorkspacePath {
    param(
        [string]$Path,
        [string]$WorkspaceRoot,
        [string]$BasePath,
        [string]$OutsideErrorCode = "EDIT_PATH_OUTSIDE_WORKSPACE"
    )

    return (
        Resolve-AiSopWorkspacePathIdentity `
            -Path $Path `
            -WorkspaceRoot $WorkspaceRoot `
            -BasePath $BasePath `
            -OutsideErrorCode $OutsideErrorCode
    ).Physical
}

function ConvertTo-AiSopUniquePathList {
    param([string[]]$Paths)

    $unique = [System.Collections.Generic.Dictionary[string, string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase
    )
    foreach ($path in $Paths) {
        if (-not $unique.ContainsKey($path)) {
            $unique.Add($path, $path)
        }
    }
    $values = [string[]]@($unique.Values)
    [System.Array]::Sort($values, [System.StringComparer]::Ordinal)
    return ,@($values)
}

function Get-AiSopWorkspaceContext {
    param(
        [System.Collections.IDictionary]$Payload,
        [string]$NativeShape,
        [string]$TrustedWorkspaceRoot
    )

    try {
        $workspace = Resolve-PhysicalPathIdentity -Path $TrustedWorkspaceRoot
    } catch {
        Throw-AiSopHookError "EDIT_PATH_AMBIGUOUS"
    }
    $cwdCandidate = if (Test-MapHasKey $Payload "cwd") {
        [string]$Payload.cwd
    } else {
        $workspace
    }
    $cwd = Resolve-AiSopWorkspacePath `
        -Path $cwdCandidate -WorkspaceRoot $workspace -BasePath $workspace

    $rootCandidates = @($workspace)
    if ($NativeShape -eq "CURSOR_PRE_TOOL_USE") {
        $rootCandidates = @($Payload.workspace_roots)
    } elseif ($NativeShape -eq "ANTIGRAVITY") {
        $rootCandidates = @($Payload.workspacePaths)
    }
    $roots = @()
    foreach ($rootCandidate in $rootCandidates) {
        $roots += Resolve-AiSopWorkspacePath `
            -Path ([string]$rootCandidate) `
            -WorkspaceRoot $workspace `
            -BasePath $workspace
    }
    $roots = ConvertTo-AiSopUniquePathList $roots
    $containingRootCount = @(
        $roots | Where-Object { Test-AiSopPathWithinRoot $cwd $_ }
    ).Count
    if ($containingRootCount -ne 1) {
        Throw-AiSopHookError "EDIT_PATH_AMBIGUOUS"
    }
    return [pscustomobject]@{
        WorkspacePath = $workspace
        WorkspaceRoots = @($roots)
        Cwd = $cwd
    }
}

function Test-AiSopMapAllowedTypes {
    param(
        [System.Collections.IDictionary]$Arguments,
        [string[]]$AllowedFields
    )

    return Test-OnlyAllowedFields $Arguments $AllowedFields
}

function Get-AiSopPathFieldValues {
    param(
        [System.Collections.IDictionary]$Arguments,
        [switch]$IncludePlural
    )

    $values = @()
    foreach ($field in @(
        "file_path",
        "path",
        "file",
        "target_file",
        "filePath",
        "TargetFile",
        "targetFile",
        "target_notebook",
        "notebook_path",
        "AbsolutePath",
        "absolute_path",
        "DirectoryPath",
        "directory_path"
    )) {
        if (Test-MapHasKey $Arguments $field) {
            if (-not (Test-StringValue $Arguments[$field])) {
                return $null
            }
            $values += [string]$Arguments[$field]
        }
    }
    if ($IncludePlural) {
        foreach ($field in @("paths", "files", "targets")) {
            if (Test-MapHasKey $Arguments $field) {
                if (-not (Test-StringArrayValue $Arguments[$field])) {
                    return $null
                }
                $values += @($Arguments[$field])
            }
        }
    }
    return ,@($values)
}

function Test-AiSopToolArgumentProfile {
    param(
        [System.Collections.IDictionary]$Arguments,
        [string]$Profile
    )

    switch ($Profile) {
        "ANY_OBJECT" {
            return $true
        }
        "READ" {
            if (-not (Test-AiSopMapAllowedTypes $Arguments @(
                "file_path",
                "path",
                "file",
                "target_file",
                "filePath",
                "offset",
                "limit",
                "line_start",
                "line_end"
            ))) {
                return $false
            }
            $paths = Get-AiSopPathFieldValues $Arguments
            if ($null -eq $paths -or @($paths).Count -ne 1) {
                return $false
            }
            foreach ($field in @("offset", "limit", "line_start", "line_end")) {
                if (
                    (Test-MapHasKey $Arguments $field) -and
                    -not (Test-IntegerValue $Arguments[$field])
                ) {
                    return $false
                }
            }
            return $true
        }
        "GLOB" {
            if (-not (Test-AiSopMapAllowedTypes $Arguments @(
                "pattern",
                "glob_pattern",
                "path",
                "target_directory",
                "include",
                "exclude"
            ))) {
                return $false
            }
            $patternFields = @(
                @("pattern", "glob_pattern") |
                    Where-Object { Test-MapHasKey $Arguments $_ }
            )
            if (
                $patternFields.Count -ne 1 -or
                -not (Test-StringValue $Arguments[$patternFields[0]])
            ) {
                return $false
            }
            $pathFields = @(
                @("path", "target_directory") |
                    Where-Object { Test-MapHasKey $Arguments $_ }
            )
            if ($pathFields.Count -gt 1) {
                return $false
            }
            foreach ($field in @("path", "target_directory", "include", "exclude")) {
                if (
                    (Test-MapHasKey $Arguments $field) -and
                    -not (Test-StringValue $Arguments[$field])
                ) {
                    return $false
                }
            }
            return $true
        }
        "SEARCH" {
            if (-not (Test-AiSopMapAllowedTypes $Arguments @(
                "pattern",
                "query",
                "search_term",
                "path",
                "glob",
                "output_mode",
                "-B",
                "-A",
                "-C",
                "-i",
                "type",
                "head_limit",
                "offset",
                "multiline"
            ))) {
                return $false
            }
            $patternFields = @(
                @("pattern", "query", "search_term") |
                    Where-Object { Test-MapHasKey $Arguments $_ }
            )
            if (
                $patternFields.Count -ne 1 -or
                -not (Test-StringValue $Arguments[$patternFields[0]])
            ) {
                return $false
            }
            foreach ($field in @("path", "glob", "output_mode", "type")) {
                if (
                    (Test-MapHasKey $Arguments $field) -and
                    -not (Test-StringValue $Arguments[$field])
                ) {
                    return $false
                }
            }
            foreach ($field in @("-B", "-A", "-C", "head_limit", "offset")) {
                if (
                    (Test-MapHasKey $Arguments $field) -and
                    -not (Test-IntegerValue $Arguments[$field])
                ) {
                    return $false
                }
            }
            foreach ($field in @("-i", "multiline")) {
                if (
                    (Test-MapHasKey $Arguments $field) -and
                    $Arguments[$field] -isnot [bool]
                ) {
                    return $false
                }
            }
            return $true
        }
        "EDIT" {
            if (-not (Test-AiSopMapAllowedTypes $Arguments @(
                "file_path",
                "path",
                "file",
                "target_file",
                "filePath",
                "TargetFile",
                "targetFile",
                "old_string",
                "new_string",
                "old_str",
                "new_str",
                "oldText",
                "newText",
                "old_text",
                "new_text",
                "TargetContent",
                "targetContent",
                "ReplacementContent",
                "replacementContent",
                "replace_all",
                "AllowMultiple",
                "allowMultiple",
                "Instruction",
                "instruction",
                "Description",
                "description",
                "StartLine",
                "startLine",
                "EndLine",
                "endLine",
                "TargetLintErrorIds",
                "targetLintErrorIds",
                "toolAction",
                "toolSummary",
                "tool_action",
                "tool_summary"
            ))) {
                return $false
            }
            $paths = Get-AiSopPathFieldValues $Arguments
            if ($null -eq $paths -or @($paths).Count -ne 1) {
                return $false
            }
            $oldPresent = @(
                "old_string",
                "old_str",
                "oldText",
                "old_text",
                "TargetContent",
                "targetContent"
            ) | Where-Object { Test-MapHasKey $Arguments $_ }
            $newPresent = @(
                "new_string",
                "new_str",
                "newText",
                "new_text",
                "ReplacementContent",
                "replacementContent"
            ) | Where-Object { Test-MapHasKey $Arguments $_ }
            if ($oldPresent.Count -ne 1 -or $newPresent.Count -ne 1) {
                return $false
            }
            $oldField = @($oldPresent)[0]
            $newField = @($newPresent)[0]
            if (
                -not (Test-StringValue $Arguments[$oldField] -AllowEmpty) -or
                -not (Test-StringValue $Arguments[$newField] -AllowEmpty)
            ) {
                return $false
            }
            if (
                (Test-MapHasKey $Arguments "replace_all") -and
                $Arguments.replace_all -isnot [bool]
            ) {
                return $false
            }
            if (
                (Test-MapHasKey $Arguments "AllowMultiple") -and
                $Arguments.AllowMultiple -isnot [bool]
            ) {
                return $false
            }
            if (
                (Test-MapHasKey $Arguments "allowMultiple") -and
                $Arguments.allowMultiple -isnot [bool]
            ) {
                return $false
            }
            return $true
        }
        "WRITE" {
            if (-not (Test-AiSopMapAllowedTypes $Arguments @(
                "file_path",
                "path",
                "file",
                "target_file",
                "filePath",
                "TargetFile",
                "targetFile",
                "content",
                "contents",
                "CodeContent",
                "codeContent",
                "Overwrite",
                "overwrite",
                "Description",
                "description",
                "ArtifactMetadata",
                "artifactMetadata",
                "toolAction",
                "toolSummary",
                "tool_action",
                "tool_summary"
            ))) {
                return $false
            }
            $paths = Get-AiSopPathFieldValues $Arguments
            $contentPresent = @(
                "content",
                "contents",
                "CodeContent",
                "codeContent"
            ) | Where-Object { Test-MapHasKey $Arguments $_ }
            if ($contentPresent.Count -ne 1) {
                return $false
            }
            $contentField = @($contentPresent)[0]
            if (
                (Test-MapHasKey $Arguments "Overwrite") -and
                $Arguments.Overwrite -isnot [bool]
            ) {
                return $false
            }
            if (
                (Test-MapHasKey $Arguments "overwrite") -and
                $Arguments.overwrite -isnot [bool]
            ) {
                return $false
            }
            return (
                $null -ne $paths -and
                @($paths).Count -eq 1 -and
                (Test-StringValue $Arguments[$contentField] -AllowEmpty)
            )
        }
        "MULTI_EDIT" {
            if (-not (Test-AiSopMapAllowedTypes $Arguments @(
                "file_path",
                "path",
                "file",
                "target_file",
                "filePath",
                "edits"
            ))) {
                return $false
            }
            if (
                -not (Test-MapHasKey $Arguments "edits") -or
                -not (Test-ArrayValue $Arguments.edits) -or
                @($Arguments.edits).Count -eq 0
            ) {
                return $false
            }
            $topPaths = Get-AiSopPathFieldValues $Arguments
            if ($null -eq $topPaths -or @($topPaths).Count -gt 1) {
                return $false
            }
            foreach ($edit in @($Arguments.edits)) {
                if (
                    $edit -isnot [System.Collections.IDictionary] -or
                    -not (Test-AiSopMapAllowedTypes $edit @(
                        "file_path",
                        "path",
                        "file",
                        "target_file",
                        "filePath",
                        "old_string",
                        "new_string",
                        "old_str",
                        "new_str",
                        "oldText",
                        "newText",
                        "replace_all"
                    ))
                ) {
                    return $false
                }
                $itemPaths = Get-AiSopPathFieldValues $edit
                if (
                    $null -eq $itemPaths -or
                    @($itemPaths).Count -gt 1 -or
                    (
                        @($topPaths).Count -eq 0 -and
                        @($itemPaths).Count -ne 1
                    )
                ) {
                    return $false
                }
                $oldFields = @(
                    @("old_string", "old_str", "oldText") |
                        Where-Object { Test-MapHasKey $edit $_ }
                )
                $newFields = @(
                    @("new_string", "new_str", "newText") |
                        Where-Object { Test-MapHasKey $edit $_ }
                )
                if (
                    $oldFields.Count -ne 1 -or
                    $newFields.Count -ne 1 -or
                    -not (Test-StringValue $edit[$oldFields[0]] -AllowEmpty) -or
                    -not (Test-StringValue $edit[$newFields[0]] -AllowEmpty) -or
                    (
                        (Test-MapHasKey $edit "replace_all") -and
                        $edit.replace_all -isnot [bool]
                    )
                ) {
                    return $false
                }
            }
            return $true
        }
        "NOTEBOOK_EDIT" {
            if (-not (Test-AiSopMapAllowedTypes $Arguments @(
                "target_notebook",
                "notebook_path",
                "path",
                "file_path",
                "cell_idx",
                "is_new_cell",
                "cell_language",
                "old_string",
                "new_string"
            ))) {
                return $false
            }
            $paths = Get-AiSopPathFieldValues $Arguments
            if (-not (
                $null -ne $paths -and
                @($paths).Count -eq 1 -and
                (Test-MapHasKey $Arguments "cell_idx") -and
                (Test-IntegerValue $Arguments.cell_idx) -and
                (
                    -not (Test-MapHasKey $Arguments "is_new_cell") -or
                    $Arguments.is_new_cell -is [bool]
                ) -and
                (Test-MapHasKey $Arguments "new_string")
            )) {
                return $false
            }
            foreach ($field in @(
                "cell_language",
                "old_string",
                "new_string"
            )) {
                if (
                    (Test-MapHasKey $Arguments $field) -and
                    -not (Test-StringValue $Arguments[$field] -AllowEmpty)
                ) {
                    return $false
                }
            }
            return $true
        }
        "CURSOR_EDIT_NOTEBOOK" {
            $required = @(
                "target_notebook",
                "cell_idx",
                "is_new_cell",
                "cell_language",
                "old_string",
                "new_string"
            )
            if (-not (Test-AiSopMapAllowedTypes $Arguments $required)) {
                return $false
            }
            foreach ($field in $required) {
                if (-not (Test-MapHasKey $Arguments $field)) {
                    return $false
                }
            }
            if (
                -not (Test-StringValue $Arguments.target_notebook) -or
                -not (Test-IntegerValue $Arguments.cell_idx) -or
                [int64]$Arguments.cell_idx -lt 0 -or
                $Arguments.is_new_cell -isnot [bool] -or
                [string]$Arguments.cell_language -notin @(
                    "python",
                    "markdown",
                    "javascript",
                    "typescript",
                    "r",
                    "sql",
                    "shell",
                    "raw",
                    "other"
                ) -or
                -not (Test-StringValue $Arguments.old_string -AllowEmpty) -or
                -not (Test-StringValue $Arguments.new_string -AllowEmpty)
            ) {
                return $false
            }
            if (
                $Arguments.is_new_cell -and
                -not [string]::IsNullOrEmpty([string]$Arguments.old_string)
            ) {
                return $false
            }
            if (
                -not $Arguments.is_new_cell -and
                [string]::IsNullOrEmpty([string]$Arguments.old_string)
            ) {
                return $false
            }
            return $true
        }
        "APPLY_PATCH" {
            if (-not (Test-AiSopMapAllowedTypes $Arguments @("patch", "input"))) {
                return $false
            }
            $fields = @(
                @("patch", "input") |
                    Where-Object { Test-MapHasKey $Arguments $_ }
            )
            return (
                $fields.Count -eq 1 -and
                (Test-StringValue $Arguments[$fields[0]])
            )
        }
        "DELETE" {
            if (-not (Test-AiSopMapAllowedTypes $Arguments @(
                "file_path",
                "path",
                "file",
                "target_file",
                "filePath",
                "paths",
                "files",
                "targets"
            ))) {
                return $false
            }
            $presentPathFields = @(
                @(
                    "file_path",
                    "path",
                    "file",
                    "target_file",
                    "filePath",
                    "paths",
                    "files",
                    "targets"
                ) | Where-Object { Test-MapHasKey $Arguments $_ }
            )
            if ($presentPathFields.Count -ne 1) {
                return $false
            }
            $paths = Get-AiSopPathFieldValues $Arguments -IncludePlural
            return $null -ne $paths -and @($paths).Count -gt 0
        }
        "STR_REPLACE_EDITOR" {
            if (-not (Test-AiSopMapAllowedTypes $Arguments @(
                "command",
                "path",
                "file_path",
                "old_str",
                "new_str",
                "old_string",
                "new_string",
                "file_text",
                "insert_line",
                "view_range"
            ))) {
                return $false
            }
            $paths = Get-AiSopPathFieldValues $Arguments
            if (-not (
                $null -ne $paths -and
                @($paths).Count -eq 1 -and
                (Test-MapHasKey $Arguments "command") -and
                $Arguments.command -in @("create", "str_replace", "insert", "undo_edit")
            )) {
                return $false
            }
            if ($Arguments.command -eq "str_replace") {
                $oldFields = @(
                    @("old_str", "old_string") |
                        Where-Object { Test-MapHasKey $Arguments $_ }
                )
                $newFields = @(
                    @("new_str", "new_string") |
                        Where-Object { Test-MapHasKey $Arguments $_ }
                )
                return (
                    $oldFields.Count -eq 1 -and
                    $newFields.Count -eq 1 -and
                    (Test-StringValue $Arguments[$oldFields[0]] -AllowEmpty) -and
                    (Test-StringValue $Arguments[$newFields[0]] -AllowEmpty) -and
                    -not (Test-MapHasKey $Arguments "file_text") -and
                    -not (Test-MapHasKey $Arguments "insert_line") -and
                    -not (Test-MapHasKey $Arguments "view_range")
                )
            }
            if ($Arguments.command -eq "create") {
                return (
                    (Test-MapHasKey $Arguments "file_text") -and
                    (Test-StringValue $Arguments.file_text -AllowEmpty) -and
                    @(
                        "old_str",
                        "new_str",
                        "old_string",
                        "new_string",
                        "insert_line",
                        "view_range"
                    ).Where({ Test-MapHasKey $Arguments $_ }).Count -eq 0
                )
            }
            if ($Arguments.command -eq "insert") {
                $newFields = @(
                    @("new_str", "new_string") |
                        Where-Object { Test-MapHasKey $Arguments $_ }
                )
                return (
                    $newFields.Count -eq 1 -and
                    (Test-StringValue $Arguments[$newFields[0]] -AllowEmpty) -and
                    (Test-MapHasKey $Arguments "insert_line") -and
                    (Test-IntegerValue $Arguments.insert_line) -and
                    @(
                        "old_str",
                        "old_string",
                        "file_text",
                        "view_range"
                    ).Where({ Test-MapHasKey $Arguments $_ }).Count -eq 0
                )
            }
            return @(
                "old_str",
                "new_str",
                "old_string",
                "new_string",
                "file_text",
                "insert_line",
                "view_range"
            ).Where({ Test-MapHasKey $Arguments $_ }).Count -eq 0
        }
        "MULTI_REPLACE" {
            if (-not (Test-AiSopMapAllowedTypes $Arguments @(
                "replacements",
                "edits"
            ))) {
                return $false
            }
            $collectionField = if (Test-MapHasKey $Arguments "replacements") {
                "replacements"
            } elseif (Test-MapHasKey $Arguments "edits") {
                "edits"
            } else {
                ""
            }
            if (
                @(
                    @("replacements", "edits") |
                        Where-Object { Test-MapHasKey $Arguments $_ }
                ).Count -ne 1 -or
                -not $collectionField -or
                -not (Test-ArrayValue $Arguments[$collectionField]) -or
                @($Arguments[$collectionField]).Count -eq 0
            ) {
                return $false
            }
            foreach ($replacement in @($Arguments[$collectionField])) {
                if (
                    $replacement -isnot [System.Collections.IDictionary] -or
                    -not (Test-AiSopMapAllowedTypes $replacement @(
                        "file_path",
                        "path",
                        "file",
                        "target_file",
                        "filePath",
                        "old_string",
                        "new_string",
                        "old_str",
                        "new_str"
                    ))
                ) {
                    return $false
                }
                $paths = Get-AiSopPathFieldValues $replacement
                if ($null -eq $paths -or @($paths).Count -ne 1) {
                    return $false
                }
                $oldFields = @(
                    @("old_string", "old_str") |
                        Where-Object { Test-MapHasKey $replacement $_ }
                )
                $newFields = @(
                    @("new_string", "new_str") |
                        Where-Object { Test-MapHasKey $replacement $_ }
                )
                if (
                    $oldFields.Count -ne 1 -or
                    $newFields.Count -ne 1 -or
                    -not (Test-StringValue $replacement[$oldFields[0]] -AllowEmpty) -or
                    -not (Test-StringValue $replacement[$newFields[0]] -AllowEmpty)
                ) {
                    return $false
                }
            }
            return $true
        }
        default {
            return $false
        }
    }
}

function Get-AiSopToolPayload {
    param(
        [System.Collections.IDictionary]$Payload,
        [string]$NativeShape
    )

    if ($NativeShape -in @(
        "CLAUDE_PRE_TOOL_USE",
        "COPILOT_CLAUDE_COMPAT",
        "CURSOR_PRE_TOOL_USE"
    )) {
        return [pscustomobject]@{
            ToolName = [string]$Payload.tool_name
            Arguments = $Payload.tool_input
        }
    }
    if ($NativeShape -eq "COPILOT_GITHUB_NATIVE") {
        $arguments = $Payload.toolArgs
        if ($arguments -is [string]) {
            try {
                $arguments = $arguments |
                    ConvertFrom-Json -AsHashtable -Depth 100
            } catch {
                Throw-AiSopHookError "TOOL_ARGS_INVALID"
            }
        }
        if ($arguments -isnot [System.Collections.IDictionary]) {
            Throw-AiSopHookError "TOOL_ARGS_INVALID"
        }
        return [pscustomobject]@{
            ToolName = [string]$Payload.toolName
            Arguments = $arguments
        }
    }
    if ($NativeShape -eq "ANTIGRAVITY") {
        return [pscustomobject]@{
            ToolName = [string]$Payload.toolCall.name
            Arguments = $Payload.toolCall.args
        }
    }
    Throw-AiSopHookError "TOOL_ARGS_INVALID"
}

function Get-AiSopToolPolicy {
    param([string]$PolicyPath)

    if (
        -not (Test-Path -LiteralPath $PolicyPath -PathType Leaf) -or
        -not (Test-Path -LiteralPath $script:HookToolPolicySchemaPath -PathType Leaf)
    ) {
        Throw-AiSopHookError "TOOL_UNKNOWN"
    }
    try {
        $canonicalPath = [System.IO.Path]::GetFullPath($PolicyPath)
        $rawPolicy = [System.IO.File]::ReadAllText($canonicalPath)
        $fileInfo = [System.IO.FileInfo]::new($canonicalPath)
        $contentSha256 = Get-AiSopSha256Hex $rawPolicy
        $cacheKey = $canonicalPath.ToLowerInvariant()
        [System.Threading.Monitor]::Enter($script:HookToolPolicyCacheLock)
        try {
            if ($script:HookToolPolicyCache.ContainsKey($cacheKey)) {
                $cached = $script:HookToolPolicyCache[$cacheKey]
                if (
                    $cached.LastWriteTimeUtcTicks -eq
                        $fileInfo.LastWriteTimeUtc.Ticks -and
                    $cached.ContentSha256 -eq $contentSha256
                ) {
                    return $cached.Policy
                }
            }
        } finally {
            [System.Threading.Monitor]::Exit($script:HookToolPolicyCacheLock)
        }
        if (-not ($rawPolicy | Test-Json -SchemaFile $script:HookToolPolicySchemaPath)) {
            Throw-AiSopHookError "TOOL_UNKNOWN"
        }
        $policy = $rawPolicy | ConvertFrom-Json -AsHashtable -Depth 100
        [System.Threading.Monitor]::Enter($script:HookToolPolicyCacheLock)
        try {
            $script:HookToolPolicyCache[$cacheKey] = [pscustomobject]@{
                LastWriteTimeUtcTicks = $fileInfo.LastWriteTimeUtc.Ticks
                ContentSha256 = $contentSha256
                Policy = $policy
            }
        } finally {
            [System.Threading.Monitor]::Exit($script:HookToolPolicyCacheLock)
        }
        return $policy
    } catch {
        if ($_.Exception.Message -eq "TOOL_UNKNOWN") {
            throw
        }
        Throw-AiSopHookError "TOOL_UNKNOWN"
    }
}

function Resolve-AiSopToolPolicy {
    param(
        [System.Collections.IDictionary]$Policy,
        [string]$NativeShape,
        [string]$ToolName,
        [System.Collections.IDictionary]$Arguments
    )

    $nameMatches = @(
        foreach ($entry in @($Policy.tools)) {
            if ($NativeShape -notin @($entry.nativeShapes)) {
                continue
            }
            $matches = if ($entry.match.kind -eq "EXACT") {
                $ToolName.Equals(
                    [string]$entry.match.value,
                    [System.StringComparison]::Ordinal
                )
            } else {
                $ToolName.StartsWith(
                    [string]$entry.match.value,
                    [System.StringComparison]::Ordinal
                )
            }
            if ($matches) {
                $entry
            }
        }
    )
    $validMatches = @(
        $nameMatches | Where-Object {
            Test-AiSopToolArgumentProfile `
                -Arguments $Arguments `
                -Profile ([string]$_.argumentProfile)
        }
    )
    if ($validMatches.Count -ne 1) {
        return [pscustomobject]@{
            CanonicalName = "UNKNOWN"
            ToolClass = [string]$Policy.unknownClass
            ArgumentProfile = "ANY_OBJECT"
            TargetExtractor = "NONE"
        }
    }
    $entry = $validMatches[0]
    return [pscustomobject]@{
        CanonicalName = [string]$entry.canonicalName
        ToolClass = [string]$entry.toolClass
        ArgumentProfile = [string]$entry.argumentProfile
        TargetExtractor = [string]$entry.targetExtractor
    }
}

function Get-AiSopRawEditTargets {
    param(
        [System.Collections.IDictionary]$Arguments,
        [string]$TargetExtractor
    )

    switch ($TargetExtractor) {
        "SINGLE_PATH" {
            $paths = Get-AiSopPathFieldValues $Arguments
            if ($null -eq $paths -or @($paths).Count -eq 0) {
                Throw-AiSopHookError "EDIT_PATH_MISSING"
            }
            if (@($paths).Count -ne 1) {
                Throw-AiSopHookError "EDIT_PATH_AMBIGUOUS"
            }
            return @($paths)
        }
        "MULTI_EDIT" {
            $paths = @()
            $topPaths = Get-AiSopPathFieldValues $Arguments
            if ($null -eq $topPaths) {
                Throw-AiSopHookError "EDIT_PATH_AMBIGUOUS"
            }
            $paths += @($topPaths)
            foreach ($edit in @($Arguments.edits)) {
                $itemPaths = Get-AiSopPathFieldValues $edit
                if ($null -eq $itemPaths) {
                    Throw-AiSopHookError "EDIT_PATH_AMBIGUOUS"
                }
                if (@($topPaths).Count -eq 0 -and @($itemPaths).Count -eq 0) {
                    Throw-AiSopHookError "EDIT_PATH_MISSING"
                }
                $paths += @($itemPaths)
            }
            if ($paths.Count -eq 0) {
                Throw-AiSopHookError "EDIT_PATH_MISSING"
            }
            return @($paths)
        }
        "APPLY_PATCH" {
            $patchField = @("patch", "input") |
                Where-Object { Test-MapHasKey $Arguments $_ } |
                Select-Object -First 1
            $patch = [string]$Arguments[$patchField]
            $lines = @($patch -split "`r?`n")
            $lastContentIndex = $lines.Count - 1
            while (
                $lastContentIndex -ge 0 -and
                [string]::IsNullOrWhiteSpace($lines[$lastContentIndex])
            ) {
                $lastContentIndex--
            }
            if (
                $lines.Count -lt 2 -or
                $lines[0] -ne "*** Begin Patch" -or
                $lastContentIndex -lt 1 -or
                $lines[$lastContentIndex] -ne "*** End Patch" -or
                @($lines | Where-Object { $_ -eq "*** Begin Patch" }).Count -ne 1 -or
                @($lines | Where-Object { $_ -eq "*** End Patch" }).Count -ne 1
            ) {
                Throw-AiSopHookError "EDIT_PATH_AMBIGUOUS"
            }
            $paths = @()
            foreach ($line in $lines) {
                if ($line -match "^\*\*\* (?:Add|Update|Delete) File: (.+)$") {
                    if ([string]::IsNullOrWhiteSpace($Matches[1])) {
                        Throw-AiSopHookError "EDIT_PATH_MISSING"
                    }
                    $paths += $Matches[1]
                } elseif (
                    $line.StartsWith(
                        "*** ",
                        [System.StringComparison]::Ordinal
                    ) -and
                    $line -notin @(
                        "*** Begin Patch",
                        "*** End Patch",
                        "*** End of File"
                    )
                ) {
                    Throw-AiSopHookError "EDIT_PATH_AMBIGUOUS"
                }
            }
            if ($paths.Count -eq 0) {
                Throw-AiSopHookError "EDIT_PATH_MISSING"
            }
            return @($paths)
        }
        "DELETE" {
            $paths = Get-AiSopPathFieldValues $Arguments -IncludePlural
            if ($null -eq $paths) {
                Throw-AiSopHookError "EDIT_PATH_AMBIGUOUS"
            }
            if (@($paths).Count -eq 0) {
                Throw-AiSopHookError "EDIT_PATH_MISSING"
            }
            return @($paths)
        }
        "STR_REPLACE_EDITOR" {
            $paths = Get-AiSopPathFieldValues $Arguments
            if ($null -eq $paths -or @($paths).Count -eq 0) {
                Throw-AiSopHookError "EDIT_PATH_MISSING"
            }
            if (@($paths).Count -ne 1) {
                Throw-AiSopHookError "EDIT_PATH_AMBIGUOUS"
            }
            return @($paths)
        }
        "MULTI_REPLACE" {
            $field = if (Test-MapHasKey $Arguments "replacements") {
                "replacements"
            } else {
                "edits"
            }
            $paths = @()
            foreach ($replacement in @($Arguments[$field])) {
                $itemPaths = Get-AiSopPathFieldValues $replacement
                if ($null -eq $itemPaths -or @($itemPaths).Count -ne 1) {
                    Throw-AiSopHookError "EDIT_PATH_AMBIGUOUS"
                }
                $paths += @($itemPaths)
            }
            if ($paths.Count -eq 0) {
                Throw-AiSopHookError "EDIT_PATH_MISSING"
            }
            return @($paths)
        }
        default {
            return @()
        }
    }
}

function Resolve-AiSopEditTargets {
    param(
        [System.Collections.IDictionary]$Arguments,
        [string]$TargetExtractor,
        [object]$WorkspaceContext
    )

    $rawTargets = Get-AiSopRawEditTargets `
        -Arguments $Arguments -TargetExtractor $TargetExtractor
    $lexicalTargets = @()
    $physicalTargets = @()
    foreach ($rawTarget in $rawTargets) {
        $identity = Resolve-AiSopWorkspacePathIdentity `
            -Path ([string]$rawTarget) `
            -WorkspaceRoot $WorkspaceContext.WorkspacePath `
            -BasePath $WorkspaceContext.Cwd
        $lexicalTargets += $identity.Lexical
        $physicalTargets += $identity.Physical
    }
    $uniquePhysicalTargets = ConvertTo-AiSopUniquePathList $physicalTargets
    return [pscustomobject]@{
        Lexical = (ConvertTo-AiSopUniquePathList $lexicalTargets)
        Physical = $uniquePhysicalTargets
        HasDuplicatePhysical = (
            @($physicalTargets).Count -ne @($uniquePhysicalTargets).Count
        )
    }
}

function Get-AiSopCanonicalPath {
    param(
        [System.Collections.IDictionary]$Arguments,
        [object]$WorkspaceContext
    )

    $paths = Get-AiSopPathFieldValues $Arguments
    if ($null -eq $paths -or @($paths).Count -ne 1) {
        return ""
    }
    $path = Resolve-AiSopWorkspacePath `
        -Path ([string]$paths[0]) `
        -WorkspaceRoot $WorkspaceContext.WorkspacePath `
        -BasePath $WorkspaceContext.Cwd
    return $path.ToLowerInvariant()
}

function Get-AiSopAliasedValue {
    param(
        [System.Collections.IDictionary]$Arguments,
        [string[]]$Fields
    )

    foreach ($field in $Fields) {
        if (Test-MapHasKey $Arguments $field) {
            return $Arguments[$field]
        }
    }
    return $null
}

function Get-AiSopCanonicalArgumentPath {
    param(
        [System.Collections.IDictionary]$Arguments,
        [object]$WorkspaceContext,
        [AllowEmptyString()]
        [string]$FallbackPath = ""
    )

    $paths = Get-AiSopPathFieldValues $Arguments
    if ($null -eq $paths -or @($paths).Count -gt 1) {
        Throw-AiSopHookError "EDIT_PATH_AMBIGUOUS"
    }
    if (@($paths).Count -eq 0) {
        return $FallbackPath
    }
    return (
        Resolve-AiSopWorkspacePath `
            -Path ([string]@($paths)[0]) `
            -WorkspaceRoot $WorkspaceContext.WorkspacePath `
            -BasePath $WorkspaceContext.Cwd
    ).ToLowerInvariant()
}

function Get-AiSopCanonicalToolArguments {
    param(
        [System.Collections.IDictionary]$Arguments,
        [object]$PolicyEntry,
        [object]$WorkspaceContext,
        [string[]]$TargetPaths
    )

    switch ($PolicyEntry.ArgumentProfile) {
        "READ" {
            return [ordered]@{
                path = Get-AiSopCanonicalPath $Arguments $WorkspaceContext
                offset = if (Test-MapHasKey $Arguments "offset") {
                    $Arguments.offset
                } else { 0 }
                limit = Get-AiSopAliasedValue $Arguments @("limit")
                lineStart = Get-AiSopAliasedValue $Arguments @("line_start")
                lineEnd = Get-AiSopAliasedValue $Arguments @("line_end")
            }
        }
        "GLOB" {
            $pathFields = @(
                @("path", "target_directory") |
                    Where-Object { Test-MapHasKey $Arguments $_ }
            )
            if ($pathFields.Count -gt 1) {
                Throw-AiSopHookError "TOOL_ARGS_INVALID"
            }
            $rawPath = if ($pathFields.Count -eq 1) {
                $Arguments[$pathFields[0]]
            } else {
                $null
            }
            $canonicalPath = if (Test-StringValue $rawPath) {
                (
                    Resolve-AiSopWorkspacePath `
                        -Path $rawPath `
                        -WorkspaceRoot $WorkspaceContext.WorkspacePath `
                        -BasePath $WorkspaceContext.Cwd
                ).ToLowerInvariant()
            } else {
                $null
            }
            return [ordered]@{
                pattern = Get-AiSopAliasedValue $Arguments @("pattern", "glob_pattern")
                path = $canonicalPath
                include = Get-AiSopAliasedValue $Arguments @("include")
                exclude = Get-AiSopAliasedValue $Arguments @("exclude")
            }
        }
        "SEARCH" {
            $rawPath = Get-AiSopAliasedValue $Arguments @("path")
            $canonicalPath = if (Test-StringValue $rawPath) {
                (
                    Resolve-AiSopWorkspacePath `
                        -Path $rawPath `
                        -WorkspaceRoot $WorkspaceContext.WorkspacePath `
                        -BasePath $WorkspaceContext.Cwd
                ).ToLowerInvariant()
            } else {
                $null
            }
            return [ordered]@{
                pattern = Get-AiSopAliasedValue $Arguments @(
                    "pattern",
                    "query",
                    "search_term"
                )
                path = $canonicalPath
                glob = Get-AiSopAliasedValue $Arguments @("glob")
                type = Get-AiSopAliasedValue $Arguments @("type")
                outputMode = if (Test-MapHasKey $Arguments "output_mode") {
                    $Arguments.output_mode
                } else { "content" }
                before = if (Test-MapHasKey $Arguments "-B") {
                    $Arguments["-B"]
                } else { 0 }
                after = if (Test-MapHasKey $Arguments "-A") {
                    $Arguments["-A"]
                } else { 0 }
                context = if (Test-MapHasKey $Arguments "-C") {
                    $Arguments["-C"]
                } else { 0 }
                ignoreCase = if (Test-MapHasKey $Arguments "-i") {
                    [bool]$Arguments["-i"]
                } else { $false }
                headLimit = Get-AiSopAliasedValue $Arguments @("head_limit")
                offset = if (Test-MapHasKey $Arguments "offset") {
                    $Arguments.offset
                } else { 0 }
                multiline = if (Test-MapHasKey $Arguments "multiline") {
                    [bool]$Arguments.multiline
                } else { $false }
            }
        }
        "EDIT" {
            return [ordered]@{
                paths = @($TargetPaths | ForEach-Object { $_.ToLowerInvariant() })
                old = Get-AiSopAliasedValue $Arguments @(
                    "old_string",
                    "old_str",
                    "oldText",
                    "old_text",
                    "TargetContent",
                    "targetContent"
                )
                new = Get-AiSopAliasedValue $Arguments @(
                    "new_string",
                    "new_str",
                    "newText",
                    "new_text",
                    "ReplacementContent",
                    "replacementContent"
                )
                replaceAll = if (Test-MapHasKey $Arguments "replace_all") {
                    [bool]$Arguments.replace_all
                } elseif (Test-MapHasKey $Arguments "AllowMultiple") {
                    [bool]$Arguments.AllowMultiple
                } elseif (Test-MapHasKey $Arguments "allowMultiple") {
                    [bool]$Arguments.allowMultiple
                } else {
                    $false
                }
            }
        }
        "WRITE" {
            return [ordered]@{
                paths = @($TargetPaths | ForEach-Object { $_.ToLowerInvariant() })
                content = Get-AiSopAliasedValue $Arguments @(
                    "content",
                    "contents",
                    "CodeContent",
                    "codeContent"
                )
            }
        }
        "MULTI_EDIT" {
            $topPath = Get-AiSopCanonicalArgumentPath `
                -Arguments $Arguments `
                -WorkspaceContext $WorkspaceContext
            $edits = @(
                foreach ($edit in @($Arguments.edits)) {
                    [ordered]@{
                        path = Get-AiSopCanonicalArgumentPath `
                            -Arguments $edit `
                            -WorkspaceContext $WorkspaceContext `
                            -FallbackPath $topPath
                        old = Get-AiSopAliasedValue $edit @(
                            "old_string",
                            "old_str",
                            "oldText"
                        )
                        new = Get-AiSopAliasedValue $edit @(
                            "new_string",
                            "new_str",
                            "newText"
                        )
                        replaceAll = if (Test-MapHasKey $edit "replace_all") {
                            [bool]$edit.replace_all
                        } else {
                            $false
                        }
                    }
                }
            )
            return [ordered]@{ edits = $edits }
        }
        { $_ -in @("NOTEBOOK_EDIT", "CURSOR_EDIT_NOTEBOOK") } {
            return [ordered]@{
                path = Get-AiSopCanonicalArgumentPath `
                    -Arguments $Arguments `
                    -WorkspaceContext $WorkspaceContext
                cellIndex = $Arguments.cell_idx
                isNewCell = if (Test-MapHasKey $Arguments "is_new_cell") {
                    [bool]$Arguments.is_new_cell
                } else { $false }
                language = if (Test-MapHasKey $Arguments "cell_language") {
                    [string]$Arguments.cell_language
                } else { "" }
                old = if (Test-MapHasKey $Arguments "old_string") {
                    [string]$Arguments.old_string
                } else { "" }
                new = $Arguments.new_string
            }
        }
        "APPLY_PATCH" {
            $patch = [string](Get-AiSopAliasedValue $Arguments @("patch", "input"))
            $sections = @()
            $current = $null
            $ended = $false
            foreach ($line in @($patch -split "`r?`n")) {
                if ($ended) {
                    if (-not [string]::IsNullOrWhiteSpace($line)) {
                        Throw-AiSopHookError "TOOL_ARGS_INVALID"
                    }
                    continue
                }
                if ($line -eq "*** End Patch") {
                    if ($null -ne $current) {
                        $sections += $current
                        $current = $null
                    }
                    $ended = $true
                    continue
                }
                if ($line -match "^\*\*\* (Add|Update|Delete) File: (.+)$") {
                    if ($null -ne $current) {
                        $sections += $current
                    }
                    $physicalPath = (
                        Resolve-AiSopWorkspacePath `
                            -Path ([string]$Matches[2]) `
                            -WorkspaceRoot $WorkspaceContext.WorkspacePath `
                            -BasePath $WorkspaceContext.Cwd
                    ).ToLowerInvariant()
                    $current = [ordered]@{
                        operation = $Matches[1].ToUpperInvariant()
                        path = $physicalPath
                        body = @()
                    }
                } elseif (
                    $null -ne $current -and
                    $line -ne "*** Begin Patch"
                ) {
                    $current.body += $line
                }
            }
            if ($null -ne $current) {
                $sections += $current
            }
            $canonicalSections = @(
                $sections |
                    Sort-Object {
                        ConvertTo-AiSopCanonicalJson -Value $_
                    }
            )
            return [ordered]@{
                sections = $canonicalSections
            }
        }
        "DELETE" {
            return [ordered]@{
                paths = @(
                    $TargetPaths |
                        ForEach-Object { $_.ToLowerInvariant() } |
                        Sort-Object -Unique
                )
            }
        }
        "STR_REPLACE_EDITOR" {
            $result = [ordered]@{
                command = $Arguments.command
                path = Get-AiSopCanonicalArgumentPath `
                    -Arguments $Arguments `
                    -WorkspaceContext $WorkspaceContext
            }
            foreach ($semanticField in @(
                @("fileText", @("file_text")),
                @("old", @("old_str", "old_string")),
                @("new", @("new_str", "new_string")),
                @("insertLine", @("insert_line")),
                @("viewRange", @("view_range"))
            )) {
                $value = Get-AiSopAliasedValue $Arguments $semanticField[1]
                if ($null -ne $value) {
                    $result[$semanticField[0]] = $value
                }
            }
            return $result
        }
        "MULTI_REPLACE" {
            $collection = Get-AiSopAliasedValue $Arguments @(
                "replacements",
                "edits"
            )
            return [ordered]@{
                replacements = @(
                    foreach ($replacement in @($collection)) {
                        [ordered]@{
                            path = Get-AiSopCanonicalArgumentPath `
                                -Arguments $replacement `
                                -WorkspaceContext $WorkspaceContext
                            old = Get-AiSopAliasedValue $replacement @(
                                "old_string",
                                "old_str"
                            )
                            new = Get-AiSopAliasedValue $replacement @(
                                "new_string",
                                "new_str"
                            )
                        }
                    }
                )
            }
        }
        default {
            $canonical = [ordered]@{
                values = ConvertTo-AiSopCanonicalNode $Arguments
            }
            if ($TargetPaths.Count -gt 0) {
                $canonical.paths = @(
                    $TargetPaths | ForEach-Object { $_.ToLowerInvariant() }
                )
            }
            return $canonical
        }
    }
}

function Get-AiSopNativeSessionId {
    param(
        [System.Collections.IDictionary]$Payload,
        [string]$NativeShape
    )

    if ($NativeShape -in @(
        "CLAUDE_SESSION_START",
        "CLAUDE_SESSION_END",
        "CLAUDE_PRE_TOOL_USE",
        "COPILOT_CLAUDE_COMPAT",
        "CURSOR_SESSION_START",
        "CURSOR_SESSION_END"
    )) {
        return [string]$Payload.session_id
    }
    if ($NativeShape -eq "COPILOT_GITHUB_NATIVE") {
        return [string]$Payload.sessionId
    }
    if ($NativeShape -eq "CURSOR_PRE_TOOL_USE") {
        return [string]$Payload.conversation_id
    }
    if ($NativeShape -eq "ANTIGRAVITY") {
        return [string]$Payload.conversationId
    }
    Throw-AiSopHookError "PAYLOAD_SHAPE_INVALID"
}

function Get-AiSopLifecycleSemanticArguments {
    param(
        [System.Collections.IDictionary]$Payload,
        [string]$EventHint
    )

    switch ($EventHint) {
        "SESSION_START" {
            return [ordered]@{
                source = Get-AiSopAliasedValue $Payload @("source")
                background = Get-AiSopAliasedValue $Payload @("is_background_agent")
                composerMode = Get-AiSopAliasedValue $Payload @("composer_mode")
            }
        }
        "SESSION_END" {
            return [ordered]@{
                reason = Get-AiSopAliasedValue $Payload @("reason")
                durationMs = Get-AiSopAliasedValue $Payload @("duration_ms")
                background = Get-AiSopAliasedValue $Payload @("is_background_agent")
                finalStatus = Get-AiSopAliasedValue $Payload @("final_status")
                errorMessage = Get-AiSopAliasedValue $Payload @("error_message")
            }
        }
        "STOP" {
            return [ordered]@{
                fullyIdle = Get-AiSopAliasedValue $Payload @("fullyIdle")
            }
        }
        default {
            return [ordered]@{}
        }
    }
}

function Get-AiSopCorrelationRoot {
    if (-not [string]::IsNullOrWhiteSpace($env:SERVER_NEW_HOOK_DEDUP_REGISTRY)) {
        return [System.IO.Path]::GetFullPath(
            $env:SERVER_NEW_HOOK_DEDUP_REGISTRY
        )
    }
    return Join-Path $env:LOCALAPPDATA "AIWorkflowHookDedup\server_new"
}

function Write-AiSopCorrelationRecord {
    param(
        [string]$RecordPath,
        [System.Collections.IDictionary]$Record
    )

    $temporaryPath = ""
    try {
        $json = $Record | ConvertTo-Json -Compress
        if (-not ($json | Test-Json -Schema $script:HookCorrelationSchema)) {
            Throw-AiSopHookError "REGISTRY_CORRUPT"
        }
        $temporaryPath = "$RecordPath.$([guid]::NewGuid().ToString('N')).tmp"
        [System.IO.File]::WriteAllText(
            $temporaryPath,
            $json,
            [System.Text.UTF8Encoding]::new($false)
        )
        [System.IO.File]::Move($temporaryPath, $RecordPath, $true)
    } catch {
        if ($_.Exception.Message -eq "REGISTRY_CORRUPT") {
            throw
        }
        Throw-AiSopHookError "REGISTRY_IO_ERROR"
    } finally {
        if (-not [string]::IsNullOrEmpty($temporaryPath)) {
            try {
                if ([System.IO.File]::Exists($temporaryPath)) {
                    [System.IO.File]::Delete($temporaryPath)
                }
            } catch {
                # Expired temp files are handled by bounded lazy cleanup.
            }
        }
    }
}

function Assert-AiSopRegistryDeadline {
    param([Nullable[DateTimeOffset]]$DeadlineUtc)

    if (
        $null -ne $DeadlineUtc -and
        [DateTimeOffset]::UtcNow -ge ([DateTimeOffset]$DeadlineUtc)
    ) {
        Throw-AiSopHookError "REGISTRY_DEADLINE_EXCEEDED"
    }
}

function ConvertFrom-AiSopHookRegistryRecord {
    param(
        [string]$RecordPath,
        [string]$Directory,
        [ValidateSet("CORRELATION", "DEDUP")]
        [string]$RecordKind
    )

    try {
        $rawRecord = [System.IO.File]::ReadAllText($RecordPath)
        $schemaValid = if ($RecordKind -eq "CORRELATION") {
            $rawRecord | Test-Json -Schema $script:HookCorrelationSchema
        } else {
            $rawRecord | Test-Json -SchemaFile $script:HookDedupSchemaPath
        }
        if (-not $schemaValid) {
            Throw-AiSopHookError "REGISTRY_CORRUPT"
        }
        $record = ConvertFrom-AiSopJson -Json $rawRecord
        $identityProperty = if ($RecordKind -eq "CORRELATION") {
            "correlationKey"
        } else {
            "dedupKey"
        }
        $expectedIdentity = [System.IO.Path]::GetFileNameWithoutExtension(
            $RecordPath
        )
        if ([string]$record[$identityProperty] -cne $expectedIdentity) {
            Throw-AiSopHookError "REGISTRY_CORRUPT"
        }
        if ($RecordKind -eq "DEDUP") {
            $expectedSessionKey = [System.IO.Path]::GetFileName(
                $Directory.TrimEnd(
                    [System.IO.Path]::DirectorySeparatorChar,
                    [System.IO.Path]::AltDirectorySeparatorChar
                )
            )
            if ([string]$record.sessionKey -cne $expectedSessionKey) {
                Throw-AiSopHookError "REGISTRY_CORRUPT"
            }
        }
        [void][DateTimeOffset]::Parse(
            [string]$record.expiresAt,
            [System.Globalization.CultureInfo]::InvariantCulture
        )
        return $record
    } catch {
        if ($_.Exception.Message -eq "REGISTRY_CORRUPT") {
            throw
        }
        if (
            $_.Exception -is [System.IO.IOException] -or
            $_.Exception -is [System.UnauthorizedAccessException]
        ) {
            Throw-AiSopHookError "REGISTRY_IO_ERROR"
        }
        Throw-AiSopHookError "REGISTRY_CORRUPT"
    }
}

function Invoke-AiSopHookRegistryScavenge {
    param(
        [string]$Directory,
        [DateTimeOffset]$NowUtc = [DateTimeOffset]::UtcNow,
        [Nullable[DateTimeOffset]]$DeadlineUtc,
        [int]$MaximumRecords = 32,
        [ValidateSet("CORRELATION", "DEDUP")]
        [string]$RecordKind = "CORRELATION"
    )

    Assert-AiSopRegistryDeadline $DeadlineUtc
    try {
        if (-not [System.IO.Directory]::Exists($Directory)) {
            return
        }
        Assert-AiSopRegistryDeadline $DeadlineUtc
        $records = @(
            [System.IO.Directory]::EnumerateFiles($Directory, "*.json") |
                Select-Object -First $MaximumRecords
        )
    } catch {
        if ($_.Exception.Message -eq "REGISTRY_DEADLINE_EXCEEDED") {
            throw
        }
        Throw-AiSopHookError "REGISTRY_IO_ERROR"
    }
    foreach ($recordPath in $records) {
        Assert-AiSopRegistryDeadline $DeadlineUtc
        $lockPath = [System.IO.Path]::ChangeExtension($recordPath, ".lock")
        $probe = $null
        try {
            Assert-AiSopRegistryDeadline $DeadlineUtc
            $probe = [System.IO.File]::Open(
                $lockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
        } catch [System.IO.IOException] {
            continue
        } catch {
            if ($_.Exception.Message -eq "REGISTRY_DEADLINE_EXCEEDED") {
                throw
            }
            Throw-AiSopHookError "REGISTRY_IO_ERROR"
        }
        $recordDeleted = $false
        try {
            Assert-AiSopRegistryDeadline $DeadlineUtc
            if (-not [System.IO.File]::Exists($recordPath)) {
                continue
            }
            $record = ConvertFrom-AiSopHookRegistryRecord `
                -RecordPath $recordPath `
                -Directory $Directory `
                -RecordKind $RecordKind
            $expiresAt = [DateTimeOffset]::Parse(
                [string]$record.expiresAt,
                [System.Globalization.CultureInfo]::InvariantCulture
            )
            if ($expiresAt -gt $NowUtc) {
                continue
            }
            Assert-AiSopRegistryDeadline $DeadlineUtc
            [System.IO.File]::Delete($recordPath)
            $recordDeleted = $true
        } catch {
            if ($_.Exception.Message -in @(
                "REGISTRY_CORRUPT",
                "REGISTRY_IO_ERROR",
                "REGISTRY_DEADLINE_EXCEEDED"
            )) {
                throw
            }
            Throw-AiSopHookError "REGISTRY_IO_ERROR"
        } finally {
            if ($null -ne $probe) {
                $probe.Dispose()
            }
        }
        if (-not $recordDeleted) {
            continue
        }
        try {
            Assert-AiSopRegistryDeadline $DeadlineUtc
            [System.IO.File]::Delete($lockPath)
        } catch [System.IO.IOException] {
            # Another process acquired the lock after the expired record left.
        } catch {
            if ($_.Exception.Message -eq "REGISTRY_DEADLINE_EXCEEDED") {
                throw
            }
            Throw-AiSopHookError "REGISTRY_IO_ERROR"
        }
    }
    try {
        Assert-AiSopRegistryDeadline $DeadlineUtc
        $locks = @(
            [System.IO.Directory]::EnumerateFiles($Directory, "*.lock") |
                Select-Object -First $MaximumRecords
        )
    } catch {
        if ($_.Exception.Message -eq "REGISTRY_DEADLINE_EXCEEDED") {
            throw
        }
        Throw-AiSopHookError "REGISTRY_IO_ERROR"
    }
    foreach ($lockPath in $locks) {
        Assert-AiSopRegistryDeadline $DeadlineUtc
        $recordPath = [System.IO.Path]::ChangeExtension($lockPath, ".json")
        try {
            Assert-AiSopRegistryDeadline $DeadlineUtc
            if (
                [System.IO.File]::Exists($recordPath) -or
                [System.IO.File]::GetLastWriteTimeUtc($lockPath) -gt
                    $NowUtc.AddMinutes(-5).UtcDateTime
            ) {
                continue
            }
        } catch {
            if ($_.Exception.Message -eq "REGISTRY_DEADLINE_EXCEEDED") {
                throw
            }
            Throw-AiSopHookError "REGISTRY_IO_ERROR"
        }
        $probe = $null
        try {
            Assert-AiSopRegistryDeadline $DeadlineUtc
            $probe = [System.IO.File]::Open(
                $lockPath,
                [System.IO.FileMode]::Open,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
        } catch [System.IO.IOException] {
            continue
        } catch {
            if ($_.Exception.Message -eq "REGISTRY_DEADLINE_EXCEEDED") {
                throw
            }
            Throw-AiSopHookError "REGISTRY_IO_ERROR"
        } finally {
            if ($null -ne $probe) {
                $probe.Dispose()
            }
        }
        try {
            Assert-AiSopRegistryDeadline $DeadlineUtc
            [System.IO.File]::Delete($lockPath)
        } catch [System.IO.IOException] {
            # A concurrent caller won the race; it owns the active lock now.
        } catch {
            if ($_.Exception.Message -eq "REGISTRY_DEADLINE_EXCEEDED") {
                throw
            }
            Throw-AiSopHookError "REGISTRY_IO_ERROR"
        }
    }
}

function Get-AiSopCorrelatedTimestamp {
    param(
        [string]$Agent,
        [string]$NativeSessionId,
        [string]$EventHint,
        [string]$WorkspacePath,
        [string]$SemanticArgsSha256,
        [string]$TargetsSha256,
        [string]$OccurrenceId,
        [DateTimeOffset]$AcceptedAt,
        [Nullable[DateTimeOffset]]$DeadlineUtc
    )

    $isTool = $EventHint -eq "PRE_TOOL_USE"
    if ($isTool -and [string]::IsNullOrWhiteSpace($OccurrenceId)) {
        return $AcceptedAt.ToUnixTimeMilliseconds()
    }
    $basis = if ($OccurrenceId) {
        [string]::Join(
            [char]0,
            @(
                "occurrence",
                $Agent,
                $NativeSessionId,
                $EventHint,
                $WorkspacePath,
                (Get-AiSopSha256Hex $OccurrenceId)
            )
        )
    } else {
        [string]::Join(
            [char]0,
            @(
                "lifecycle",
                $Agent,
                $NativeSessionId,
                $EventHint,
                $WorkspacePath,
                $SemanticArgsSha256,
                $TargetsSha256
            )
        )
    }
    $correlationKey = Get-AiSopSha256Hex $basis
    try {
        $correlationRoot = Join-Path (Get-AiSopCorrelationRoot) "correlations"
        [System.IO.Directory]::CreateDirectory($correlationRoot) | Out-Null
        $recordPath = Join-Path $correlationRoot "$correlationKey.json"
        $lockPath = Join-Path $correlationRoot "$correlationKey.lock"
    } catch {
        if ($_.Exception.Message -in @(
            "REGISTRY_IO_ERROR",
            "REGISTRY_CORRUPT",
            "REGISTRY_DEADLINE_EXCEEDED"
        )) {
            throw
        }
        Throw-AiSopHookError "REGISTRY_IO_ERROR"
    }
    $lock = $null
    $deadline = if ($null -ne $DeadlineUtc) {
        ([DateTimeOffset]$DeadlineUtc).ToUniversalTime()
    } else {
        [DateTimeOffset]::UtcNow.AddMilliseconds(250)
    }
    while ($null -eq $lock -and [DateTimeOffset]::UtcNow -lt $deadline) {
        try {
            $lock = [System.IO.File]::Open(
                $lockPath,
                [System.IO.FileMode]::OpenOrCreate,
                [System.IO.FileAccess]::ReadWrite,
                [System.IO.FileShare]::None
            )
        } catch [System.IO.IOException] {
            Start-Sleep -Milliseconds 10
        } catch {
            Throw-AiSopHookError "REGISTRY_IO_ERROR"
        }
    }
    if ($null -eq $lock) {
        Throw-AiSopHookError "REGISTRY_LOCK_TIMEOUT"
    }
    try {
        $currentTimestamp = $null
        if ([System.IO.File]::Exists($recordPath)) {
            try {
                $record = ConvertFrom-AiSopHookRegistryRecord `
                    -RecordPath $recordPath `
                    -Directory $correlationRoot `
                    -RecordKind "CORRELATION"
                $expiresAt = [DateTimeOffset]::Parse(
                    [string]$record.expiresAt,
                    [System.Globalization.CultureInfo]::InvariantCulture
                )
                if ($AcceptedAt -lt $expiresAt) {
                    $currentTimestamp = [int64]$record.normalizedTimestampEpochMs
                } else {
                    [System.IO.File]::Delete($recordPath)
                }
            } catch {
                if ($_.Exception.Message -in @(
                    "REGISTRY_CORRUPT",
                    "REGISTRY_IO_ERROR"
                )) {
                    throw
                }
                Throw-AiSopHookError "REGISTRY_CORRUPT"
            }
        }
        Invoke-AiSopHookRegistryScavenge `
            -Directory $correlationRoot `
            -NowUtc $AcceptedAt `
            -DeadlineUtc $DeadlineUtc `
            -RecordKind "CORRELATION"
        if ($null -ne $currentTimestamp) {
            return $currentTimestamp
        }
        $correlationExpiry = if ($OccurrenceId) {
            $AcceptedAt.AddHours(24)
        } else {
            $AcceptedAt.AddSeconds(5)
        }
        $record = [ordered]@{
            correlationKey = $correlationKey
            normalizedTimestampEpochMs = $AcceptedAt.ToUnixTimeMilliseconds()
            expiresAt = $correlationExpiry.ToUniversalTime().ToString("o")
        }
        Write-AiSopCorrelationRecord `
            -RecordPath $recordPath `
            -Record $record
        return [int64]$record.normalizedTimestampEpochMs
    } finally {
        $lock.Dispose()
    }
}

function Get-AiSopNormalizedTimestamp {
    param(
        [System.Collections.IDictionary]$Payload,
        [string]$NativeShape,
        [string]$Agent,
        [string]$NativeSessionId,
        [string]$EventHint,
        [string]$WorkspacePath,
        [string]$SemanticArgsSha256,
        [string]$TargetsSha256,
        [DateTimeOffset]$AcceptedAt,
        [Nullable[DateTimeOffset]]$DeadlineUtc
    )

    if ($NativeShape -eq "COPILOT_CLAUDE_COMPAT") {
        $parsed = [DateTimeOffset]::Parse(
            [string]$Payload.timestamp,
            [System.Globalization.CultureInfo]::InvariantCulture
        )
        $epoch = $parsed.ToUniversalTime().ToUnixTimeMilliseconds()
        if ([Math]::Abs($epoch - $AcceptedAt.ToUnixTimeMilliseconds()) -gt 300000) {
            Throw-AiSopHookError "PAYLOAD_SHAPE_INVALID"
        }
        return [pscustomobject]@{
            EpochMs = [int64]$epoch
            Source = "NATIVE"
        }
    }
    if ($NativeShape -eq "COPILOT_GITHUB_NATIVE") {
        $epoch = [int64]$Payload.timestamp
        if ([Math]::Abs($epoch - $AcceptedAt.ToUnixTimeMilliseconds()) -gt 300000) {
            Throw-AiSopHookError "PAYLOAD_SHAPE_INVALID"
        }
        return [pscustomobject]@{
            EpochMs = $epoch
            Source = "NATIVE"
        }
    }

    $occurrenceId = ""
    if (Test-MapHasKey $Payload "tool_use_id") {
        $occurrenceId = [string]$Payload.tool_use_id
    } elseif (Test-MapHasKey $Payload "generation_id") {
        $occurrenceId = [string]$Payload.generation_id
    }
    $epoch = Get-AiSopCorrelatedTimestamp `
        -Agent $Agent `
        -NativeSessionId $NativeSessionId `
        -EventHint $EventHint `
        -WorkspacePath $WorkspacePath `
        -SemanticArgsSha256 $SemanticArgsSha256 `
        -TargetsSha256 $TargetsSha256 `
        -OccurrenceId $occurrenceId `
        -AcceptedAt $AcceptedAt `
        -DeadlineUtc $DeadlineUtc
    return [pscustomobject]@{
        EpochMs = [int64]$epoch
        Source = "CORRELATED_ACCEPTED_AT"
    }
}

function Get-AiSopHookSessionKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$HookEvent
    )

    return Get-AiSopSha256Hex (
        [string]::Join(
            [char]0,
            @(
                [string]$HookEvent.agent,
                [string]$HookEvent.nativeSessionId,
                [string]$HookEvent.workspacePath
            )
        )
    )
}

function ConvertTo-AiSopHookEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$RawPayload,

        [Parameter(Mandatory)]
        [ValidateSet(
            "SESSION_START",
            "PRE_INVOCATION",
            "PRE_TOOL_USE",
            "SESSION_END",
            "STOP"
        )]
        [string]$EventHint,

        [Parameter(Mandatory)]
        [string]$TrustedWorkspaceRoot,

        [Parameter(Mandatory)]
        [DateTimeOffset]$AcceptedAt,

        [Nullable[DateTimeOffset]]$DeadlineUtc,

        [string]$ToolPolicyPath = $script:HookToolPolicyPath
    )

    try {
        $payload = ConvertFrom-AiSopJson -Json $RawPayload
    } catch {
        Throw-AiSopHookError "PAYLOAD_JSON_INVALID"
    }
    if ($payload -isnot [System.Collections.IDictionary]) {
        Throw-AiSopHookError "PAYLOAD_SHAPE_INVALID"
    }

    $shape = Resolve-AiSopNativeShape `
        -Payload $payload -EventHint $EventHint
    $workspace = Get-AiSopWorkspaceContext `
        -Payload $payload `
        -NativeShape $shape.NativeShape `
        -TrustedWorkspaceRoot $TrustedWorkspaceRoot
    $nativeSessionId = Get-AiSopNativeSessionId `
        -Payload $payload -NativeShape $shape.NativeShape
    $generationId = if (Test-MapHasKey $payload "generation_id") {
        [string]$payload.generation_id
    } else {
        ""
    }

    $toolName = ""
    $toolClass = "UNKNOWN"
    $targetPaths = @()
    $physicalTargetPaths = @()
    $canonicalName = "LIFECYCLE"
    $canonicalArguments = Get-AiSopLifecycleSemanticArguments `
        -Payload $payload -EventHint $EventHint

    if ($EventHint -eq "PRE_TOOL_USE") {
        $toolPayload = Get-AiSopToolPayload `
            -Payload $payload -NativeShape $shape.NativeShape
        $toolName = $toolPayload.ToolName
        $policy = Get-AiSopToolPolicy -PolicyPath $ToolPolicyPath
        $policyEntry = Resolve-AiSopToolPolicy `
            -Policy $policy `
            -NativeShape $shape.NativeShape `
            -ToolName $toolName `
            -Arguments $toolPayload.Arguments
        $toolClass = $policyEntry.ToolClass
        $canonicalName = $policyEntry.CanonicalName
        if ($toolClass -eq "FILE_EDIT") {
            $resolvedTargets = Resolve-AiSopEditTargets `
                -Arguments $toolPayload.Arguments `
                -TargetExtractor $policyEntry.TargetExtractor `
                -WorkspaceContext $workspace
            if (
                $policyEntry.ArgumentProfile -eq "APPLY_PATCH" -and
                $resolvedTargets.HasDuplicatePhysical
            ) {
                # Independent file sections may be reordered canonically, but
                # repeated physical targets are order-dependent patch programs.
                Throw-AiSopHookError "TOOL_ARGS_INVALID"
            }
            $targetPaths = @($resolvedTargets.Lexical)
            $physicalTargetPaths = @($resolvedTargets.Physical)
        }
        $canonicalArguments = Get-AiSopCanonicalToolArguments `
            -Arguments $toolPayload.Arguments `
            -PolicyEntry $policyEntry `
            -WorkspaceContext $workspace `
            -TargetPaths $physicalTargetPaths
    }

    $semanticObject = [ordered]@{
        tool = $canonicalName
        args = $canonicalArguments
    }
    $semanticArgsSha256 = Get-AiSopSha256Hex (
        ConvertTo-AiSopCanonicalJson $semanticObject
    )
    $canonicalTargetValues = @(
        $physicalTargetPaths |
            ForEach-Object { $_.ToLowerInvariant() } |
            Sort-Object -Unique
    )
    $targetsSha256 = Get-AiSopSha256Hex (
        ConvertTo-AiSopCanonicalJson -Value $canonicalTargetValues
    )
    $timestamp = Get-AiSopNormalizedTimestamp `
        -Payload $payload `
        -NativeShape $shape.NativeShape `
        -Agent $shape.Agent `
        -NativeSessionId $nativeSessionId `
        -EventHint $EventHint `
        -WorkspacePath $workspace.WorkspacePath `
        -SemanticArgsSha256 $semanticArgsSha256 `
        -TargetsSha256 $targetsSha256 `
        -AcceptedAt $AcceptedAt `
        -DeadlineUtc $DeadlineUtc

    $sessionKey = Get-AiSopSha256Hex (
        [string]::Join(
            [char]0,
            @(
                $shape.Agent,
                $nativeSessionId,
                $workspace.WorkspacePath
            )
        )
    )
    $dedupKey = Get-AiSopSha256Hex (
        [string]::Join(
            [char]0,
            @(
                $shape.Agent,
                $sessionKey,
                $EventHint,
                [string]$timestamp.EpochMs,
                $toolClass,
                $semanticArgsSha256,
                $targetsSha256
            )
        )
    )
    $event = [pscustomobject][ordered]@{
        agent = $shape.Agent
        nativeShape = $shape.NativeShape
        event = $EventHint
        nativeSessionId = $nativeSessionId
        generationId = $generationId
        workspacePath = $workspace.WorkspacePath
        workspaceRoots = @($workspace.WorkspaceRoots)
        cwd = $workspace.Cwd
        normalizedTimestampEpochMs = [int64]$timestamp.EpochMs
        timestampSource = $timestamp.Source
        toolName = $toolName
        toolClass = $toolClass
        targetPaths = @($targetPaths)
        canonicalSemanticArgsSha256 = $semanticArgsSha256
        canonicalTargetsSha256 = $targetsSha256
        rawPayloadSha256 = Get-AiSopSha256Hex $RawPayload
        dedupKey = $dedupKey
    }

    try {
        $eventJson = $event | ConvertTo-Json -Compress -Depth 100
        if (-not ($eventJson | Test-Json -SchemaFile $script:HookEventSchemaPath)) {
            Throw-AiSopHookError "PAYLOAD_SHAPE_INVALID"
        }
    } catch {
        if ($_.Exception.Message -eq "PAYLOAD_SHAPE_INVALID") {
            throw
        }
        Throw-AiSopHookError "PAYLOAD_SHAPE_INVALID"
    }
    return $event
}
