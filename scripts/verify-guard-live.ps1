#requires -Version 7.0

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$ScriptsRoot = $PSScriptRoot
$DispatcherScript = Join-Path $ScriptsRoot "hook-dispatcher.ps1"
$OwnerScript = Join-Path $ScriptsRoot "workflow-owner.ps1"
$ClaudeRoot = Split-Path -Parent $ScriptsRoot
$WorkspaceRoot = Split-Path -Parent $ClaudeRoot
$ProbeRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "guard-live-" + [guid]::NewGuid().ToString("N")
)
$ProbeSuffix = [guid]::NewGuid().ToString("N").Substring(0, 12)
$Feature = "GuardLiveProbe$ProbeSuffix"
$OwnerId = "guard-live-$ProbeSuffix"
$FeatureSpecDir = Join-Path $ClaudeRoot "specs\features\$Feature"
$RegistryVariables = @(
    "SERVER_NEW_WORKFLOW_REGISTRY",
    "SERVER_NEW_WORKFLOW_SESSION_REGISTRY",
    "SERVER_NEW_WORKFLOW_COMMAND_GRANT_REGISTRY",
    "SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY",
    "SERVER_NEW_HOOK_DEDUP_REGISTRY",
    "SERVER_NEW_HOOK_CORRELATION_REGISTRY",
    "SERVER_NEW_SKIP_OWNER_GUARD"
)
$SavedEnvironment = @{}

function Assert-LiveProbe {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function ConvertTo-LiveJson {
    param([object]$Value)

    return $Value | ConvertTo-Json -Compress -Depth 40
}

function Invoke-LiveDispatch {
    param(
        [string]$RawPayload,
        [string]$EventHint,
        [DateTimeOffset]$AcceptedAt
    )

    return Invoke-AiSopHookDispatcher `
        -RawPayload $RawPayload `
        -EventHint $EventHint `
        -TrustedWorkspaceRoot $WorkspaceRoot `
        -AcceptedAt $AcceptedAt
}

function New-LiveCursorPayload {
    param(
        [ValidateSet("START", "TOOL")]
        [string]$Kind,
        [string]$SessionId,
        [string]$ToolName = "",
        [hashtable]$ToolInput = @{},
        [string]$Occurrence = "live"
    )

    if ($Kind -eq "START") {
        return ConvertTo-LiveJson ([ordered]@{
            session_id = $SessionId
            is_background_agent = $false
            composer_mode = "agent"
        })
    }
    return ConvertTo-LiveJson ([ordered]@{
        conversation_id = $SessionId
        generation_id = "generation-$Occurrence"
        hook_event_name = "preToolUse"
        workspace_roots = @($WorkspaceRoot)
        tool_name = $ToolName
        tool_input = $ToolInput
        tool_use_id = "tool-$Occurrence"
        cwd = $WorkspaceRoot
    })
}

function New-LiveOwnerCommand {
    param([string]$Operation)

    return (
        "pwsh -NoProfile -File '.\.ai-sop\scripts\workflow-owner.ps1' " +
        "-Operation '$Operation' " +
        "-SpecDirectory '.claude\specs\features\$Feature' " +
        "-Feature '$Feature' " +
        "-Workflow 'SUPERPOWERS' " +
        "-Agent 'CURSOR' " +
        "-OwnerId '$OwnerId'"
    )
}

try {
    foreach ($name in $RegistryVariables) {
        $SavedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    $env:SERVER_NEW_WORKFLOW_REGISTRY = Join-Path $ProbeRoot "owners"
    $env:SERVER_NEW_WORKFLOW_SESSION_REGISTRY = Join-Path $ProbeRoot "sessions"
    $env:SERVER_NEW_WORKFLOW_COMMAND_GRANT_REGISTRY =
        Join-Path $ProbeRoot "grants"
    $env:SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY =
        Join-Path $ProbeRoot "transactions"
    $env:SERVER_NEW_HOOK_DEDUP_REGISTRY = Join-Path $ProbeRoot "dedup"
    $env:SERVER_NEW_HOOK_CORRELATION_REGISTRY =
        Join-Path $ProbeRoot "correlation"
    Remove-Item Env:SERVER_NEW_SKIP_OWNER_GUARD -ErrorAction SilentlyContinue

    [System.IO.Directory]::CreateDirectory($FeatureSpecDir) | Out-Null
    . $DispatcherScript
    $now = [DateTimeOffset]::UtcNow
    $sessionId = "cursor-live-$ProbeSuffix"

    $start = Invoke-LiveDispatch `
        -RawPayload (
            New-LiveCursorPayload -Kind START -SessionId $sessionId
        ) `
        -EventHint SESSION_START `
        -AcceptedAt $now
    Assert-LiveProbe ($start.Decision -eq "ALLOW") (
        "Cursor live lifecycle registration failed: $($start.ReasonCode)"
    )

    $claimCommand = New-LiveOwnerCommand -Operation Claim
    $claimHook = Invoke-LiveDispatch `
        -RawPayload (
            New-LiveCursorPayload `
                -Kind TOOL `
                -SessionId $sessionId `
                -ToolName Shell `
                -ToolInput @{ command = $claimCommand } `
                -Occurrence "claim"
        ) `
        -EventHint PRE_TOOL_USE `
        -AcceptedAt $now.AddMilliseconds(100)
    Assert-LiveProbe (
        $claimHook.Decision -eq "ALLOW" -and
        $claimHook.ReasonCode -eq "COMMAND_GRANT_ISSUED"
    ) "Isolated Owner 1.1 Claim grant was not issued."

    & $OwnerScript `
        -Operation Claim `
        -SpecDirectory $FeatureSpecDir `
        -Feature $Feature `
        -Workflow SUPERPOWERS `
        -Agent CURSOR `
        -OwnerId $OwnerId |
        Out-Null
    $ownerPath = Join-Path (
        $env:SERVER_NEW_WORKFLOW_REGISTRY
    ) ($Feature.ToLowerInvariant() + ".json")
    $owner = [System.IO.File]::ReadAllText($ownerPath) | ConvertFrom-Json
    Assert-LiveProbe (
        $owner.schemaVersion -eq "1.1" -and
        $owner.status -eq "ACTIVE" -and
        $owner.sessionBinding.sessionKey -eq $start.SessionKey
    ) "Live probe did not create an exact isolated Owner 1.1."

    $production = Invoke-LiveDispatch `
        -RawPayload (
            New-LiveCursorPayload `
                -Kind TOOL `
                -SessionId $sessionId `
                -ToolName Edit `
                -ToolInput @{
                    file_path = (
                        Join-Path $WorkspaceRoot "src\com\GuardLiveProbe.java"
                    )
                    old_string = "before"
                    new_string = "after"
                } `
                -Occurrence "production"
        ) `
        -EventHint PRE_TOOL_USE `
        -AcceptedAt $now.AddMilliseconds(200)
    Assert-LiveProbe (
        $production.Decision -eq "ALLOW" -and
        $production.ReasonCode -eq "EXACT_OWNER_AUTHORIZED"
    ) "Exact isolated Owner 1.1 did not authorize production FILE_EDIT."

    $shell = Invoke-LiveDispatch `
        -RawPayload (
            New-LiveCursorPayload `
                -Kind TOOL `
                -SessionId $sessionId `
                -ToolName Shell `
                -ToolInput @{ command = "Get-Location" } `
                -Occurrence "shell"
        ) `
        -EventHint PRE_TOOL_USE `
        -AcceptedAt $now.AddMilliseconds(300)
    Assert-LiveProbe (
        $shell.Decision -eq "ALLOW" -and
        $shell.ReasonCode -eq "EXACT_OWNER_AUTHORIZED"
    ) "Exact isolated Owner 1.1 did not authorize OWNER_REQUIRED."

    $unknown = Invoke-LiveDispatch `
        -RawPayload (
            New-LiveCursorPayload `
                -Kind TOOL `
                -SessionId $sessionId `
                -ToolName unknown_live_tool `
                -ToolInput @{} `
                -Occurrence "unknown"
        ) `
        -EventHint PRE_TOOL_USE `
        -AcceptedAt $now.AddMilliseconds(400)
    Assert-LiveProbe ($unknown.Decision -eq "DENY") (
        "UNKNOWN live tool unexpectedly allowed."
    )

    $malformed = Invoke-LiveDispatch `
        -RawPayload "{" `
        -EventHint PRE_TOOL_USE `
        -AcceptedAt $now.AddMilliseconds(500)
    Assert-LiveProbe ($malformed.Decision -eq "DENY") (
        "Malformed live payload unexpectedly allowed."
    )

    $perfSession = "cursor-live-perf-$ProbeSuffix"
    Invoke-LiveDispatch `
        -RawPayload (
            New-LiveCursorPayload -Kind START -SessionId $perfSession
        ) `
        -EventHint SESSION_START `
        -AcceptedAt $now.AddSeconds(1) |
        Out-Null
    $samples = @()
    foreach ($index in 1..20) {
        $watch = [System.Diagnostics.Stopwatch]::StartNew()
        $result = Invoke-LiveDispatch `
            -RawPayload (
                New-LiveCursorPayload `
                    -Kind TOOL `
                    -SessionId $perfSession `
                    -ToolName Edit `
                    -ToolInput @{
                        file_path = (
                            Join-Path $WorkspaceRoot (
                                ".claude\live-perf-$index.tmp"
                            )
                        )
                        old_string = "before"
                        new_string = "after"
                    } `
                    -Occurrence "perf-$index"
            ) `
            -EventHint PRE_TOOL_USE `
            -AcceptedAt $now.AddSeconds(1 + $index)
        $watch.Stop()
        Assert-LiveProbe ($result.Decision -eq "ALLOW") (
            "Normal live performance fixture was denied."
        )
        $samples += $watch.ElapsedMilliseconds
    }
    $orderedSamples = @($samples | Sort-Object)
    $normalPathMaxMs = ($samples | Measure-Object -Maximum).Maximum
    $p50 = $orderedSamples[[Math]::Floor(($orderedSamples.Count - 1) * 0.50)]
    $p95 = $orderedSamples[[Math]::Floor(($orderedSamples.Count - 1) * 0.95)]
    Assert-LiveProbe ($normalPathMaxMs -lt 1000) (
        "Normal live path exceeded 1000ms: ${normalPathMaxMs}ms."
    )

    $completeCommand = New-LiveOwnerCommand -Operation Complete
    $completeHook = Invoke-LiveDispatch `
        -RawPayload (
            New-LiveCursorPayload `
                -Kind TOOL `
                -SessionId $sessionId `
                -ToolName Shell `
                -ToolInput @{ command = $completeCommand } `
                -Occurrence "complete"
        ) `
        -EventHint PRE_TOOL_USE `
        -AcceptedAt ([DateTimeOffset]::UtcNow)
    Assert-LiveProbe (
        $completeHook.Decision -eq "ALLOW" -and
        $completeHook.ReasonCode -eq "COMMAND_GRANT_ISSUED"
    ) "Isolated Owner Complete grant was not issued."
    & $OwnerScript `
        -Operation Complete `
        -SpecDirectory $FeatureSpecDir `
        -Feature $Feature `
        -Workflow SUPERPOWERS `
        -Agent CURSOR `
        -OwnerId $OwnerId |
        Out-Null

    [pscustomobject][ordered]@{
        result = "PASS"
        ownerSchemaVersion = "1.1"
        ownerRegistryIsolated = $true
        currentOwner1_0UsedForAuthorization = $false
        sampleCount = $samples.Count
        p50Ms = $p50
        p95Ms = $p95
        normalPathMaxMs = $normalPathMaxMs
        configuredTimeoutMs = 5000
        concern = (
            "This script validates the installed dispatcher and native " +
            "envelopes in-process. Product-host timeout behavior remains a " +
            "separate exact-version certification concern."
        )
    } | ConvertTo-Json -Depth 10
    exit 0
} catch {
    [pscustomobject][ordered]@{
        result = "FAIL"
        errorCode = if (
            $_.Exception.Message -match "^[A-Z][A-Z0-9_]*$"
        ) {
            $_.Exception.Message
        } else {
            "LIVE_PROBE_FAILED"
        }
        errorMessage = $_.Exception.Message
    } | ConvertTo-Json -Depth 10
    exit 1
} finally {
    foreach ($name in $RegistryVariables) {
        $saved = $SavedEnvironment[$name]
        if ($null -eq $saved) {
            Remove-Item "Env:$name" -ErrorAction SilentlyContinue
        } else {
            Set-Item "Env:$name" -Value $saved
        }
    }
    if (Test-Path -LiteralPath $FeatureSpecDir) {
        [System.IO.Directory]::Delete($FeatureSpecDir, $true)
    }
    if (Test-Path -LiteralPath $ProbeRoot) {
        [System.IO.Directory]::Delete($ProbeRoot, $true)
    }
}
