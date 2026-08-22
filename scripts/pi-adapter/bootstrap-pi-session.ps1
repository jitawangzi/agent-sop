#requires -Version 7.0
# PiAdapterP1 — minimal PI session bootstrap.
# Drives the exact same security model as the other four harnesses:
#   1. Register a PI session (CONFIRMED) via Invoke-AiSopWorkflowSession.
#   2. Issue an AST-validated command grant for the canonical owner command.
# The caller (a Pi extension or a human) then runs workflow-owner.ps1, which
# consumes the grant exactly as the four harnesses do. This script writes no
# secrets, performs no authorization, and does not bypass dedup/policy.
#
# Usage:
#   pwsh -NoProfile -File ./.claude/scripts/pi-adapter/bootstrap-pi-session.ps1 `
#     -SpecDirectory ".claude/specs/features/PiAdapterP1" `
#     -Feature PiAdapterP1 -Workflow SUPERPOWERS -Agent PI `
#     -OwnerId "pi-adapter-0001" -NativeSessionId "<pi-native-session-id>" `
#     -OwnerOperation Claim -WorkspaceRoot . -OutputFormat Json

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SpecDirectory,

    [Parameter(Mandatory)]
    [string]$Feature,

    [Parameter(Mandatory)]
    [ValidateSet("CUSTOM_SKILLS", "SUPERPOWERS")]
    [string]$Workflow,

    [Parameter(Mandatory)]
    [ValidateSet("PI")]
    [string]$Agent,

    [Parameter(Mandatory)]
    [ValidatePattern("^[A-Za-z0-9._:-]+$")]
    [string]$OwnerId,

    [Parameter(Mandatory)]
    [ValidateNotNullOrEmpty()]
    [string]$NativeSessionId,

    [Parameter(Mandatory)]
    [ValidateSet("Claim", "BindSession", "RebindSession", "Validate", "Complete")]
    [string]$OwnerOperation,

    [string]$WorkspaceRoot = ".",

    # Grant consumption window (seconds) for the issued owner command.
    # Default 60: enough for a separate tool-call or human paste between
    # bootstrap (issue) and workflow-owner.ps1 (consume). Other harnesses
    # consume synchronously and keep the 10s default in workflow-command-grant.
    [int]$GrantTtlSeconds = 60,

    [ValidateSet("Json", "Text")]
    [string]$OutputFormat = "Text"
)

$ErrorActionPreference = "Stop"

$ClaudeRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $ClaudeRoot "scripts\path-identity.ps1")
. (Join-Path $ClaudeRoot "scripts\workflow-transaction.ps1")
. (Join-Path $ClaudeRoot "scripts\workflow-session.ps1")
. (Join-Path $ClaudeRoot "scripts\workflow-command-grant.ps1")

$ResolvedSpecDirectory = Resolve-PhysicalPathIdentity -Path $SpecDirectory
$ResolvedWorkspace = Resolve-PhysicalPathIdentity -Path $WorkspaceRoot

$AcceptedAt = [DateTimeOffset]::UtcNow
# DeadlineUtc caps how long the bootstrap script itself may run (session
# register/touch + possibly an in-place rebind that re-runs workflow-owner.ps1).
# It must be longer than GrantTtlSeconds; the grant's own consumption window is
# controlled separately by GrantTtlSeconds at issue time.
$DeadlineUtc = $AcceptedAt.AddSeconds($GrantTtlSeconds + 60)

$OwnerRegistryRoot = Join-Path $env:LOCALAPPDATA "AIWorkflowOwners\server_new"
if (-not [string]::IsNullOrWhiteSpace($env:SERVER_NEW_WORKFLOW_REGISTRY)) {
    $OwnerRegistryRoot = [System.IO.Path]::GetFullPath($env:SERVER_NEW_WORKFLOW_REGISTRY)
}
$ownerPath = Join-Path $OwnerRegistryRoot ($Feature.ToLowerInvariant() + ".json")

# Canonical owner command, identical shape to the other harnesses (single-quoted
# literal values, no variables/pipes/redirects) so the grant AST validator passes.
$CommandText = (
    "pwsh -NoProfile -File '.\.ai-sop\scripts\workflow-owner.ps1' " +
    "-Operation '$OwnerOperation' " +
    "-SpecDirectory '$($SpecDirectory -replace "'", "''")' " +
    "-Feature '$Feature' " +
    "-Workflow '$Workflow' " +
    "-Agent '$Agent' " +
    "-OwnerId '$OwnerId'"
)

if (Test-Path -LiteralPath $ownerPath) {
    # An existing owner record exists. Two legal cases:
    # 1. status COMPLETE -> prior owner released; allow a fresh PI Register+Claim.
    # 2. status ACTIVE + same PI tuple -> reuse the bound session for a new operation.
    $existing = Get-Content -Raw -LiteralPath $ownerPath | ConvertFrom-Json
    if ([string]$existing.status -ceq "COMPLETE") {
        $session = Invoke-AiSopWorkflowSession `
            -Operation Register `
            -Agent $Agent `
            -NativeSessionId $NativeSessionId `
            -WorkspacePath $ResolvedWorkspace `
            -LifecycleProof CONFIRMED `
            -AcceptedAt $AcceptedAt `
            -DeadlineUtc $DeadlineUtc
        $sessionKeyOut = [string]$session.Record.sessionKey
        $sessionEpochIdOut = [string]$session.Record.sessionEpochId
    } elseif (
        [string]$existing.agent -cne $Agent -or
        [string]$existing.workflow -cne $Workflow -or
        [string]$existing.ownerId -cne $OwnerId -or
        [string]$existing.schemaVersion -cne "1.1"
    ) {
        throw "PI_BOOTSTRAP_OWNER_MISMATCH"
    } else {
        $sessionKey = [string]$existing.sessionBinding.sessionKey
        $sessionEpochId = [string]$existing.sessionBinding.sessionEpochId
        # Touch the bound session; if it has expired/ended (e.g. the 10s TTL
        # elapsed since the original Claim), re-register a fresh session and
        # rebind the owner to it before issuing the requested operation grant.
        $sessionAlive = $false
        try {
            Invoke-AiSopWorkflowSession `
                -Operation Touch `
                -Agent $Agent `
                -NativeSessionId $NativeSessionId `
                -WorkspacePath $ResolvedWorkspace `
                -AcceptedAt $AcceptedAt `
                -DeadlineUtc $DeadlineUtc | Out-Null
            $sessionAlive = $true
        } catch {
            $sessionAlive = $false
        }
        if ($sessionAlive) {
            $sessionKeyOut = $sessionKey
            $sessionEpochIdOut = $sessionEpochId
        } else {
            $rebindSession = Invoke-AiSopWorkflowSession `
                -Operation Register `
                -Agent $Agent `
                -NativeSessionId $NativeSessionId `
                -WorkspacePath $ResolvedWorkspace `
                -LifecycleProof CONFIRMED `
                -AcceptedAt $AcceptedAt `
                -DeadlineUtc $DeadlineUtc
            $rebindKey = [string]$rebindSession.Record.sessionKey
            $rebindEpoch = [string]$rebindSession.Record.sessionEpochId
            $rebindCmd = (
                "pwsh -NoProfile -File '.\.ai-sop\scripts\workflow-owner.ps1' " +
                "-Operation 'RebindSession' " +
                "-SpecDirectory '$($SpecDirectory -replace "'", "''")' " +
                "-Feature '$Feature' " +
                "-Workflow '$Workflow' " +
                "-Agent '$Agent' " +
                "-OwnerId '$OwnerId'"
            )
            $rebindDedup = Get-AiSopWorkflowSha256 ("pi-bootstrap-rebind-" + $rebindKey)
            $rebindTx = "pi-rebind-" + [guid]::NewGuid().ToString("N")
            $null = Invoke-AiSopWorkflowCommandGrant `
                -Operation Issue `
                -CommandText $rebindCmd `
                -SessionKey $rebindKey `
                -SessionEpochId $rebindEpoch `
                -DedupKey $rebindDedup `
                -AcceptedAt $AcceptedAt `
                -TransactionId $rebindTx `
                -GrantTtlSeconds $GrantTtlSeconds `
                -DeadlineUtc $DeadlineUtc
            Invoke-Expression $rebindCmd | Out-Null
            $sessionKeyOut = $rebindKey
            $sessionEpochIdOut = $rebindEpoch
        }
    }
} else {
    $session = Invoke-AiSopWorkflowSession `
        -Operation Register `
        -Agent $Agent `
        -NativeSessionId $NativeSessionId `
        -WorkspacePath $ResolvedWorkspace `
        -LifecycleProof CONFIRMED `
        -AcceptedAt $AcceptedAt `
        -DeadlineUtc $DeadlineUtc
    $sessionKeyOut = [string]$session.Record.sessionKey
    $sessionEpochIdOut = [string]$session.Record.sessionEpochId
}

$dedupKey = Get-AiSopWorkflowSha256 (
    "pi-bootstrap-" + $sessionKeyOut + "-" + $OwnerOperation
)
$transactionId = "pi-bootstrap-" + [guid]::NewGuid().ToString("N")

$grant = Invoke-AiSopWorkflowCommandGrant `
    -Operation Issue `
    -CommandText $CommandText `
    -SessionKey $sessionKeyOut `
    -SessionEpochId $sessionEpochIdOut `
    -DedupKey $dedupKey `
    -AcceptedAt $AcceptedAt `
    -TransactionId $transactionId `
    -GrantTtlSeconds $GrantTtlSeconds `
    -DeadlineUtc $DeadlineUtc

$result = [ordered]@{
    sessionKey      = $sessionKeyOut
    sessionEpochId  = $sessionEpochIdOut
    grantId         = [string]$grant.Record.grantId
    commandText     = $CommandText
    specDirectory   = $ResolvedSpecDirectory
    workspacePath   = $ResolvedWorkspace
}

if ($OutputFormat -eq "Json") {
    $result | ConvertTo-Json -Compress
} else {
    Write-Output "PI session registered: $($result.sessionKey)"
    Write-Output "Grant issued for: $($result.commandText)"
    Write-Output "GrantId: $($result.grantId)"
    Write-Output "Now run the command above to consume the grant."
}
