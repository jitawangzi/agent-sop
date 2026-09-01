#requires -Version 7.0

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$ScriptsRoot = Split-Path -Parent $PSScriptRoot
$NormalizerScript = Join-Path $ScriptsRoot "hook-event-normalizer.ps1"
$EventSchema = Join-Path (Split-Path -Parent $ScriptsRoot) "schemas\hook-event.schema.json"
$PolicySchema = Join-Path (Split-Path -Parent $ScriptsRoot) "schemas\hook-tool-policy.schema.json"
$PolicyPath = Join-Path (Split-Path -Parent $ScriptsRoot) "config\hook-tool-policy.json"
$FixtureRoot = Join-Path $PSScriptRoot "fixtures\hooks"

foreach ($requiredPath in @($NormalizerScript, $EventSchema, $PolicySchema, $PolicyPath)) {
    if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required Task 2 artifact does not exist: $requiredPath"
    }
}

. $NormalizerScript

$ExpectedHookEventFields = @(
    "agent",
    "canonicalSemanticArgsSha256",
    "canonicalTargetsSha256",
    "cwd",
    "dedupKey",
    "event",
    "generationId",
    "nativeSessionId",
    "nativeShape",
    "normalizedTimestampEpochMs",
    "rawPayloadSha256",
    "targetPaths",
    "timestampSource",
    "toolClass",
    "toolName",
    "workspacePath",
    "workspaceRoots"
) | Sort-Object

$ExpectedValidatorFunctions = @(
    "Test-ClaudeSessionStartShape",
    "Test-ClaudeSessionEndShape",
    "Test-ClaudePreToolUseShape",
    "Test-CopilotCompatShape",
    "Test-CopilotNativeShape",
    "Test-CursorSessionStartShape",
    "Test-CursorSessionEndShape",
    "Test-CursorPreToolUseShape",
    "Test-AntigravityShape"
)

$ExpectedFixtureNames = @(
    "claude-session-start.json",
    "claude-session-end.json",
    "claude-pre-tool-edit.json",
    "cursor-session-start.json",
    "cursor-session-start-no-mode.json",
    "cursor-session-end.json",
    "cursor-pre-tool-edit.json",
    "cursor-claim-before-context.json",
    "cursor-pre-tool-session-mismatch.json",
    "copilot-claude-compat-session-start.json",
    "copilot-claude-compat-pre-tool-read.json",
    "copilot-claude-compat-pre-tool-edit.json",
    "copilot-claude-compat-pre-tool-shell.json",
    "copilot-github-session-start.json",
    "copilot-github-pre-tool-read.json",
    "copilot-github-pre-tool-edit-object-args.json",
    "copilot-github-pre-tool-edit-string-args.json",
    "copilot-github-pre-tool-shell.json",
    "antigravity-pre-invocation.json",
    "antigravity-pre-tool-edit.json",
    "antigravity-stop-idle.json",
    "antigravity-stop-busy.json",
    "ambiguous-shape.json",
    "claude-copilot-pascal-ambiguous.json",
    "unknown-shape.json",
    "multi-target-apply-patch.json",
    "str-replace-editor.json",
    "delete-target.json"
)

function Assert-Equal {
    param(
        [AllowNull()]
        [object]$Actual,

        [AllowNull()]
        [object]$Expected,

        [Parameter(Mandatory)]
        [string]$Message
    )

    if ($Actual -ne $Expected) {
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

function Assert-ThrowsCode {
    param(
        [scriptblock]$Action,
        [string]$Code,
        [string]$Message
    )

    try {
        & $Action | Out-Null
    } catch {
        if ($_.Exception.Message -notlike "$Code*") {
            throw "$Message Expected error '$Code', got '$($_.Exception.Message)'."
        }
        return
    }
    throw "$Message Expected error '$Code', but the action succeeded."
}

function Get-TestSha256Hex {
    param(
        [AllowEmptyString()]
        [string]$Value
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha.ComputeHash(
            [System.Text.UTF8Encoding]::new($false).GetBytes($Value)
        )
    } finally {
        $sha.Dispose()
    }
    return ([System.BitConverter]::ToString($hash)).Replace("-", "").ToLowerInvariant()
}

function Expand-FixtureValue {
    param(
        [AllowNull()]
        [object]$Value,
        [string]$Workspace,
        [string]$Transcript
    )

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [string]) {
        $expanded = $Value.Replace("__WORKSPACE__", $Workspace).Replace(
            "__TRANSCRIPT__",
            $Transcript
        )
        if (-not [System.OperatingSystem]::IsWindows()) {
            $expanded = $expanded.Replace(
                '\',
                [string][System.IO.Path]::DirectorySeparatorChar
            )
        }
        return $expanded
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $expanded = [ordered]@{}
        foreach ($key in $Value.Keys) {
            $expanded[$key] = Expand-FixtureValue `
                -Value $Value[$key] -Workspace $Workspace -Transcript $Transcript
        }
        return $expanded
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        return ,@(
            foreach ($item in $Value) {
                Expand-FixtureValue `
                    -Value $item -Workspace $Workspace -Transcript $Transcript
            }
        )
    }
    return $Value
}

function Get-FixturePayload {
    param(
        [string]$Name,
        [string]$Workspace,
        [string]$Transcript
    )

    $fixturePath = Join-Path $FixtureRoot $Name
    if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
        throw "Fixture does not exist: $fixturePath"
    }
    $payload = Get-Content -LiteralPath $fixturePath -Raw |
        ConvertFrom-Json -AsHashtable -Depth 100
    return Expand-FixtureValue `
        -Value $payload -Workspace $Workspace -Transcript $Transcript
}

function ConvertTo-RawPayload {
    param([System.Collections.IDictionary]$Payload)

    return $Payload | ConvertTo-Json -Compress -Depth 100
}

function Get-CanonicalProfileHash {
    param(
        [string]$Profile,
        [System.Collections.IDictionary]$Arguments,
        [object]$WorkspaceContext,
        [string[]]$TargetPaths = @()
    )

    $canonical = Get-AiSopCanonicalToolArguments `
        -Arguments $Arguments `
        -PolicyEntry ([pscustomobject]@{ ArgumentProfile = $Profile }) `
        -WorkspaceContext $WorkspaceContext `
        -TargetPaths $TargetPaths
    return Get-TestSha256Hex (
        ConvertTo-AiSopCanonicalJson -Value $canonical
    )
}

function Convert-Fixture {
    param(
        [string]$Name,
        [string]$EventHint,
        [string]$Workspace,
        [string]$Transcript,
        [DateTimeOffset]$AcceptedAt
    )

    $payload = Get-FixturePayload `
        -Name $Name -Workspace $Workspace -Transcript $Transcript
    return ConvertTo-AiSopHookEvent `
        -RawPayload (ConvertTo-RawPayload -Payload $payload) `
        -EventHint $EventHint `
        -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt
}

function Assert-HookEventContract {
    param(
        [object]$Event,
        [string]$Message
    )

    $actualFields = @($Event.PSObject.Properties.Name | Sort-Object)
    Assert-Equal `
        -Actual ($actualFields -join ",") `
        -Expected ($ExpectedHookEventFields -join ",") `
        -Message "$Message HookEvent fields differ from DC-023."
    $eventJson = $Event | ConvertTo-Json -Compress -Depth 100
    Assert-True `
        -Condition ($eventJson | Test-Json -SchemaFile $EventSchema) `
        -Message "$Message HookEvent does not satisfy its schema."
}

function New-ClaudeToolPayload {
    param(
        [string]$ToolName,
        [System.Collections.IDictionary]$ToolInput,
        [string]$Workspace,
        [string]$Transcript,
        [string]$Occurrence = "toolu_generated_001"
    )

    $payload = Get-FixturePayload `
        -Name "claude-pre-tool-edit.json" `
        -Workspace $Workspace `
        -Transcript $Transcript
    $payload.tool_name = $ToolName
    $payload.tool_input = $ToolInput
    $payload.tool_use_id = $Occurrence
    return $payload
}

function New-AntigravityToolPayload {
    param(
        [string]$ToolName,
        [System.Collections.IDictionary]$Arguments,
        [string]$Workspace
    )

    return [ordered]@{
        conversationId = "antigravity-generated-001"
        workspacePaths = @($Workspace)
        toolCall = [ordered]@{
            name = $ToolName
            args = $Arguments
        }
    }
}

$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "hook-event-normalizer-tests-" + [guid]::NewGuid().ToString("N")
)
$Workspace = Join-Path $TestRoot "workspace"
$Transcript = Join-Path $TestRoot "transcript.jsonl"
$PreviousDedupRegistry = $env:SERVER_NEW_HOOK_DEDUP_REGISTRY
$env:SERVER_NEW_HOOK_DEDUP_REGISTRY = Join-Path $TestRoot "dedup-registry"
$AcceptedAt = [DateTimeOffset]::Parse("2026-08-17T08:00:05.000Z")
$CreatedJunctions = @()

try {
    [System.IO.Directory]::CreateDirectory($Workspace) | Out-Null
    [System.IO.Directory]::CreateDirectory(
        (Join-Path $Workspace ".claude")
    ) | Out-Null
    [System.IO.File]::WriteAllText(
        (Join-Path $Workspace "README.md"),
        "fixture"
    )

    foreach ($functionName in $ExpectedValidatorFunctions) {
        Assert-True `
            -Condition ($null -ne (Get-Command $functionName -ErrorAction SilentlyContinue)) `
            -Message "Required event-specific validator is missing: $functionName"
    }
    foreach ($fixtureName in $ExpectedFixtureNames) {
        Assert-True `
            -Condition (Test-Path -LiteralPath (Join-Path $FixtureRoot $fixtureName)) `
            -Message "Required DC-049 fixture is missing: $fixtureName"
    }

    $policyJson = Get-Content -LiteralPath $PolicyPath -Raw
    Assert-True `
        -Condition ($policyJson | Test-Json -SchemaFile $PolicySchema) `
        -Message "Tool policy does not satisfy hook-tool-policy.schema.json."
    $policy = $policyJson | ConvertFrom-Json
    Assert-Equal `
        -Actual $policy.unknownClass `
        -Expected "UNKNOWN" `
        -Message "Tool policy must configure fail-closed UNKNOWN."
    foreach ($toolClass in @("SAFE_NON_EDIT", "FILE_EDIT", "OWNER_REQUIRED")) {
        Assert-True `
            -Condition (@($policy.tools | Where-Object { $_.toolClass -eq $toolClass }).Count -gt 0) `
            -Message "Tool policy has no explicit $toolClass entry."
    }

    $normalizerSource = Get-Content -LiteralPath $NormalizerScript -Raw
    if (
        $normalizerSource -match
        "Invoke-WebRequest|Invoke-RestMethod|Start-BitsTransfer|git\s+(fetch|clone)|svn\s+(checkout|update)"
    ) {
        throw "Hook normalization must be network-free."
    }
    Assert-True `
        -Condition (
            (Get-Command ConvertTo-AiSopHookEvent).Parameters.ContainsKey(
                "DeadlineUtc"
            )
        ) `
        -Message "Normalizer does not accept the shared absolute deadline."
    Assert-True `
        -Condition (
            (Get-Command Invoke-AiSopHookRegistryScavenge).Parameters.ContainsKey(
                "DeadlineUtc"
            )
        ) `
        -Message "Registry scavenger does not consume the shared deadline."

    $cachedPolicyOne = Get-AiSopToolPolicy -PolicyPath $PolicyPath
    $cachedPolicyTwo = Get-AiSopToolPolicy -PolicyPath $PolicyPath
    Assert-True `
        -Condition ([object]::ReferenceEquals($cachedPolicyOne, $cachedPolicyTwo)) `
        -Message "Unchanged tool policy was reparsed instead of cache-hit."
    $driftPolicyPath = Join-Path $TestRoot "drift-tool-policy.json"
    [System.IO.File]::Copy($PolicyPath, $driftPolicyPath)
    Get-AiSopToolPolicy -PolicyPath $driftPolicyPath | Out-Null
    $driftWriteTime = [System.IO.File]::GetLastWriteTimeUtc($driftPolicyPath)
    [System.IO.File]::WriteAllText(
        $driftPolicyPath,
        '{"schemaVersion":"1.0","unknownClass":"UNKNOWN","tools":[]}',
        [System.Text.UTF8Encoding]::new($false)
    )
    [System.IO.File]::SetLastWriteTimeUtc($driftPolicyPath, $driftWriteTime)
    Assert-ThrowsCode -Code "TOOL_UNKNOWN" `
        -Message "Policy hash drift bypassed schema revalidation." `
        -Action {
            Get-AiSopToolPolicy -PolicyPath $driftPolicyPath
        }

    # Claude Start/End/PreToolUse use independent validators. Both common
    # permission/transcript fields are optional, while bad optional types deny.
    $claudeCases = @(
        @("claude-session-start.json", "SESSION_START", "CLAUDE_SESSION_START"),
        @("claude-session-end.json", "SESSION_END", "CLAUDE_SESSION_END"),
        @("claude-pre-tool-edit.json", "PRE_TOOL_USE", "CLAUDE_PRE_TOOL_USE")
    )
    foreach ($case in $claudeCases) {
        $fixtureName = $case[0]
        $eventHint = $case[1]
        $expectedShape = $case[2]
        $event = Convert-Fixture `
            -Name $fixtureName -EventHint $eventHint `
            -Workspace $Workspace -Transcript $Transcript -AcceptedAt $AcceptedAt
        Assert-Equal $event.agent "CLAUDE_CODE" "$fixtureName agent mismatch."
        Assert-Equal $event.nativeShape $expectedShape "$fixtureName shape mismatch."
        Assert-HookEventContract $event $fixtureName

        foreach ($absentFields in @(
            @("permission_mode"),
            @("transcript_path"),
            @("permission_mode", "transcript_path")
        )) {
            $withoutCommonOptionals = Get-FixturePayload `
                -Name $fixtureName -Workspace $Workspace -Transcript $Transcript
            foreach ($absentField in $absentFields) {
                $withoutCommonOptionals.Remove($absentField)
            }
            $withoutEvent = ConvertTo-AiSopHookEvent `
                -RawPayload (ConvertTo-RawPayload $withoutCommonOptionals) `
                -EventHint $eventHint -TrustedWorkspaceRoot $Workspace `
                -AcceptedAt $AcceptedAt
            Assert-Equal `
                $withoutEvent.agent "CLAUDE_CODE" `
                "$fixtureName rejected optional absence: $($absentFields -join ',')."
        }

        $withPermission = Get-FixturePayload `
            -Name $fixtureName -Workspace $Workspace -Transcript $Transcript
        $withPermission.permission_mode = "default"
        $withPermissionEvent = ConvertTo-AiSopHookEvent `
            -RawPayload (ConvertTo-RawPayload $withPermission) `
            -EventHint $eventHint -TrustedWorkspaceRoot $Workspace `
            -AcceptedAt $AcceptedAt
        Assert-Equal `
            $withPermissionEvent.agent "CLAUDE_CODE" `
            "$fixtureName must allow a valid permission_mode."

        $badPermission = Get-FixturePayload `
            -Name $fixtureName -Workspace $Workspace -Transcript $Transcript
        $badPermission.permission_mode = 1
        Assert-ThrowsCode -Code "PAYLOAD_SHAPE_INVALID" `
            -Message "$fixtureName accepted an invalid permission_mode." `
            -Action {
                ConvertTo-AiSopHookEvent `
                    -RawPayload (ConvertTo-RawPayload $badPermission) `
                    -EventHint $eventHint -TrustedWorkspaceRoot $Workspace `
                    -AcceptedAt $AcceptedAt
            }

        $badTranscript = Get-FixturePayload `
            -Name $fixtureName -Workspace $Workspace -Transcript $Transcript
        $badTranscript.transcript_path = 42
        Assert-ThrowsCode -Code "PAYLOAD_SHAPE_INVALID" `
            -Message "$fixtureName accepted an invalid transcript_path." `
            -Action {
                ConvertTo-AiSopHookEvent `
                    -RawPayload (ConvertTo-RawPayload $badTranscript) `
                    -EventHint $eventHint -TrustedWorkspaceRoot $Workspace `
                    -AcceptedAt $AcceptedAt
            }
    }

    $corruptPayload = Get-FixturePayload `
        -Name "claude-session-start.json" `
        -Workspace $Workspace -Transcript $Transcript
    $corruptPayload.session_id = "claude-corrupt-correlation"
    $correlationFilesBefore = @(
        Get-ChildItem `
            -LiteralPath (Join-Path $env:SERVER_NEW_HOOK_DEDUP_REGISTRY "correlations") `
            -Filter "*.json" `
            -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName }
    )
    ConvertTo-AiSopHookEvent `
        -RawPayload (ConvertTo-RawPayload $corruptPayload) `
        -EventHint "SESSION_START" `
        -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt | Out-Null
    $correlationRecord = @(
        Get-ChildItem `
            -LiteralPath (Join-Path $env:SERVER_NEW_HOOK_DEDUP_REGISTRY "correlations") `
            -Filter "*.json" |
            Where-Object { $_.FullName -notin $correlationFilesBefore }
    )
    Assert-Equal `
        $correlationRecord.Count 1 `
        "Could not isolate corrupt-correlation fixture record."
    [System.IO.File]::WriteAllText($correlationRecord[0].FullName, "{")
    Assert-ThrowsCode -Code "REGISTRY_CORRUPT" `
        -Message "Malformed correlation record was silently replaced." `
        -Action {
            ConvertTo-AiSopHookEvent `
                -RawPayload (ConvertTo-RawPayload $corruptPayload) `
                -EventHint "SESSION_START" `
                -TrustedWorkspaceRoot $Workspace `
                -AcceptedAt $AcceptedAt.AddMilliseconds(1)
        }
    [System.IO.File]::Delete($correlationRecord[0].FullName)

    # A current correlation key must be read under its own lock and validated
    # before expiry can make it eligible for replacement.
    $correlationRegistryBefore = $env:SERVER_NEW_HOOK_DEDUP_REGISTRY
    try {
        $correlationCorruptCases = @(
            [pscustomobject]@{
                Name = "missing-required"
                Mutate = {
                    param($record)
                    $record.Remove("normalizedTimestampEpochMs") | Out-Null
                }
            },
            [pscustomobject]@{
                Name = "wrong-identity"
                Mutate = {
                    param($record)
                    $record.correlationKey = ("f" * 64)
                }
            }
        )
        foreach ($corruptCase in $correlationCorruptCases) {
            $caseRegistry = Join-Path `
                $TestRoot "correlation-corrupt-$($corruptCase.Name)"
            $env:SERVER_NEW_HOOK_DEDUP_REGISTRY = $caseRegistry
            $casePayload = Get-FixturePayload `
                -Name "claude-session-start.json" `
                -Workspace $Workspace -Transcript $Transcript
            $casePayload.session_id = "correlation-$($corruptCase.Name)"
            ConvertTo-AiSopHookEvent `
                -RawPayload (ConvertTo-RawPayload $casePayload) `
                -EventHint "SESSION_START" `
                -TrustedWorkspaceRoot $Workspace `
                -AcceptedAt $AcceptedAt | Out-Null
            $caseRecordPath = (
                Get-ChildItem `
                    -LiteralPath (Join-Path $caseRegistry "correlations") `
                    -Filter "*.json"
            )[0].FullName
            $caseRecord = Get-Content -LiteralPath $caseRecordPath -Raw |
                ConvertFrom-Json -AsHashtable -Depth 20
            $caseRecord.expiresAt = $AcceptedAt.AddSeconds(-1).ToString("o")
            $mutate = $corruptCase.Mutate
            & $mutate $caseRecord
            $caseRecordJson = $caseRecord | ConvertTo-Json -Compress -Depth 20
            [System.IO.File]::WriteAllText(
                $caseRecordPath,
                $caseRecordJson,
                [System.Text.UTF8Encoding]::new($false)
            )
            Assert-ThrowsCode -Code "REGISTRY_CORRUPT" `
                -Message (
                    "Expired correlation $($corruptCase.Name) record " +
                    "was scavenged before strict validation."
                ) `
                -Action {
                    ConvertTo-AiSopHookEvent `
                        -RawPayload (ConvertTo-RawPayload $casePayload) `
                        -EventHint "SESSION_START" `
                        -TrustedWorkspaceRoot $Workspace `
                        -AcceptedAt $AcceptedAt.AddSeconds(10)
                }
            Assert-True `
                -Condition ([System.IO.File]::Exists($caseRecordPath)) `
                -Message "Corrupt correlation record was deleted."
            Assert-Equal `
                ([System.IO.File]::ReadAllText($caseRecordPath)) `
                $caseRecordJson `
                "Corrupt correlation record was replaced."
        }

        # The lazy scavenger must apply the correlation schema to records that
        # are not the current key as well.
        $foreignRegistry = Join-Path $TestRoot "correlation-corrupt-foreign"
        $env:SERVER_NEW_HOOK_DEDUP_REGISTRY = $foreignRegistry
        $foreignPayload = Get-FixturePayload `
            -Name "claude-session-start.json" `
            -Workspace $Workspace -Transcript $Transcript
        $foreignPayload.session_id = "correlation-foreign-corrupt"
        ConvertTo-AiSopHookEvent `
            -RawPayload (ConvertTo-RawPayload $foreignPayload) `
            -EventHint "SESSION_START" `
            -TrustedWorkspaceRoot $Workspace `
            -AcceptedAt $AcceptedAt | Out-Null
        $foreignRecordPath = (
            Get-ChildItem `
                -LiteralPath (Join-Path $foreignRegistry "correlations") `
                -Filter "*.json"
        )[0].FullName
        $foreignRecord = Get-Content -LiteralPath $foreignRecordPath -Raw |
            ConvertFrom-Json -AsHashtable -Depth 20
        $foreignRecord.expiresAt = $AcceptedAt.AddSeconds(-1).ToString("o")
        $foreignRecord.Remove("normalizedTimestampEpochMs") | Out-Null
        $foreignRecordJson = $foreignRecord |
            ConvertTo-Json -Compress -Depth 20
        [System.IO.File]::WriteAllText(
            $foreignRecordPath,
            $foreignRecordJson,
            [System.Text.UTF8Encoding]::new($false)
        )
        $otherPayload = Get-FixturePayload `
            -Name "claude-session-start.json" `
            -Workspace $Workspace -Transcript $Transcript
        $otherPayload.session_id = "correlation-other-current-key"
        Assert-ThrowsCode -Code "REGISTRY_CORRUPT" `
            -Message "Correlation scavenger ignored a schema-invalid record." `
            -Action {
                ConvertTo-AiSopHookEvent `
                    -RawPayload (ConvertTo-RawPayload $otherPayload) `
                    -EventHint "SESSION_START" `
                    -TrustedWorkspaceRoot $Workspace `
                    -AcceptedAt $AcceptedAt.AddSeconds(10)
            }
        Assert-Equal `
            ([System.IO.File]::ReadAllText($foreignRecordPath)) `
            $foreignRecordJson `
            "Correlation scavenger deleted or replaced a corrupt record."
    } finally {
        $env:SERVER_NEW_HOOK_DEDUP_REGISTRY = $correlationRegistryBefore
    }
    $workingRegistry = $env:SERVER_NEW_HOOK_DEDUP_REGISTRY
    $registryBlocker = Join-Path $TestRoot "registry-io-blocker"
    [System.IO.File]::WriteAllText($registryBlocker, "not-a-directory")
    $env:SERVER_NEW_HOOK_DEDUP_REGISTRY = $registryBlocker
    try {
        $ioPayload = Get-FixturePayload `
            -Name "claude-session-start.json" `
            -Workspace $Workspace -Transcript $Transcript
        $ioPayload.session_id = "claude-correlation-io-failure"
        Assert-ThrowsCode -Code "REGISTRY_IO_ERROR" `
            -Message "Correlation I/O failure was not stable/fail-closed." `
            -Action {
                ConvertTo-AiSopHookEvent `
                    -RawPayload (ConvertTo-RawPayload $ioPayload) `
                    -EventHint "SESSION_START" `
                    -TrustedWorkspaceRoot $Workspace `
                    -AcceptedAt $AcceptedAt
            }
    } finally {
        $env:SERVER_NEW_HOOK_DEDUP_REGISTRY = $workingRegistry
    }

    $lifecycleBoundaryPayload = Get-FixturePayload `
        -Name "claude-session-start.json" `
        -Workspace $Workspace -Transcript $Transcript
    $lifecycleBoundaryPayload.session_id = "claude-lifecycle-boundary"
    $lifecycleBoundaryRaw = ConvertTo-RawPayload $lifecycleBoundaryPayload
    $lifecycleAtZero = ConvertTo-AiSopHookEvent `
        -RawPayload $lifecycleBoundaryRaw `
        -EventHint "SESSION_START" -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt
    $lifecycleBeforeFive = ConvertTo-AiSopHookEvent `
        -RawPayload $lifecycleBoundaryRaw `
        -EventHint "SESSION_START" -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt.AddMilliseconds(4999)
    $lifecycleAtFive = ConvertTo-AiSopHookEvent `
        -RawPayload $lifecycleBoundaryRaw `
        -EventHint "SESSION_START" -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt.AddSeconds(5)
    Assert-Equal `
        $lifecycleAtZero.dedupKey $lifecycleBeforeFive.dedupKey `
        "Timeless lifecycle event split before five-second boundary."
    Assert-True `
        -Condition ($lifecycleAtZero.dedupKey -ne $lifecycleAtFive.dedupKey) `
        -Message "Timeless lifecycle event retained correlation at +5s boundary."

    $occurrencePayload = Get-FixturePayload `
        -Name "claude-pre-tool-edit.json" `
        -Workspace $Workspace -Transcript $Transcript
    $occurrencePayload.session_id = "claude-occurrence-retention"
    $occurrencePayload.tool_use_id = "toolu_occurrence_retention"
    $occurrenceRaw = ConvertTo-RawPayload $occurrencePayload
    $occurrenceFirst = ConvertTo-AiSopHookEvent `
        -RawPayload $occurrenceRaw `
        -EventHint "PRE_TOOL_USE" -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt
    $occurrenceAfterTen = ConvertTo-AiSopHookEvent `
        -RawPayload $occurrenceRaw `
        -EventHint "PRE_TOOL_USE" -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt.AddSeconds(10)
    Assert-Equal `
        $occurrenceFirst.dedupKey $occurrenceAfterTen.dedupKey `
        "Safe occurrence ID expired with lifecycle correlation window."

    # Copilot PascalCase event / snake_case payload and camelCase payload are
    # separate native validators that normalize to one Agent and semantics.
    foreach ($minimalCase in @(
        @([ordered]@{
            hook_event_name = "SessionStart"
            session_id = "copilot-session-001"
            timestamp = "2026-08-17T08:00:00.000Z"
            cwd = $Workspace
        }, "SESSION_START", "COPILOT_CLAUDE_COMPAT"),
        @([ordered]@{
            sessionId = "copilot-session-001"
            timestamp = 1786953600000
            cwd = $Workspace
        }, "SESSION_START", "COPILOT_GITHUB_NATIVE"),
        @([ordered]@{
            hook_event_name = "SessionEnd"
            session_id = "copilot-session-001"
            timestamp = "2026-08-17T08:00:04.000Z"
            cwd = $Workspace
        }, "SESSION_END", "COPILOT_CLAUDE_COMPAT"),
        @([ordered]@{
            sessionId = "copilot-session-001"
            timestamp = 1786953604000
            cwd = $Workspace
        }, "SESSION_END", "COPILOT_GITHUB_NATIVE")
    )) {
        $minimalEvent = ConvertTo-AiSopHookEvent `
            -RawPayload (ConvertTo-RawPayload $minimalCase[0]) `
            -EventHint $minimalCase[1] `
            -TrustedWorkspaceRoot $Workspace `
            -AcceptedAt $AcceptedAt
        Assert-Equal `
            $minimalEvent.nativeShape $minimalCase[2] `
            "Copilot minimal lifecycle shape was rejected."
    }
    $compatStart = Convert-Fixture `
        -Name "copilot-claude-compat-session-start.json" `
        -EventHint "SESSION_START" -Workspace $Workspace `
        -Transcript $Transcript -AcceptedAt $AcceptedAt
    $nativeStart = Convert-Fixture `
        -Name "copilot-github-session-start.json" `
        -EventHint "SESSION_START" -Workspace $Workspace `
        -Transcript $Transcript -AcceptedAt $AcceptedAt
    foreach ($event in @($compatStart, $nativeStart)) {
        Assert-Equal $event.agent "COPILOT" "Copilot session Agent mismatch."
        Assert-HookEventContract $event "Copilot session"
    }
    Assert-Equal `
        $compatStart.canonicalSemanticArgsSha256 `
        $nativeStart.canonicalSemanticArgsSha256 `
        "Copilot SessionStart semantics differ across native formats."
    Assert-Equal `
        $compatStart.dedupKey $nativeStart.dedupKey `
        "Copilot SessionStart dedup key differs across native formats."
    $compatMissingTimestamp = Get-FixturePayload `
        -Name "copilot-claude-compat-session-start.json" `
        -Workspace $Workspace -Transcript $Transcript
    $compatMissingTimestamp.Remove("timestamp")
    Assert-ThrowsCode -Code "PAYLOAD_SHAPE_INVALID" `
        -Message "Copilot compat accepted a missing timestamp." `
        -Action {
            ConvertTo-AiSopHookEvent `
                -RawPayload (ConvertTo-RawPayload $compatMissingTimestamp) `
                -EventHint "SESSION_START" -TrustedWorkspaceRoot $Workspace `
                -AcceptedAt $AcceptedAt
        }
    $nativeIsoTimestamp = Get-FixturePayload `
        -Name "copilot-github-session-start.json" `
        -Workspace $Workspace -Transcript $Transcript
    $nativeIsoTimestamp.timestamp = "2026-08-17T08:00:00.000Z"
    Assert-ThrowsCode -Code "PAYLOAD_SHAPE_INVALID" `
        -Message "Copilot native accepted an ISO timestamp." `
        -Action {
            ConvertTo-AiSopHookEvent `
                -RawPayload (ConvertTo-RawPayload $nativeIsoTimestamp) `
                -EventHint "SESSION_START" -TrustedWorkspaceRoot $Workspace `
                -AcceptedAt $AcceptedAt
        }

    $compatEndPayload = [ordered]@{
        hook_event_name = "SessionEnd"
        session_id = "copilot-session-001"
        timestamp = "2026-08-17T08:00:04.000Z"
        cwd = $Workspace
        reason = "complete"
    }
    $nativeEndPayload = [ordered]@{
        sessionId = "copilot-session-001"
        timestamp = 1786953604000
        cwd = $Workspace
        reason = "complete"
    }
    $compatEnd = ConvertTo-AiSopHookEvent `
        -RawPayload (ConvertTo-RawPayload $compatEndPayload) `
        -EventHint "SESSION_END" -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt
    $nativeEnd = ConvertTo-AiSopHookEvent `
        -RawPayload (ConvertTo-RawPayload $nativeEndPayload) `
        -EventHint "SESSION_END" -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt
    Assert-Equal $compatEnd.agent "COPILOT" "Copilot compat End agent mismatch."
    Assert-Equal $nativeEnd.agent "COPILOT" "Copilot native End agent mismatch."
    Assert-Equal `
        $compatEnd.dedupKey $nativeEnd.dedupKey `
        "Copilot SessionEnd dedup key differs across native formats."
    $compatEndPayload.Remove("timestamp")
    Assert-ThrowsCode -Code "PAYLOAD_SHAPE_INVALID" `
        -Message "Timestamp-less Copilot SessionEnd was misclassified as Claude." `
        -Action {
            ConvertTo-AiSopHookEvent `
                -RawPayload (ConvertTo-RawPayload $compatEndPayload) `
                -EventHint "SESSION_END" -TrustedWorkspaceRoot $Workspace `
                -AcceptedAt $AcceptedAt
        }

    $compatRead = Convert-Fixture `
        -Name "copilot-claude-compat-pre-tool-read.json" `
        -EventHint "PRE_TOOL_USE" -Workspace $Workspace `
        -Transcript $Transcript -AcceptedAt $AcceptedAt
    $nativeRead = Convert-Fixture `
        -Name "copilot-github-pre-tool-read.json" `
        -EventHint "PRE_TOOL_USE" -Workspace $Workspace `
        -Transcript $Transcript -AcceptedAt $AcceptedAt
    Assert-Equal $compatRead.agent "COPILOT" "Compat Read was not COPILOT."
    Assert-Equal $nativeRead.agent "COPILOT" "Native Read was not COPILOT."
    Assert-Equal $compatRead.toolClass "SAFE_NON_EDIT" "Compat Read class mismatch."
    Assert-Equal $nativeRead.toolClass "SAFE_NON_EDIT" "Native Read class mismatch."
    Assert-Equal `
        $compatRead.canonicalSemanticArgsSha256 `
        $nativeRead.canonicalSemanticArgsSha256 `
        "Copilot Read semantic args differ across native formats."
    Assert-Equal `
        $compatRead.dedupKey $nativeRead.dedupKey `
        "Copilot Read dedup key differs across native formats."
    Assert-Equal `
        $compatRead.canonicalTargetsSha256 `
        (Get-TestSha256Hex "[]") `
        "A no-target event must hash the canonical empty array."

    $nativeEditObject = Convert-Fixture `
        -Name "copilot-github-pre-tool-edit-object-args.json" `
        -EventHint "PRE_TOOL_USE" -Workspace $Workspace `
        -Transcript $Transcript -AcceptedAt $AcceptedAt
    $nativeEditString = Convert-Fixture `
        -Name "copilot-github-pre-tool-edit-string-args.json" `
        -EventHint "PRE_TOOL_USE" -Workspace $Workspace `
        -Transcript $Transcript -AcceptedAt $AcceptedAt
    Assert-Equal `
        $nativeEditObject.canonicalSemanticArgsSha256 `
        $nativeEditString.canonicalSemanticArgsSha256 `
        "Copilot object/string toolArgs semantics differ."
    Assert-Equal `
        $nativeEditObject.canonicalTargetsSha256 `
        $nativeEditString.canonicalTargetsSha256 `
        "Copilot object/string toolArgs target hashes differ."
    Assert-Equal `
        (@($nativeEditObject.targetPaths).Count) 1 `
        "Copilot object Edit target count mismatch."
    $badJsonArgs = Get-FixturePayload `
        -Name "copilot-github-pre-tool-edit-string-args.json" `
        -Workspace $Workspace -Transcript $Transcript
    $badJsonArgs.toolArgs = '{"file_path":'
    Assert-ThrowsCode -Code "TOOL_ARGS_INVALID" `
        -Message "Copilot accepted malformed JSON-string toolArgs." `
        -Action {
            ConvertTo-AiSopHookEvent `
                -RawPayload (ConvertTo-RawPayload $badJsonArgs) `
                -EventHint "PRE_TOOL_USE" -TrustedWorkspaceRoot $Workspace `
                -AcceptedAt $AcceptedAt
        }
    $doubleEncodedArgs = Get-FixturePayload `
        -Name "copilot-github-pre-tool-edit-string-args.json" `
        -Workspace $Workspace -Transcript $Transcript
    $doubleEncodedArgs.toolArgs = (
        $doubleEncodedArgs.toolArgs | ConvertTo-Json -Compress
    )
    Assert-ThrowsCode -Code "TOOL_ARGS_INVALID" `
        -Message "Copilot toolArgs were parsed more than once." `
        -Action {
            ConvertTo-AiSopHookEvent `
                -RawPayload (ConvertTo-RawPayload $doubleEncodedArgs) `
                -EventHint "PRE_TOOL_USE" -TrustedWorkspaceRoot $Workspace `
                -AcceptedAt $AcceptedAt
        }

    # Cursor lifecycle uses official independent Start and End shapes; composer
    # and error fields are optional with strict types.
    $cursorStart = Convert-Fixture `
        -Name "cursor-session-start.json" -EventHint "SESSION_START" `
        -Workspace $Workspace -Transcript $Transcript -AcceptedAt $AcceptedAt
    $cursorStartNoMode = Convert-Fixture `
        -Name "cursor-session-start-no-mode.json" -EventHint "SESSION_START" `
        -Workspace $Workspace -Transcript $Transcript -AcceptedAt $AcceptedAt
    $cursorEnd = Convert-Fixture `
        -Name "cursor-session-end.json" -EventHint "SESSION_END" `
        -Workspace $Workspace -Transcript $Transcript -AcceptedAt $AcceptedAt
    $cursorTool = Convert-Fixture `
        -Name "cursor-pre-tool-edit.json" -EventHint "PRE_TOOL_USE" `
        -Workspace $Workspace -Transcript $Transcript -AcceptedAt $AcceptedAt
    Assert-Equal $cursorStart.agent "CURSOR" "Cursor Start agent mismatch."
    Assert-Equal $cursorStartNoMode.agent "CURSOR" "Cursor no-mode Start agent mismatch."
    Assert-Equal $cursorEnd.nativeShape "CURSOR_SESSION_END" "Cursor End shape mismatch."
    Assert-Equal $cursorTool.nativeSessionId "cursor-session-001" "Cursor tool conversation mismatch."
    Assert-Equal $cursorTool.generationId "cursor-generation-001" "Cursor generation mismatch."

    $cursorEndWithError = Get-FixturePayload `
        -Name "cursor-session-end.json" -Workspace $Workspace -Transcript $Transcript
    $cursorEndWithError.error_message = "fixture error"
    $cursorEndErrorEvent = ConvertTo-AiSopHookEvent `
        -RawPayload (ConvertTo-RawPayload $cursorEndWithError) `
        -EventHint "SESSION_END" -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt
    Assert-Equal $cursorEndErrorEvent.agent "CURSOR" "Cursor End error field was rejected."
    $cursorEndWithError.error_message = 42
    Assert-ThrowsCode -Code "PAYLOAD_SHAPE_INVALID" `
        -Message "Cursor SessionEnd accepted non-string error_message." `
        -Action {
            ConvertTo-AiSopHookEvent `
                -RawPayload (ConvertTo-RawPayload $cursorEndWithError) `
                -EventHint "SESSION_END" -TrustedWorkspaceRoot $Workspace `
                -AcceptedAt $AcceptedAt
        }
    $cursorBadComposer = Get-FixturePayload `
        -Name "cursor-session-start.json" `
        -Workspace $Workspace -Transcript $Transcript
    $cursorBadComposer.composer_mode = "compose"
    Assert-ThrowsCode -Code "PAYLOAD_SHAPE_INVALID" `
        -Message "Cursor SessionStart accepted an unknown composer_mode." `
        -Action {
            ConvertTo-AiSopHookEvent `
                -RawPayload (ConvertTo-RawPayload $cursorBadComposer) `
                -EventHint "SESSION_START" -TrustedWorkspaceRoot $Workspace `
                -AcceptedAt $AcceptedAt
        }
    $cursorMissingDuration = Get-FixturePayload `
        -Name "cursor-session-end.json" `
        -Workspace $Workspace -Transcript $Transcript
    $cursorMissingDuration.Remove("duration_ms")
    Assert-ThrowsCode -Code "PAYLOAD_SHAPE_INVALID" `
        -Message "Cursor SessionEnd accepted a missing duration_ms." `
        -Action {
            ConvertTo-AiSopHookEvent `
                -RawPayload (ConvertTo-RawPayload $cursorMissingDuration) `
                -EventHint "SESSION_END" -TrustedWorkspaceRoot $Workspace `
                -AcceptedAt $AcceptedAt
        }

    # Antigravity variants remain strict and map to one Agent.
    foreach ($case in @(
        @("antigravity-pre-invocation.json", "PRE_INVOCATION"),
        @("antigravity-pre-tool-edit.json", "PRE_TOOL_USE"),
        @("antigravity-stop-idle.json", "STOP"),
        @("antigravity-stop-busy.json", "STOP")
    )) {
        $event = Convert-Fixture `
            -Name $case[0] -EventHint $case[1] `
            -Workspace $Workspace -Transcript $Transcript -AcceptedAt $AcceptedAt
        Assert-Equal $event.agent "ANTIGRAVITY" "$($case[0]) agent mismatch."
    }

    # Mixed discriminators, unknown shapes, strict unknown fields, and event
    # mismatches deny with stable reason codes.
    foreach ($ambiguousFixture in @(
        "ambiguous-shape.json",
        "claude-copilot-pascal-ambiguous.json"
    )) {
        Assert-ThrowsCode -Code "PAYLOAD_SHAPE_AMBIGUOUS" `
            -Message "$ambiguousFixture was not denied as ambiguous." `
            -Action {
                Convert-Fixture `
                    -Name $ambiguousFixture -EventHint "PRE_TOOL_USE" `
                    -Workspace $Workspace -Transcript $Transcript `
                    -AcceptedAt $AcceptedAt
            }
    }
    Assert-ThrowsCode -Code "PAYLOAD_SHAPE_UNKNOWN" `
        -Message "Unknown payload was not denied." `
        -Action {
            Convert-Fixture `
                -Name "unknown-shape.json" -EventHint "PRE_TOOL_USE" `
                -Workspace $Workspace -Transcript $Transcript `
                -AcceptedAt $AcceptedAt
        }
    $unknownFieldPayload = Get-FixturePayload `
        -Name "claude-session-start.json" `
        -Workspace $Workspace -Transcript $Transcript
    $unknownFieldPayload.unexpected_field = "deny"
    Assert-ThrowsCode -Code "PAYLOAD_SHAPE_INVALID" `
        -Message "Unknown field on an otherwise valid payload was accepted." `
        -Action {
            ConvertTo-AiSopHookEvent `
                -RawPayload (ConvertTo-RawPayload $unknownFieldPayload) `
                -EventHint "SESSION_START" -TrustedWorkspaceRoot $Workspace `
                -AcceptedAt $AcceptedAt
        }
    Assert-ThrowsCode -Code "EVENT_HINT_MISMATCH" `
        -Message "SessionStart payload was accepted in SessionEnd slot." `
        -Action {
            Convert-Fixture `
                -Name "claude-session-start.json" -EventHint "SESSION_END" `
                -Workspace $Workspace -Transcript $Transcript `
                -AcceptedAt $AcceptedAt
        }

    # Four-state tool policy. This Task classifies OWNER_REQUIRED but performs
    # no Owner/session authorization.
    $compatShell = Convert-Fixture `
        -Name "copilot-claude-compat-pre-tool-shell.json" `
        -EventHint "PRE_TOOL_USE" -Workspace $Workspace `
        -Transcript $Transcript -AcceptedAt $AcceptedAt
    Assert-Equal $compatShell.toolClass "OWNER_REQUIRED" "Shell class mismatch."
    $unknownToolPayload = New-ClaudeToolPayload `
        -ToolName "FutureMutationTool" `
        -ToolInput ([ordered]@{ file_path = (Join-Path $Workspace "future.txt") }) `
        -Workspace $Workspace -Transcript $Transcript
    $unknownTool = ConvertTo-AiSopHookEvent `
        -RawPayload (ConvertTo-RawPayload $unknownToolPayload) `
        -EventHint "PRE_TOOL_USE" -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt
    Assert-Equal $unknownTool.toolClass "UNKNOWN" "Unknown tool must remain UNKNOWN."
    Assert-Equal (@($unknownTool.targetPaths).Count) 0 "UNKNOWN must not infer targets."

    $searchDriftPayload = New-ClaudeToolPayload `
        -ToolName "Grep" `
        -ToolInput ([ordered]@{
            pattern = "needle"
            head_limit = "not-an-integer"
        }) `
        -Workspace $Workspace -Transcript $Transcript `
        -Occurrence "toolu_search_drift_001"
    $searchDrift = ConvertTo-AiSopHookEvent `
        -RawPayload (ConvertTo-RawPayload $searchDriftPayload) `
        -EventHint "PRE_TOOL_USE" -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt
    Assert-Equal `
        $searchDrift.toolClass "UNKNOWN" `
        "A schema-drifted safe search tool must become UNKNOWN."

    $globAmbiguousPayload = New-ClaudeToolPayload `
        -ToolName "Glob" `
        -ToolInput ([ordered]@{
            pattern = "*.ps1"
            glob_pattern = "*.json"
        }) `
        -Workspace $Workspace -Transcript $Transcript `
        -Occurrence "toolu_glob_ambiguous_001"
    $globAmbiguous = ConvertTo-AiSopHookEvent `
        -RawPayload (ConvertTo-RawPayload $globAmbiguousPayload) `
        -EventHint "PRE_TOOL_USE" -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt
    Assert-Equal `
        $globAmbiguous.toolClass "UNKNOWN" `
        "Conflicting safe-tool aliases must become UNKNOWN."

    $conflictPolicy = $policyJson |
        ConvertFrom-Json -AsHashtable -Depth 100
    $conflictingReadEntry = (
        $conflictPolicy.tools |
            Where-Object {
                $_.match.kind -eq "EXACT" -and
                $_.match.value -eq "Read"
            } |
            Select-Object -First 1 |
            ConvertTo-Json -Compress -Depth 20 |
            ConvertFrom-Json -AsHashtable -Depth 20
    )
    $conflictingReadEntry.canonicalName = "READ_CONFLICT"
    $conflictPolicy.tools = @($conflictPolicy.tools) + @($conflictingReadEntry)
    $conflictPolicyPath = Join-Path $TestRoot "conflicting-tool-policy.json"
    [System.IO.File]::WriteAllText(
        $conflictPolicyPath,
        ($conflictPolicy | ConvertTo-Json -Depth 100),
        [System.Text.UTF8Encoding]::new($false)
    )
    $conflictReadPayload = Get-FixturePayload `
        -Name "copilot-claude-compat-pre-tool-read.json" `
        -Workspace $Workspace -Transcript $Transcript
    $conflictRead = ConvertTo-AiSopHookEvent `
        -RawPayload (ConvertTo-RawPayload $conflictReadPayload) `
        -EventHint "PRE_TOOL_USE" -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt -ToolPolicyPath $conflictPolicyPath
    Assert-Equal `
        $conflictRead.toolClass "UNKNOWN" `
        "Conflicting exact policy entries must become UNKNOWN."

    $cursorToolClasses = @(
        @("Read", [ordered]@{
            file_path = (Join-Path $Workspace "README.md")
        }, "SAFE_NON_EDIT"),
        @("Shell", [ordered]@{
            command = "Get-Location"
        }, "OWNER_REQUIRED"),
        @("FutureCursorTool", [ordered]@{
            value = "unknown"
        }, "UNKNOWN")
    )
    foreach ($case in $cursorToolClasses) {
        $payload = Get-FixturePayload `
            -Name "cursor-pre-tool-edit.json" `
            -Workspace $Workspace -Transcript $Transcript
        $payload.tool_name = $case[0]
        $payload.tool_input = $case[1]
        $payload.tool_use_id = "cursor-$($case[0])-matrix"
        $event = ConvertTo-AiSopHookEvent `
            -RawPayload (ConvertTo-RawPayload $payload) `
            -EventHint "PRE_TOOL_USE" -TrustedWorkspaceRoot $Workspace `
            -AcceptedAt $AcceptedAt
        Assert-Equal `
            $event.toolClass $case[2] `
            "Cursor $($case[0]) tool class mismatch."
    }

    $antigravityToolClasses = @(
        @("read_file", [ordered]@{
            path = (Join-Path $Workspace "README.md")
        }, "SAFE_NON_EDIT"),
        @("run_command", [ordered]@{
            command = "Get-Location"
        }, "OWNER_REQUIRED"),
        @("future_antigravity_tool", [ordered]@{
            value = "unknown"
        }, "UNKNOWN")
    )
    foreach ($case in $antigravityToolClasses) {
        $payload = New-AntigravityToolPayload `
            -ToolName $case[0] -Arguments $case[1] -Workspace $Workspace
        $event = ConvertTo-AiSopHookEvent `
            -RawPayload (ConvertTo-RawPayload $payload) `
            -EventHint "PRE_TOOL_USE" -TrustedWorkspaceRoot $Workspace `
            -AcceptedAt $AcceptedAt
        Assert-Equal `
            $event.toolClass $case[2] `
            "Antigravity $($case[0]) tool class mismatch."
    }

    $fourTerminalMatrix = @(
        @("CLAUDE", "Read", [ordered]@{
            file_path = (Join-Path $Workspace "README.md")
        }, "SAFE_NON_EDIT"),
        @("CLAUDE", "Edit", [ordered]@{
            file_path = (Join-Path $Workspace ".claude\matrix-claude.txt")
            old_string = "a"
            new_string = "b"
        }, "FILE_EDIT"),
        @("CLAUDE", "Bash", [ordered]@{ command = "Get-Location" }, "OWNER_REQUIRED"),
        @("CLAUDE", "FutureClaude", [ordered]@{ value = 1 }, "UNKNOWN"),
        @("COPILOT", "view", [ordered]@{
            path = (Join-Path $Workspace "README.md")
        }, "SAFE_NON_EDIT"),
        @("COPILOT", "edit", [ordered]@{
            path = (Join-Path $Workspace ".claude\matrix-copilot.txt")
            old_str = "a"
            new_str = "b"
        }, "FILE_EDIT"),
        @("COPILOT", "bash", [ordered]@{ command = "Get-Location" }, "OWNER_REQUIRED"),
        @("COPILOT", "future_copilot", [ordered]@{ value = 1 }, "UNKNOWN"),
        @("CURSOR", "Read", [ordered]@{
            file_path = (Join-Path $Workspace "README.md")
        }, "SAFE_NON_EDIT"),
        @("CURSOR", "Edit", [ordered]@{
            file_path = (Join-Path $Workspace ".claude\matrix-cursor.txt")
            old_string = "a"
            new_string = "b"
        }, "FILE_EDIT"),
        @("CURSOR", "Shell", [ordered]@{ command = "Get-Location" }, "OWNER_REQUIRED"),
        @("CURSOR", "FutureCursor", [ordered]@{ value = 1 }, "UNKNOWN"),
        @("ANTIGRAVITY", "read_file", [ordered]@{
            path = (Join-Path $Workspace "README.md")
        }, "SAFE_NON_EDIT"),
        @("ANTIGRAVITY", "edit_file", [ordered]@{
            path = (Join-Path $Workspace ".claude\matrix-antigravity.txt")
            old_string = "a"
            new_string = "b"
        }, "FILE_EDIT"),
        @("ANTIGRAVITY", "run_command", [ordered]@{ command = "Get-Location" }, "OWNER_REQUIRED"),
        @("ANTIGRAVITY", "future_antigravity", [ordered]@{ value = 1 }, "UNKNOWN")
    )
    $fourTerminalCount = 0
    foreach ($matrixCase in $fourTerminalMatrix) {
        $matrixPayload = switch ($matrixCase[0]) {
            "CLAUDE" {
                New-ClaudeToolPayload `
                    -ToolName $matrixCase[1] `
                    -ToolInput $matrixCase[2] `
                    -Workspace $Workspace `
                    -Transcript $Transcript `
                    -Occurrence ("toolu_matrix_" + $fourTerminalCount)
            }
            "COPILOT" {
                [ordered]@{
                    sessionId = "copilot-session-001"
                    timestamp = 1786953600000
                    cwd = $Workspace
                    toolName = $matrixCase[1]
                    toolArgs = $matrixCase[2]
                }
            }
            "CURSOR" {
                $payload = Get-FixturePayload `
                    -Name "cursor-pre-tool-edit.json" `
                    -Workspace $Workspace -Transcript $Transcript
                $payload.tool_name = $matrixCase[1]
                $payload.tool_input = $matrixCase[2]
                $payload.tool_use_id = "cursor-matrix-$fourTerminalCount"
                $payload
            }
            "ANTIGRAVITY" {
                New-AntigravityToolPayload `
                    -ToolName $matrixCase[1] `
                    -Arguments $matrixCase[2] `
                    -Workspace $Workspace
            }
        }
        $matrixEvent = ConvertTo-AiSopHookEvent `
            -RawPayload (ConvertTo-RawPayload $matrixPayload) `
            -EventHint "PRE_TOOL_USE" `
            -TrustedWorkspaceRoot $Workspace `
            -AcceptedAt $AcceptedAt
        Assert-Equal `
            $matrixEvent.toolClass $matrixCase[3] `
            "$($matrixCase[0])/$($matrixCase[1]) four-state mismatch."
        $fourTerminalCount++
    }
    Assert-Equal $fourTerminalCount 16 "Four-terminal/four-state matrix incomplete."

    # Antigravity specific safe tools (view_file, list_dir, ask_question, invoke_subagent, etc.)
    foreach ($agToolCase in @(
        @("view_file", [ordered]@{ AbsolutePath = (Join-Path $Workspace "README.md"); toolAction = "Viewing file"; toolSummary = "View file" }, "SAFE_NON_EDIT"),
        @("ViewFile", [ordered]@{ AbsolutePath = (Join-Path $Workspace "README.md") }, "SAFE_NON_EDIT"),
        @("list_dir", [ordered]@{ DirectoryPath = $Workspace; toolAction = "Listing dir"; toolSummary = "List dir" }, "SAFE_NON_EDIT"),
        @("ListDir", [ordered]@{ DirectoryPath = $Workspace }, "SAFE_NON_EDIT"),
        @("ask_question", [ordered]@{ questions = @(@{ question = "Confirm?"; options = @("Yes", "No") }) }, "SAFE_NON_EDIT"),
        @("AskQuestion", [ordered]@{ questions = @() }, "SAFE_NON_EDIT"),
        @("invoke_subagent", [ordered]@{ Subagents = @(@{ Role = "Tester"; Prompt = "Run" }) }, "SAFE_NON_EDIT"),
        @("InvokeSubagent", [ordered]@{ Subagents = @() }, "SAFE_NON_EDIT")
    )) {
        $agPayload = New-AntigravityToolPayload `
            -ToolName $agToolCase[0] `
            -Arguments $agToolCase[1] `
            -Workspace $Workspace
        $agEvent = ConvertTo-AiSopHookEvent `
            -RawPayload (ConvertTo-RawPayload $agPayload) `
            -EventHint "PRE_TOOL_USE" `
            -TrustedWorkspaceRoot $Workspace `
            -AcceptedAt $AcceptedAt
        Assert-Equal $agEvent.toolClass $agToolCase[2] "Antigravity $($agToolCase[0]) tool class mismatch."
    }

    # GLOB path aliases are a strict union: zero or one may be present, never
    # both, even when their values happen to resolve to the same directory.
    $outsideGlobDirectory = Join-Path `
        (Split-Path -Parent $Workspace) "outside-glob"
    $globAliasCases = @(
        [pscustomobject]@{
            Name = "same-value"
            Path = $Workspace
            TargetDirectory = $Workspace
        },
        [pscustomobject]@{
            Name = "different-value"
            Path = $Workspace
            TargetDirectory = (Join-Path $Workspace ".claude")
        },
        [pscustomobject]@{
            Name = "inside-outside"
            Path = $Workspace
            TargetDirectory = $outsideGlobDirectory
        }
    )
    foreach ($globAliasCase in $globAliasCases) {
        $globAliasPayload = New-ClaudeToolPayload `
            -ToolName "Glob" `
            -ToolInput ([ordered]@{
                pattern = "*.ps1"
                path = $globAliasCase.Path
                target_directory = $globAliasCase.TargetDirectory
            }) `
            -Workspace $Workspace -Transcript $Transcript `
            -Occurrence "toolu_glob_alias_$($globAliasCase.Name)"
        $globAliasEvent = ConvertTo-AiSopHookEvent `
            -RawPayload (ConvertTo-RawPayload $globAliasPayload) `
            -EventHint "PRE_TOOL_USE" `
            -TrustedWorkspaceRoot $Workspace `
            -AcceptedAt $AcceptedAt
        Assert-Equal `
            $globAliasEvent.toolClass "UNKNOWN" `
            "GLOB accepted $($globAliasCase.Name) path aliases."
    }
    Assert-ThrowsCode -Code "TOOL_ARGS_INVALID" `
        -Message "GLOB canonicalization silently ignored a second path alias." `
        -Action {
            Get-AiSopCanonicalToolArguments `
                -Arguments ([ordered]@{
                    pattern = "*.ps1"
                    path = $Workspace
                    target_directory = $Workspace
                }) `
                -PolicyEntry ([pscustomobject]@{ ArgumentProfile = "GLOB" }) `
                -WorkspaceContext ([pscustomobject]@{
                    WorkspacePath = $Workspace
                    Cwd = $Workspace
                }) `
                -TargetPaths @()
        }

    $cursorClaimBeforeContext = Convert-Fixture `
        -Name "cursor-claim-before-context.json" `
        -EventHint "PRE_TOOL_USE" -Workspace $Workspace `
        -Transcript $Transcript -AcceptedAt $AcceptedAt
    Assert-Equal `
        $cursorClaimBeforeContext.toolClass "OWNER_REQUIRED" `
        "Cursor pre-context Claim must only be classified OWNER_REQUIRED in Task 2."
    $cursorMismatch = Convert-Fixture `
        -Name "cursor-pre-tool-session-mismatch.json" `
        -EventHint "PRE_TOOL_USE" -Workspace $Workspace `
        -Transcript $Transcript -AcceptedAt $AcceptedAt
    Assert-Equal `
        $cursorMismatch.nativeSessionId "cursor-other-session" `
        "Task 2 must preserve Cursor conversation identity for Task 3."

    # FILE_EDIT collects every target for multi-edit, patch, delete and
    # str_replace_editor families.
    $multiEditPayload = New-ClaudeToolPayload `
        -ToolName "MultiEdit" `
        -ToolInput ([ordered]@{
            edits = @(
                [ordered]@{
                    file_path = (Join-Path $Workspace ".claude\multi-one.txt")
                    old_string = "one"
                    new_string = "ONE"
                },
                [ordered]@{
                    file_path = (Join-Path $Workspace ".claude\multi-two.txt")
                    old_string = "two"
                    new_string = "TWO"
                }
            )
        }) `
        -Workspace $Workspace -Transcript $Transcript `
        -Occurrence "toolu_multi_edit_001"
    $multiEdit = ConvertTo-AiSopHookEvent `
        -RawPayload (ConvertTo-RawPayload $multiEditPayload) `
        -EventHint "PRE_TOOL_USE" -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt
    Assert-Equal $multiEdit.toolClass "FILE_EDIT" "MultiEdit class mismatch."
    Assert-Equal (@($multiEdit.targetPaths).Count) 2 "MultiEdit lost a target."

    $invalidMultiEditPayload = New-ClaudeToolPayload `
        -ToolName "MultiEdit" `
        -ToolInput ([ordered]@{
            edits = @(
                [ordered]@{
                    file_path = (Join-Path $Workspace ".claude\invalid-multi.txt")
                    old_string = 7
                    new_string = "replacement"
                }
            )
        }) `
        -Workspace $Workspace -Transcript $Transcript `
        -Occurrence "toolu_invalid_multi_edit_001"
    $invalidMultiEdit = ConvertTo-AiSopHookEvent `
        -RawPayload (ConvertTo-RawPayload $invalidMultiEditPayload) `
        -EventHint "PRE_TOOL_USE" -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt
    Assert-Equal `
        $invalidMultiEdit.toolClass "UNKNOWN" `
        "A type-drifted MultiEdit must become UNKNOWN."

    $applyPatch = Convert-Fixture `
        -Name "multi-target-apply-patch.json" -EventHint "PRE_TOOL_USE" `
        -Workspace $Workspace -Transcript $Transcript -AcceptedAt $AcceptedAt
    Assert-Equal (@($applyPatch.targetPaths).Count) 2 "ApplyPatch lost a target."

    $endOfFilePatchPayload = Get-FixturePayload `
        -Name "multi-target-apply-patch.json" `
        -Workspace $Workspace -Transcript $Transcript
    $endOfFilePatchPayload.tool_input.patch = (
        $endOfFilePatchPayload.tool_input.patch.Replace(
            "*** End Patch",
            "*** End of File`n*** End Patch"
        )
    )
    $endOfFilePatch = ConvertTo-AiSopHookEvent `
        -RawPayload (ConvertTo-RawPayload $endOfFilePatchPayload) `
        -EventHint "PRE_TOOL_USE" -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt
    Assert-Equal `
        (@($endOfFilePatch.targetPaths).Count) 2 `
        "ApplyPatch rejected its valid End of File marker."

    $delete = Convert-Fixture `
        -Name "delete-target.json" -EventHint "PRE_TOOL_USE" `
        -Workspace $Workspace -Transcript $Transcript -AcceptedAt $AcceptedAt
    Assert-Equal (@($delete.targetPaths).Count) 2 "Delete lost a target."

    $strReplace = Convert-Fixture `
        -Name "str-replace-editor.json" -EventHint "PRE_TOOL_USE" `
        -Workspace $Workspace -Transcript $Transcript -AcceptedAt $AcceptedAt
    Assert-Equal (@($strReplace.targetPaths).Count) 1 "str_replace_editor target missing."

    # Remaining declared FILE_EDIT families each expose every supplied target.
    $fileEditCases = @(
        @("Edit", [ordered]@{
            file_path = (Join-Path $Workspace ".claude\edit.txt")
            old_string = "a"
            new_string = "b"
        }, 1),
        @("Write", [ordered]@{
            file_path = (Join-Path $Workspace ".claude\write.txt")
            content = "write"
        }, 1),
        @("Create", [ordered]@{
            path = (Join-Path $Workspace ".claude\create.txt")
            content = "create"
        }, 1),
        @("NotebookEdit", [ordered]@{
            target_notebook = (Join-Path $Workspace ".claude\book.ipynb")
            cell_idx = 0
            new_string = "cell"
        }, 1)
    )
    foreach ($case in $fileEditCases) {
        $payload = New-ClaudeToolPayload `
            -ToolName $case[0] -ToolInput $case[1] `
            -Workspace $Workspace -Transcript $Transcript `
            -Occurrence ("toolu_" + $case[0].ToLowerInvariant())
        $event = ConvertTo-AiSopHookEvent `
            -RawPayload (ConvertTo-RawPayload $payload) `
            -EventHint "PRE_TOOL_USE" -TrustedWorkspaceRoot $Workspace `
            -AcceptedAt $AcceptedAt
        Assert-Equal $event.toolClass "FILE_EDIT" "$($case[0]) class mismatch."
        Assert-Equal `
            (@($event.targetPaths).Count) $case[2] `
            "$($case[0]) target count mismatch."
    }

    foreach ($case in @(
        @("write_to_file", [ordered]@{
            path = (Join-Path $Workspace ".claude\agy-write.txt")
            content = "write"
        }, 1),
        @("replace_file_content", [ordered]@{
            path = (Join-Path $Workspace ".claude\agy-replace.txt")
            old_string = "a"
            new_string = "b"
        }, 1),
        @("multi_replace_file_content", [ordered]@{
            replacements = @(
                [ordered]@{
                    path = (Join-Path $Workspace ".claude\agy-multi-one.txt")
                    old_string = "a"
                    new_string = "A"
                },
                [ordered]@{
                    path = (Join-Path $Workspace ".claude\agy-multi-two.txt")
                    old_string = "b"
                    new_string = "B"
                }
            )
        }, 2),
        @("edit_file", [ordered]@{
            file_path = (Join-Path $Workspace ".claude\agy-edit.txt")
            old_string = "a"
            new_string = "b"
        }, 1)
    )) {
        $payload = New-AntigravityToolPayload `
            -ToolName $case[0] -Arguments $case[1] -Workspace $Workspace
        $event = ConvertTo-AiSopHookEvent `
            -RawPayload (ConvertTo-RawPayload $payload) `
            -EventHint "PRE_TOOL_USE" -TrustedWorkspaceRoot $Workspace `
            -AcceptedAt $AcceptedAt
        Assert-Equal $event.toolClass "FILE_EDIT" "$($case[0]) class mismatch."
        Assert-Equal `
            (@($event.targetPaths).Count) $case[2] `
            "$($case[0]) target count mismatch."
    }

    $negativeTarget = Join-Path $Workspace ".claude\negative.txt"
    $negativeCases = @(
        @("CLAUDE", "Edit",
            [ordered]@{ file_path = $negativeTarget; new_string = "b" },
            [ordered]@{ file_path = $negativeTarget; old_string = 1; new_string = "b" },
            [ordered]@{ file_path = $negativeTarget; path = $negativeTarget; old_string = "a"; new_string = "b" }),
        @("CLAUDE", "Write",
            [ordered]@{ file_path = $negativeTarget },
            [ordered]@{ file_path = $negativeTarget; content = 1 },
            [ordered]@{ file_path = $negativeTarget; path = $negativeTarget; content = "x" }),
        @("CLAUDE", "Create",
            [ordered]@{ path = $negativeTarget },
            [ordered]@{ path = $negativeTarget; content = 1 },
            [ordered]@{ path = $negativeTarget; file_path = $negativeTarget; content = "x" }),
        @("CLAUDE", "MultiEdit",
            [ordered]@{},
            [ordered]@{ edits = "bad" },
            [ordered]@{ edits = @([ordered]@{
                path = $negativeTarget
                file_path = $negativeTarget
                old_string = "a"
                new_string = "b"
            }) }),
        @("CLAUDE", "NotebookEdit",
            [ordered]@{ target_notebook = $negativeTarget; cell_idx = 0 },
            [ordered]@{ target_notebook = $negativeTarget; cell_idx = "0"; new_string = "x" },
            [ordered]@{
                target_notebook = $negativeTarget
                notebook_path = $negativeTarget
                cell_idx = 0
                new_string = "x"
            }),
        @("CLAUDE", "ApplyPatch",
            [ordered]@{},
            [ordered]@{ patch = 1 },
            [ordered]@{ patch = "*** Begin Patch`n*** End Patch"; input = "*** Begin Patch`n*** End Patch" }),
        @("CLAUDE", "Delete",
            [ordered]@{},
            [ordered]@{ paths = "bad" },
            [ordered]@{ paths = @($negativeTarget); files = @($negativeTarget) }),
        @("COPILOT", "str_replace_editor",
            [ordered]@{ command = "str_replace"; path = $negativeTarget; new_str = "b" },
            [ordered]@{ command = "str_replace"; path = $negativeTarget; old_str = 1; new_str = "b" },
            [ordered]@{
                command = "str_replace"
                path = $negativeTarget
                old_str = "a"
                old_string = "a"
                new_str = "b"
            }),
        @("ANTIGRAVITY", "write_to_file",
            [ordered]@{ path = $negativeTarget },
            [ordered]@{ path = $negativeTarget; content = 1 },
            [ordered]@{ path = $negativeTarget; file_path = $negativeTarget; content = "x" }),
        @("ANTIGRAVITY", "replace_file_content",
            [ordered]@{ path = $negativeTarget; new_string = "b" },
            [ordered]@{ path = $negativeTarget; old_string = 1; new_string = "b" },
            [ordered]@{ path = $negativeTarget; file_path = $negativeTarget; old_string = "a"; new_string = "b" }),
        @("ANTIGRAVITY", "multi_replace_file_content",
            [ordered]@{},
            [ordered]@{ replacements = "bad" },
            [ordered]@{
                replacements = @([ordered]@{
                    path = $negativeTarget
                    old_string = "a"
                    new_string = "b"
                })
                edits = @([ordered]@{
                    path = $negativeTarget
                    old_string = "a"
                    new_string = "b"
                })
            }),
        @("ANTIGRAVITY", "edit_file",
            [ordered]@{ path = $negativeTarget; new_string = "b" },
            [ordered]@{ path = $negativeTarget; old_string = 1; new_string = "b" },
            [ordered]@{ path = $negativeTarget; file_path = $negativeTarget; old_string = "a"; new_string = "b" })
    )
    $negativeAssertionCount = 0
    foreach ($negativeCase in $negativeCases) {
        foreach ($invalidArguments in @(
            $negativeCase[2],
            $negativeCase[3],
            $negativeCase[4]
        )) {
            $negativePayload = switch ($negativeCase[0]) {
                "CLAUDE" {
                    New-ClaudeToolPayload `
                        -ToolName $negativeCase[1] `
                        -ToolInput $invalidArguments `
                        -Workspace $Workspace `
                        -Transcript $Transcript `
                        -Occurrence ("toolu_negative_" + $negativeAssertionCount)
                }
                "COPILOT" {
                    [ordered]@{
                        sessionId = "copilot-session-001"
                        timestamp = 1786953600000
                        cwd = $Workspace
                        toolName = $negativeCase[1]
                        toolArgs = $invalidArguments
                    }
                }
                "ANTIGRAVITY" {
                    New-AntigravityToolPayload `
                        -ToolName $negativeCase[1] `
                        -Arguments $invalidArguments `
                        -Workspace $Workspace
                }
            }
            $negativeEvent = ConvertTo-AiSopHookEvent `
                -RawPayload (ConvertTo-RawPayload $negativePayload) `
                -EventHint "PRE_TOOL_USE" `
                -TrustedWorkspaceRoot $Workspace `
                -AcceptedAt $AcceptedAt
            Assert-Equal `
                $negativeEvent.toolClass "UNKNOWN" `
                "$($negativeCase[1]) accepted missing/type/alias drift."
            $negativeAssertionCount++
        }
    }
    Assert-Equal `
        $negativeAssertionCount 36 `
        "Twelve-family negative matrix did not execute 36 assertions."

    $profileTarget = Join-Path $Workspace ".claude\profile.txt"
    $profileTargetTwo = Join-Path $Workspace ".claude\profile-two.txt"
    $profileContext = [pscustomobject]@{
        WorkspacePath = $Workspace
        Cwd = $Workspace
    }
    $canonicalProfileCases = @(
        @("READ",
            [ordered]@{ file_path = $profileTarget; limit = 5 },
            [ordered]@{ path = $profileTarget; limit = 5 },
            [ordered]@{ path = $profileTarget; limit = 6 },
            @(), @()),
        @("GLOB",
            [ordered]@{ pattern = "*.ps1"; path = $Workspace },
            [ordered]@{ glob_pattern = "*.ps1"; target_directory = $Workspace },
            [ordered]@{ glob_pattern = "*.json"; target_directory = $Workspace },
            @(), @()),
        @("SEARCH",
            [ordered]@{ pattern = "x"; path = $Workspace; "-i" = $false },
            [ordered]@{ query = "x"; path = $Workspace; "-i" = $false },
            [ordered]@{ query = "x"; path = $Workspace; "-i" = $true },
            @(), @()),
        @("ANY_OBJECT",
            [ordered]@{ command = "x"; description = "d" },
            [ordered]@{ description = "d"; command = "x" },
            [ordered]@{ description = "d"; command = "y" },
            @(), @()),
        @("EDIT",
            [ordered]@{ file_path = $profileTarget; old_string = "a"; new_string = "b" },
            [ordered]@{ path = $profileTarget; old_str = "a"; new_str = "b" },
            [ordered]@{ path = $profileTarget; old_str = "a"; new_str = "c" },
            @($profileTarget), @($profileTarget)),
        @("WRITE",
            [ordered]@{ file_path = $profileTarget; content = "a" },
            [ordered]@{ path = $profileTarget; content = "a" },
            [ordered]@{ path = $profileTarget; content = "b" },
            @($profileTarget), @($profileTarget)),
        @("MULTI_EDIT",
            [ordered]@{ file_path = $profileTarget; edits = @([ordered]@{
                old_string = "a"; new_string = "b"
            }) },
            [ordered]@{ path = $profileTarget; edits = @([ordered]@{
                old_str = "a"; new_str = "b"
            }) },
            [ordered]@{ path = $profileTarget; edits = @([ordered]@{
                old_str = "a"; new_str = "c"
            }) },
            @($profileTarget), @($profileTarget)),
        @("NOTEBOOK_EDIT",
            [ordered]@{ target_notebook = $profileTarget; cell_idx = 0; new_string = "a" },
            [ordered]@{ notebook_path = $profileTarget; cell_idx = 0; new_string = "a" },
            [ordered]@{ notebook_path = $profileTarget; cell_idx = 1; new_string = "a" },
            @($profileTarget), @($profileTarget)),
        @("APPLY_PATCH",
            [ordered]@{ patch = "*** Begin Patch`n*** Update File: x`n-a`n+b`n*** End Patch" },
            [ordered]@{ input = "*** Begin Patch`n*** Update File: x`n-a`n+b`n*** End Patch" },
            [ordered]@{ input = "*** Begin Patch`n*** Update File: x`n-a`n+c`n*** End Patch" },
            @($profileTarget), @($profileTarget)),
        @("DELETE",
            [ordered]@{ paths = @($profileTarget, $profileTargetTwo) },
            [ordered]@{ files = @($profileTargetTwo, $profileTarget) },
            [ordered]@{ files = @($profileTarget) },
            @($profileTarget, $profileTargetTwo), @($profileTarget)),
        @("STR_REPLACE_EDITOR",
            [ordered]@{ command = "str_replace"; path = $profileTarget; old_str = "a"; new_str = "b" },
            [ordered]@{ command = "str_replace"; file_path = $profileTarget; old_string = "a"; new_string = "b" },
            [ordered]@{ command = "str_replace"; file_path = $profileTarget; old_string = "a"; new_string = "c" },
            @($profileTarget), @($profileTarget)),
        @("MULTI_REPLACE",
            [ordered]@{ replacements = @([ordered]@{
                path = $profileTarget; old_string = "a"; new_string = "b"
            }) },
            [ordered]@{ edits = @([ordered]@{
                file_path = $profileTarget; old_str = "a"; new_str = "b"
            }) },
            [ordered]@{ edits = @([ordered]@{
                file_path = $profileTarget; old_str = "a"; new_str = "c"
            }) },
            @($profileTarget), @($profileTarget))
    )
    foreach ($profileCase in $canonicalProfileCases) {
        $sameHashOne = Get-CanonicalProfileHash `
            -Profile $profileCase[0] `
            -Arguments $profileCase[1] `
            -WorkspaceContext $profileContext `
            -TargetPaths $profileCase[4]
        $sameHashTwo = Get-CanonicalProfileHash `
            -Profile $profileCase[0] `
            -Arguments $profileCase[2] `
            -WorkspaceContext $profileContext `
            -TargetPaths $profileCase[4]
        $changedHash = Get-CanonicalProfileHash `
            -Profile $profileCase[0] `
            -Arguments $profileCase[3] `
            -WorkspaceContext $profileContext `
            -TargetPaths $profileCase[5]
        Assert-Equal `
            $sameHashOne $sameHashTwo `
            "$($profileCase[0]) split equivalent semantic aliases."
        Assert-True `
            -Condition ($sameHashOne -ne $changedHash) `
            -Message "$($profileCase[0]) merged a single semantic field change."
    }
    Assert-Equal `
        $canonicalProfileCases.Count 12 `
        "Canonical semantic profile matrix is incomplete."

    $badPatchPayload = Get-FixturePayload `
        -Name "multi-target-apply-patch.json" `
        -Workspace $Workspace -Transcript $Transcript
    $badPatchPayload.tool_input.patch = "*** Begin Patch`n*** Update File .claude\bad.txt`n*** End Patch`n"
    Assert-ThrowsCode -Code "EDIT_PATH_AMBIGUOUS" `
        -Message "Malformed ApplyPatch header was accepted." `
        -Action {
            ConvertTo-AiSopHookEvent `
                -RawPayload (ConvertTo-RawPayload $badPatchPayload) `
                -EventHint "PRE_TOOL_USE" -TrustedWorkspaceRoot $Workspace `
                -AcceptedAt $AcceptedAt
        }

    $unknownHeaderPayload = Get-FixturePayload `
        -Name "multi-target-apply-patch.json" `
        -Workspace $Workspace -Transcript $Transcript
    $unknownHeaderPayload.tool_input.patch = @"
*** Begin Patch
*** Update File: .claude\bad.txt
*** Unexpected Header
*** End Patch
"@
    Assert-ThrowsCode -Code "EDIT_PATH_AMBIGUOUS" `
        -Message "Unknown ApplyPatch control header was accepted." `
        -Action {
            ConvertTo-AiSopHookEvent `
                -RawPayload (ConvertTo-RawPayload $unknownHeaderPayload) `
                -EventHint "PRE_TOOL_USE" -TrustedWorkspaceRoot $Workspace `
                -AcceptedAt $AcceptedAt
        }

    $outsidePayload = New-ClaudeToolPayload `
        -ToolName "Delete" `
        -ToolInput ([ordered]@{
            path = (Join-Path (Split-Path -Parent $Workspace) "outside.txt")
        }) `
        -Workspace $Workspace -Transcript $Transcript `
        -Occurrence "toolu_outside_001"
    Assert-ThrowsCode -Code "EDIT_PATH_OUTSIDE_WORKSPACE" `
        -Message "Outside-workspace edit target was accepted." `
        -Action {
            ConvertTo-AiSopHookEvent `
                -RawPayload (ConvertTo-RawPayload $outsidePayload) `
                -EventHint "PRE_TOOL_USE" -TrustedWorkspaceRoot $Workspace `
                -AcceptedAt $AcceptedAt
        }

    # DC-028 preserves canonical lexical targets for Task 3 while semantic
    # target identity is based on the resolved physical paths.
    $safePhysicalDirectory = Join-Path $Workspace ".claude\safe-physical"
    $productionPhysicalDirectory = Join-Path $Workspace "config"
    [System.IO.Directory]::CreateDirectory($safePhysicalDirectory) | Out-Null
    [System.IO.Directory]::CreateDirectory($productionPhysicalDirectory) | Out-Null
    [System.IO.Directory]::CreateDirectory((Join-Path $Workspace "src")) | Out-Null
    $lexicalProductionJunction = Join-Path $Workspace "src\com"
    $lexicalSafeJunction = Join-Path $Workspace ".claude\production-link"
    New-Item `
        -ItemType Junction `
        -Path $lexicalProductionJunction `
        -Target $safePhysicalDirectory | Out-Null
    New-Item `
        -ItemType Junction `
        -Path $lexicalSafeJunction `
        -Target $productionPhysicalDirectory | Out-Null
    $CreatedJunctions = @($lexicalProductionJunction, $lexicalSafeJunction)
    foreach ($junctionCase in @(
        @(
            (Join-Path $lexicalProductionJunction "lexical-production.txt"),
            (Join-Path $safePhysicalDirectory "lexical-production.txt")
        ),
        @(
            (Join-Path $lexicalSafeJunction "physical-production.txt"),
            (Join-Path $productionPhysicalDirectory "physical-production.txt")
        )
    )) {
        $junctionPayload = New-ClaudeToolPayload `
            -ToolName "Edit" `
            -ToolInput ([ordered]@{
                file_path = $junctionCase[0]
                old_string = "before"
                new_string = "after"
            }) `
            -Workspace $Workspace `
            -Transcript $Transcript `
            -Occurrence ("toolu_junction_" + [guid]::NewGuid().ToString("N"))
        $junctionEvent = ConvertTo-AiSopHookEvent `
            -RawPayload (ConvertTo-RawPayload $junctionPayload) `
            -EventHint "PRE_TOOL_USE" `
            -TrustedWorkspaceRoot $Workspace `
            -AcceptedAt $AcceptedAt
        Assert-Equal `
            $junctionEvent.targetPaths[0] `
            ([System.IO.Path]::GetFullPath($junctionCase[0])) `
            "HookEvent did not preserve canonical lexical target identity."
        $expectedPhysicalJson = ConvertTo-AiSopCanonicalJson -Value @(
            ([System.IO.Path]::GetFullPath($junctionCase[1])).ToLowerInvariant()
        )
        Assert-Equal `
            $junctionEvent.canonicalTargetsSha256 `
            (Get-TestSha256Hex $expectedPhysicalJson) `
            "Target hash did not use canonical physical identity."
    }

    $casePathLower = Join-Path $Workspace ".claude\case-target.txt"
    $casePathUpper = $casePathLower.ToUpperInvariant()
    $caseEvents = @(
        foreach ($casePath in @($casePathLower, $casePathUpper)) {
            $casePayload = New-ClaudeToolPayload `
                -ToolName "Edit" `
                -ToolInput ([ordered]@{
                    file_path = $casePath
                    old_string = "a"
                    new_string = "b"
                }) `
                -Workspace $Workspace -Transcript $Transcript `
                -Occurrence "toolu_case_insensitive"
            ConvertTo-AiSopHookEvent `
                -RawPayload (ConvertTo-RawPayload $casePayload) `
                -EventHint "PRE_TOOL_USE" `
                -TrustedWorkspaceRoot $Workspace `
                -AcceptedAt $AcceptedAt
        }
    )
    Assert-Equal `
        $caseEvents[0].canonicalTargetsSha256 `
        $caseEvents[1].canonicalTargetsSha256 `
        "Windows path case changed physical target identity."

    $mixedPayload = New-ClaudeToolPayload `
        -ToolName "MultiEdit" `
        -ToolInput ([ordered]@{ edits = @(
            [ordered]@{
                file_path = (Join-Path $Workspace ".claude\mixed-safe.txt")
                old_string = "a"
                new_string = "b"
            },
            [ordered]@{
                file_path = (Join-Path $Workspace "config\mixed-production.txt")
                old_string = "a"
                new_string = "b"
            }
        ) }) `
        -Workspace $Workspace -Transcript $Transcript `
        -Occurrence "toolu_mixed_targets"
    $mixedEvent = ConvertTo-AiSopHookEvent `
        -RawPayload (ConvertTo-RawPayload $mixedPayload) `
        -EventHint "PRE_TOOL_USE" `
        -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt
    Assert-Equal `
        @($mixedEvent.targetPaths).Count 2 `
        "Mixed production/non-production edit lost a target."

    $rootA = Join-Path $Workspace "root-a"
    $rootB = Join-Path $Workspace "root-b"
    [System.IO.Directory]::CreateDirectory($rootA) | Out-Null
    [System.IO.Directory]::CreateDirectory($rootB) | Out-Null
    $multiRootPayload = Get-FixturePayload `
        -Name "cursor-pre-tool-edit.json" `
        -Workspace $Workspace -Transcript $Transcript
    $multiRootPayload.cwd = $rootA
    $multiRootPayload.workspace_roots = @($rootA, $rootB)
    $multiRootPayload.tool_input.file_path = Join-Path $rootB "target.txt"
    $multiRootEvent = ConvertTo-AiSopHookEvent `
        -RawPayload (ConvertTo-RawPayload $multiRootPayload) `
        -EventHint "PRE_TOOL_USE" `
        -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt
    Assert-Equal `
        @($multiRootEvent.workspaceRoots).Count 2 `
        "Valid disjoint multi-root context was not preserved."

    # Canonical semantics must neither merge behavioral changes nor split
    # equivalent aliases/set orderings.
    $searchBasePayload = New-ClaudeToolPayload `
        -ToolName "Grep" `
        -ToolInput ([ordered]@{
            pattern = "needle"
            path = $Workspace
            "-i" = $false
            head_limit = 10
        }) `
        -Workspace $Workspace `
        -Transcript $Transcript `
        -Occurrence "toolu_semantic_search_001"
    $searchChangedPayload = $searchBasePayload |
        ConvertTo-Json -Depth 100 |
        ConvertFrom-Json -AsHashtable -Depth 100
    $searchChangedPayload.tool_input["-i"] = $true
    $searchBase = ConvertTo-AiSopHookEvent `
        -RawPayload (ConvertTo-RawPayload $searchBasePayload) `
        -EventHint "PRE_TOOL_USE" -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt
    $searchChanged = ConvertTo-AiSopHookEvent `
        -RawPayload (ConvertTo-RawPayload $searchChangedPayload) `
        -EventHint "PRE_TOOL_USE" -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt
    Assert-True `
        -Condition (
            $searchBase.canonicalSemanticArgsSha256 -ne
            $searchChanged.canonicalSemanticArgsSha256
        ) `
        -Message "A behavioral Search field change was merged."
    Assert-True `
        -Condition ($searchBase.dedupKey -ne $searchChanged.dedupKey) `
        -Message "A behavioral Search field change reused the dedup key."

    $deleteAliasOne = New-ClaudeToolPayload `
        -ToolName "Delete" `
        -ToolInput ([ordered]@{
            paths = @(
                (Join-Path $Workspace ".claude\same-a.txt"),
                (Join-Path $Workspace ".claude\same-b.txt")
            )
        }) `
        -Workspace $Workspace -Transcript $Transcript `
        -Occurrence "toolu_semantic_delete_001"
    $deleteAliasTwo = New-ClaudeToolPayload `
        -ToolName "Delete" `
        -ToolInput ([ordered]@{
            files = @(
                (Join-Path $Workspace ".claude\same-b.txt"),
                (Join-Path $Workspace ".claude\same-a.txt")
            )
        }) `
        -Workspace $Workspace -Transcript $Transcript `
        -Occurrence "toolu_semantic_delete_001"
    $deleteOneEvent = ConvertTo-AiSopHookEvent `
        -RawPayload (ConvertTo-RawPayload $deleteAliasOne) `
        -EventHint "PRE_TOOL_USE" -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt
    $deleteTwoEvent = ConvertTo-AiSopHookEvent `
        -RawPayload (ConvertTo-RawPayload $deleteAliasTwo) `
        -EventHint "PRE_TOOL_USE" -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt
    Assert-Equal `
        $deleteOneEvent.canonicalSemanticArgsSha256 `
        $deleteTwoEvent.canonicalSemanticArgsSha256 `
        "Equivalent Delete aliases/orderings split semantic identity."
    Assert-Equal `
        $deleteOneEvent.dedupKey `
        $deleteTwoEvent.dedupKey `
        "Equivalent Delete aliases/orderings split dedup identity."

    $editDefaultPayloads = @(
        [ordered]@{
            file_path = (Join-Path $Workspace ".claude\default-edit.txt")
            old_string = "a"
            new_string = "b"
        },
        [ordered]@{
            file_path = (Join-Path $Workspace ".claude\default-edit.txt")
            old_string = "a"
            new_string = "b"
            replace_all = $false
        }
    )
    $editDefaultEvents = @(
        foreach ($arguments in $editDefaultPayloads) {
            $payload = New-ClaudeToolPayload `
                -ToolName "Edit" -ToolInput $arguments `
                -Workspace $Workspace -Transcript $Transcript `
                -Occurrence "toolu_edit_default_equivalence"
            ConvertTo-AiSopHookEvent `
                -RawPayload (ConvertTo-RawPayload $payload) `
                -EventHint "PRE_TOOL_USE" `
                -TrustedWorkspaceRoot $Workspace `
                -AcceptedAt $AcceptedAt
        }
    )
    Assert-Equal `
        $editDefaultEvents[0].canonicalSemanticArgsSha256 `
        $editDefaultEvents[1].canonicalSemanticArgsSha256 `
        "Edit absent replace_all differs from explicit false."
    Assert-Equal `
        $editDefaultEvents[0].dedupKey `
        $editDefaultEvents[1].dedupKey `
        "Edit default-equivalent payloads have different dedup keys."

    $searchDefaultPayloads = @(
        [ordered]@{ pattern = "needle"; path = $Workspace },
        [ordered]@{
            pattern = "needle"
            path = $Workspace
            output_mode = "content"
            "-A" = 0
            "-B" = 0
            "-C" = 0
            "-i" = $false
            offset = 0
            multiline = $false
        }
    )
    $searchDefaultEvents = @(
        foreach ($arguments in $searchDefaultPayloads) {
            $payload = New-ClaudeToolPayload `
                -ToolName "Grep" -ToolInput $arguments `
                -Workspace $Workspace -Transcript $Transcript `
                -Occurrence "toolu_search_default_equivalence"
            ConvertTo-AiSopHookEvent `
                -RawPayload (ConvertTo-RawPayload $payload) `
                -EventHint "PRE_TOOL_USE" `
                -TrustedWorkspaceRoot $Workspace `
                -AcceptedAt $AcceptedAt
        }
    )
    Assert-Equal `
        $searchDefaultEvents[0].dedupKey `
        $searchDefaultEvents[1].dedupKey `
        "Search absent defaults differ from explicit defaults."

    $patchContainerBase = [string]::Join(
        "`n",
        @(
            "*** Begin Patch",
            "*** Update File: .claude\container.txt",
            "-old",
            "+new",
            "*** End Patch"
        )
    )
    $patchContainerVariants = @(
        $patchContainerBase,
        "$patchContainerBase`n",
        "$patchContainerBase`n`n`n",
        ($patchContainerBase.Replace("`n", "`r`n") + "`r`n"),
        "$patchContainerBase`n `t`n"
    )
    $patchContainerEvents = @(
        foreach ($patchText in $patchContainerVariants) {
            $payload = New-ClaudeToolPayload `
                -ToolName "ApplyPatch" `
                -ToolInput ([ordered]@{ patch = $patchText }) `
                -Workspace $Workspace -Transcript $Transcript `
                -Occurrence "toolu_patch_container_eol"
            ConvertTo-AiSopHookEvent `
                -RawPayload (ConvertTo-RawPayload $payload) `
                -EventHint "PRE_TOOL_USE" `
                -TrustedWorkspaceRoot $Workspace `
                -AcceptedAt $AcceptedAt
        }
    )
    foreach ($patchContainerEvent in $patchContainerEvents) {
        Assert-Equal `
            $patchContainerEvent.canonicalSemanticArgsSha256 `
            $patchContainerEvents[0].canonicalSemanticArgsSha256 `
            "ApplyPatch container trailing whitespace changed semantic hash."
        Assert-Equal `
            $patchContainerEvent.dedupKey `
            $patchContainerEvents[0].dedupKey `
            "ApplyPatch container trailing whitespace changed dedup key."
    }
    $patchWithInternalBlank = $patchContainerBase.Replace(
        "-old`n+new",
        "-old`n`n+new"
    )
    $internalBlankPayload = New-ClaudeToolPayload `
        -ToolName "ApplyPatch" `
        -ToolInput ([ordered]@{ patch = $patchWithInternalBlank }) `
        -Workspace $Workspace -Transcript $Transcript `
        -Occurrence "toolu_patch_container_eol"
    $internalBlankEvent = ConvertTo-AiSopHookEvent `
        -RawPayload (ConvertTo-RawPayload $internalBlankPayload) `
        -EventHint "PRE_TOOL_USE" `
        -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt
    Assert-True `
        -Condition (
            $internalBlankEvent.canonicalSemanticArgsSha256 -ne
            $patchContainerEvents[0].canonicalSemanticArgsSha256
        ) `
        -Message "ApplyPatch discarded a semantic section-internal blank line."
    Assert-True `
        -Condition (
            $internalBlankEvent.dedupKey -ne
            $patchContainerEvents[0].dedupKey
        ) `
        -Message "ApplyPatch merged a section-internal blank-line change."

    $patchOne = @"
*** Begin Patch
*** Update File: .claude\b.txt
-old
+ONE
*** Update File: .claude\a.txt
-old
+TWO
*** End Patch
"@
    $patchTwo = @"
*** Begin Patch
*** Update File: .claude\a.txt
-old
+ONE
*** Update File: .claude\b.txt
-old
+TWO
*** End Patch
"@
    $patchBindingEvents = @(
        foreach ($patchText in @($patchOne, $patchTwo)) {
            $payload = New-ClaudeToolPayload `
                -ToolName "ApplyPatch" `
                -ToolInput ([ordered]@{ patch = $patchText }) `
                -Workspace $Workspace -Transcript $Transcript `
                -Occurrence "toolu_patch_binding"
            ConvertTo-AiSopHookEvent `
                -RawPayload (ConvertTo-RawPayload $payload) `
                -EventHint "PRE_TOOL_USE" `
                -TrustedWorkspaceRoot $Workspace `
                -AcceptedAt $AcceptedAt
        }
    )
    Assert-True `
        -Condition (
            $patchBindingEvents[0].canonicalSemanticArgsSha256 -ne
            $patchBindingEvents[1].canonicalSemanticArgsSha256
        ) `
        -Message "ApplyPatch lost physical path-to-body binding."
    Assert-True `
        -Condition ($patchBindingEvents[0].dedupKey -ne $patchBindingEvents[1].dedupKey) `
        -Message "Different ApplyPatch bindings reused one dedup key."

    $samePathForwardPatch = @"
*** Begin Patch
*** Update File: .claude\same-dependent.txt
-a
+b
*** Update File: .claude\same-dependent.txt
-b
+c
*** End Patch
"@
    $samePathReversePatch = @"
*** Begin Patch
*** Update File: .claude\same-dependent.txt
-b
+c
*** Update File: .claude\same-dependent.txt
-a
+b
*** End Patch
"@
    foreach ($samePathPatch in @(
        $samePathForwardPatch,
        $samePathReversePatch
    )) {
        $samePathPayload = New-ClaudeToolPayload `
            -ToolName "ApplyPatch" `
            -ToolInput ([ordered]@{ patch = $samePathPatch }) `
            -Workspace $Workspace -Transcript $Transcript `
            -Occurrence "toolu_same_path_patch"
        Assert-ThrowsCode -Code "TOOL_ARGS_INVALID" `
            -Message "ApplyPatch accepted duplicate physical path headers." `
            -Action {
                ConvertTo-AiSopHookEvent `
                    -RawPayload (ConvertTo-RawPayload $samePathPayload) `
                    -EventHint "PRE_TOOL_USE" `
                    -TrustedWorkspaceRoot $Workspace `
                    -AcceptedAt $AcceptedAt
            }
    }

    $cursorNotebookBase = Get-FixturePayload `
        -Name "cursor-pre-tool-edit.json" `
        -Workspace $Workspace -Transcript $Transcript
    $cursorNotebookBase.tool_name = "EditNotebook"
    $cursorNotebookBase.tool_input = [ordered]@{
        target_notebook = (Join-Path $Workspace ".claude\strict.ipynb")
        cell_idx = 0
        is_new_cell = $false
        cell_language = "python"
        old_string = "before"
        new_string = "after"
    }
    $cursorNotebookEvent = ConvertTo-AiSopHookEvent `
        -RawPayload (ConvertTo-RawPayload $cursorNotebookBase) `
        -EventHint "PRE_TOOL_USE" -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt
    Assert-Equal `
        $cursorNotebookEvent.toolClass "FILE_EDIT" `
        "Certified Cursor EditNotebook shape was rejected."
    foreach ($requiredNotebookField in @(
        "is_new_cell",
        "cell_language",
        "old_string",
        "new_string"
    )) {
        $missingNotebook = $cursorNotebookBase |
            ConvertTo-Json -Depth 100 |
            ConvertFrom-Json -AsHashtable -Depth 100
        $missingNotebook.tool_input.Remove($requiredNotebookField)
        $missingNotebookEvent = ConvertTo-AiSopHookEvent `
            -RawPayload (ConvertTo-RawPayload $missingNotebook) `
            -EventHint "PRE_TOOL_USE" -TrustedWorkspaceRoot $Workspace `
            -AcceptedAt $AcceptedAt
        Assert-Equal `
            $missingNotebookEvent.toolClass "UNKNOWN" `
            "Cursor EditNotebook accepted missing $requiredNotebookField."
    }
    $invalidNewNotebook = $cursorNotebookBase |
        ConvertTo-Json -Depth 100 |
        ConvertFrom-Json -AsHashtable -Depth 100
    $invalidNewNotebook.tool_input.is_new_cell = $true
    $invalidNewNotebook.tool_input.old_string = "must-be-empty"
    $invalidNewNotebookEvent = ConvertTo-AiSopHookEvent `
        -RawPayload (ConvertTo-RawPayload $invalidNewNotebook) `
        -EventHint "PRE_TOOL_USE" -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt
    Assert-Equal `
        $invalidNewNotebookEvent.toolClass "UNKNOWN" `
        "New-cell EditNotebook accepted a non-empty old_string."

    $deadlineScavengeDirectory = Join-Path $TestRoot "deadline-scavenge"
    [System.IO.Directory]::CreateDirectory($deadlineScavengeDirectory) | Out-Null
    foreach ($index in 1..32) {
        [System.IO.File]::WriteAllText(
            (Join-Path $deadlineScavengeDirectory "$index.json"),
            (@{ expiresAt = $AcceptedAt.AddSeconds(-1).ToString("o") } |
                ConvertTo-Json -Compress)
        )
    }
    $deadlineStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Assert-ThrowsCode -Code "REGISTRY_DEADLINE_EXCEEDED" `
        -Message "Scavenger ignored an exhausted shared deadline." `
        -Action {
            Invoke-AiSopHookRegistryScavenge `
                -Directory $deadlineScavengeDirectory `
                -NowUtc $AcceptedAt `
                -DeadlineUtc ([DateTimeOffset]::UtcNow.AddMilliseconds(1))
        }
    $deadlineStopwatch.Stop()
    Assert-True `
        -Condition ($deadlineStopwatch.ElapsedMilliseconds -le 750) `
        -Message "Scavenger deadline failure exceeded 750ms."

    # Command-union and notebook profiles deny incomplete calls instead of
    # treating a path alone as a certified FILE_EDIT invocation.
    foreach ($incompleteCase in @(
        @("Create", [ordered]@{
            path = (Join-Path $Workspace ".claude\path-only-create.txt")
        }),
        @("NotebookEdit", [ordered]@{
            target_notebook = (Join-Path $Workspace ".claude\path-only.ipynb")
        })
    )) {
        $incompletePayload = New-ClaudeToolPayload `
            -ToolName $incompleteCase[0] `
            -ToolInput $incompleteCase[1] `
            -Workspace $Workspace -Transcript $Transcript `
            -Occurrence ("toolu_incomplete_" + $incompleteCase[0])
        $incompleteEvent = ConvertTo-AiSopHookEvent `
            -RawPayload (ConvertTo-RawPayload $incompletePayload) `
            -EventHint "PRE_TOOL_USE" -TrustedWorkspaceRoot $Workspace `
            -AcceptedAt $AcceptedAt
        Assert-Equal `
            $incompleteEvent.toolClass "UNKNOWN" `
            "$($incompleteCase[0]) accepted a path-only edit."
    }
    $pathOnlyStrReplacePayload = [ordered]@{
        sessionId = "copilot-session-001"
        timestamp = 1786953600000
        cwd = $Workspace
        toolName = "str_replace_editor"
        toolArgs = [ordered]@{
            command = "create"
            path = (Join-Path $Workspace ".claude\path-only-str-create.txt")
        }
    }
    $pathOnlyStrReplace = ConvertTo-AiSopHookEvent `
        -RawPayload (ConvertTo-RawPayload $pathOnlyStrReplacePayload) `
        -EventHint "PRE_TOOL_USE" -TrustedWorkspaceRoot $Workspace `
        -AcceptedAt $AcceptedAt
    Assert-Equal `
        $pathOnlyStrReplace.toolClass "UNKNOWN" `
        "str_replace_editor create accepted a path-only edit."

    Write-Output "All hook event normalizer tests passed."
} finally {
    if ($null -eq $PreviousDedupRegistry) {
        Remove-Item Env:SERVER_NEW_HOOK_DEDUP_REGISTRY -ErrorAction SilentlyContinue
    } else {
        $env:SERVER_NEW_HOOK_DEDUP_REGISTRY = $PreviousDedupRegistry
    }
    foreach ($junction in $CreatedJunctions) {
        if (Test-Path -LiteralPath $junction) {
            [System.IO.Directory]::Delete($junction)
        }
    }
    if (Test-Path -LiteralPath $TestRoot) {
        [System.IO.Directory]::Delete($TestRoot, $true)
    }
}
