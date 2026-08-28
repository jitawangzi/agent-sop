#requires -Version 7.0

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$ScriptsRoot = Split-Path -Parent $PSScriptRoot
$OwnerScript = Join-Path $ScriptsRoot "workflow-owner.ps1"
$SessionScript = Join-Path $ScriptsRoot "workflow-session.ps1"
$GrantScript = Join-Path $ScriptsRoot "workflow-command-grant.ps1"
$ClaudeRoot = Split-Path -Parent $ScriptsRoot
$OwnerSchema = Join-Path $ClaudeRoot "schemas\workflow-owner.schema.json"
$SessionSchema = Join-Path $ClaudeRoot "schemas\workflow-session.schema.json"
$GrantSchema = Join-Path $ClaudeRoot "schemas\workflow-command-grant.schema.json"
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "workflow-owner-tests-" + [guid]::NewGuid().ToString("N")
)
$env:SERVER_NEW_WORKFLOW_REGISTRY = Join-Path $TestRoot "owners"
$env:SERVER_NEW_WORKFLOW_SESSION_REGISTRY = Join-Path $TestRoot "sessions"
$env:SERVER_NEW_WORKFLOW_COMMAND_GRANT_REGISTRY = Join-Path $TestRoot "grants"
$env:SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY = Join-Path $TestRoot "transactions"
$env:SERVER_NEW_WORKFLOW_OWNER_DEADLINE_MS = "10000"
$env:SERVER_NEW_WORKFLOW_TRANSACTION_DEADLINE_MS = "10000"
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

function Assert-True {
    param([bool]$Condition, [string]$Message)

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)

    if ($Actual -cne $Expected) {
        throw "$Message Expected '$Expected', got '$Actual'."
    }
}

function Assert-Fails {
    param([scriptblock]$Action, [string]$Message)

    $failed = $false
    try {
        & $Action | Out-Null
    } catch {
        $failed = $true
    }
    if (-not $failed) {
        throw "Expected failure: $Message"
    }
}

function New-TestFeature {
    param([string]$Name)

    $workspace = Join-Path $TestRoot "workspace-$Name"
    $spec = Join-Path $workspace ".ai-workspace\specs\features\$Name"
    [System.IO.Directory]::CreateDirectory($spec) | Out-Null
    [System.IO.Directory]::CreateDirectory(
        (Join-Path $workspace ".ai-sop\scripts")
    ) | Out-Null
    return [pscustomobject]@{
        Feature = $Name
        Workspace = $workspace
        Spec = $spec
    }
}

function New-OwnerCommand {
    param(
        [string]$Operation,
        [string]$Feature,
        [string]$Workflow,
        [string]$Agent,
        [string]$OwnerId
    )

    return (
        "pwsh -NoProfile -File '.\.ai-sop\scripts\workflow-owner.ps1' " +
        "-Operation '$Operation' " +
        "-SpecDirectory '.ai-workspace\specs\features\$Feature' " +
        "-Feature '$Feature' " +
        "-Workflow '$Workflow' " +
        "-Agent '$Agent' " +
        "-OwnerId '$OwnerId'"
    )
}

function New-Session {
    param(
        [object]$Feature,
        [string]$Agent,
        [string]$NativeSessionId,
        [DateTimeOffset]$AcceptedAt = [DateTimeOffset]::UtcNow
    )

    $session = Invoke-AiSopWorkflowSession `
        -Operation Register `
        -Agent $Agent `
        -NativeSessionId $NativeSessionId `
        -WorkspacePath $Feature.Workspace `
        -LifecycleProof CONFIRMED `
        -AcceptedAt $AcceptedAt
    Assert-Equal $session.Record.stateChangedAt (
        $AcceptedAt.ToUniversalTime().ToString("o")
    ) "Owner test session fixture did not initialize stateChangedAt."
    return $session
}

function New-Grant {
    param(
        [object]$Feature,
        [object]$Session,
        [string]$Operation,
        [string]$Agent,
        [string]$OwnerId,
        [string]$Suffix
    )

    $acceptedAt = [DateTimeOffset]::UtcNow
    $command = New-OwnerCommand `
        -Operation $Operation `
        -Feature $Feature.Feature `
        -Workflow SUPERPOWERS `
        -Agent $Agent `
        -OwnerId $OwnerId
    return Invoke-AiSopWorkflowCommandGrant `
        -Operation Issue `
        -CommandText $command `
        -SessionKey $Session.Record.sessionKey `
        -SessionEpochId $Session.Record.sessionEpochId `
        -DedupKey (Get-AiSopWorkflowSha256 "dedup-$Suffix") `
        -AcceptedAt $acceptedAt `
        -TransactionId "issue-$Suffix"
}

function Invoke-Owner {
    param(
        [object]$Feature,
        [string]$Operation,
        [string]$Workflow,
        [string]$Agent,
        [string]$OwnerId,
        [string]$Tier = "T2"
    )

    return & $OwnerScript `
        -Operation $Operation `
        -SpecDirectory $Feature.Spec `
        -Feature $Feature.Feature `
        -Workflow $Workflow `
        -Agent $Agent `
        -OwnerId $OwnerId `
        -Tier $Tier
}

function Read-OwnerRecord {
    param([string]$Feature)

    $path = Join-Path $env:SERVER_NEW_WORKFLOW_REGISTRY (
        $Feature.ToLowerInvariant() + ".json"
    )
    $raw = [System.IO.File]::ReadAllText($path)
    Assert-True ($raw | Test-Json -SchemaFile $OwnerSchema) (
        "Owner record does not satisfy schema: $Feature"
    )
    return ConvertFrom-AiSopWorkflowJson -Json $raw
}

function Write-LegacyOwner {
    param(
        [object]$Feature,
        [string]$Workflow,
        [string]$Agent,
        [string]$OwnerId
    )

    [System.IO.Directory]::CreateDirectory(
        $env:SERVER_NEW_WORKFLOW_REGISTRY
    ) | Out-Null
    $owner = [ordered]@{
        schemaVersion = "1.0"
        feature = $Feature.Feature
        workflow = $Workflow
        agent = $Agent
        ownerId = $OwnerId
        specDirectory = [System.IO.Path]::GetFullPath($Feature.Spec)
        baseline = "0"
        status = "ACTIVE"
        startedAt = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString("o")
        completedAt = ""
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $env:SERVER_NEW_WORKFLOW_REGISTRY (
            $Feature.Feature.ToLowerInvariant() + ".json"
        )),
        ($owner | ConvertTo-Json -Depth 20),
        $Utf8NoBom
    )
}

function Write-Owner11 {
    param(
        [object]$Feature,
        [string]$OwnerId,
        [object]$Session,
        [DateTimeOffset]$AcceptedAt
    )

    [System.IO.Directory]::CreateDirectory(
        $env:SERVER_NEW_WORKFLOW_REGISTRY
    ) | Out-Null
    $owner = [ordered]@{
        schemaVersion = "1.1"
        feature = $Feature.Feature
        workflow = "SUPERPOWERS"
        agent = "CURSOR"
        ownerId = $OwnerId
        specDirectory = [System.IO.Path]::GetFullPath($Feature.Spec)
        workspacePath = [System.IO.Path]::GetFullPath($Feature.Workspace)
        baseline = "0"
        status = "ACTIVE"
        startedAt = $AcceptedAt.AddMinutes(-1).ToString("o")
        completedAt = ""
        sessionBinding = [ordered]@{
            sessionKey = [string]$Session.sessionKey
            sessionEpochId = [string]$Session.sessionEpochId
            boundAt = $AcceptedAt.AddMinutes(-1).ToString("o")
        }
        lastTransactionId = "test-owner-11"
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $env:SERVER_NEW_WORKFLOW_REGISTRY (
            $Feature.Feature.ToLowerInvariant() + ".json"
        )),
        ($owner | ConvertTo-Json -Depth 30),
        $Utf8NoBom
    )
}

function New-CrossSessionRebindCase {
    param(
        [string]$Name,
        [DateTimeOffset]$AcceptedAt
    )

    $feature = New-TestFeature $Name
    $ownerId = "owner-$($Name.ToLowerInvariant())"
    $oldSession = New-Session `
        -Feature $feature `
        -Agent CURSOR `
        -NativeSessionId "old-$Name" `
        -AcceptedAt $AcceptedAt
    $newSession = New-Session `
        -Feature $feature `
        -Agent CURSOR `
        -NativeSessionId "new-$Name" `
        -AcceptedAt $AcceptedAt
    $oldRecord = Get-Content -LiteralPath $oldSession.SessionPath -Raw |
        ConvertFrom-Json -AsHashtable -DateKind String
    $oldRecord.boundFeature = $feature.Feature
    $oldRecord.boundWorkflow = "SUPERPOWERS"
    $oldRecord.boundOwnerId = $ownerId
    $oldRecord.boundSessionEpochId = $oldRecord.sessionEpochId
    $oldRecord.status = "ENDED"
    $oldRecord.endedAt = $AcceptedAt.AddMilliseconds(1).ToString("o")
    [System.IO.File]::WriteAllText(
        $oldSession.SessionPath,
        ($oldRecord | ConvertTo-Json -Depth 30),
        $Utf8NoBom
    )
    Write-Owner11 `
        -Feature $feature `
        -OwnerId $ownerId `
        -Session $oldRecord `
        -AcceptedAt $AcceptedAt
    $grant = New-Grant `
        -Feature $feature `
        -Session $newSession `
        -Operation RebindSession `
        -Agent CURSOR `
        -OwnerId $ownerId `
        -Suffix "$Name-rebind"
    return [pscustomobject]@{
        Feature = $feature
        OwnerId = $ownerId
        OwnerPath = Join-Path $env:SERVER_NEW_WORKFLOW_REGISTRY (
            $feature.Feature.ToLowerInvariant() + ".json"
        )
        OldSessionPath = $oldSession.SessionPath
        OldRecord = $oldRecord
        NewSession = $newSession
        Grant = $grant
    }
}

try {
    foreach ($requiredPath in @(
        $OwnerScript,
        $SessionScript,
        $GrantScript,
        $OwnerSchema,
        $SessionSchema,
        $GrantSchema
    )) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "Required Task 3 artifact does not exist: $requiredPath"
        }
    }
    . $SessionScript
    . $GrantScript

    # Four current harnesses create only session-bound Owner 1.1 records.
    foreach ($agent in @("CLAUDE_CODE", "COPILOT", "ANTIGRAVITY", "CURSOR")) {
        $name = "Owner$($agent.Replace('_', ''))"
        $feature = New-TestFeature $name
        $ownerId = "owner-$($agent.ToLowerInvariant())"
        $session = New-Session `
            -Feature $feature `
            -Agent $agent `
            -NativeSessionId "native-$agent"
        $claimGrant = New-Grant `
            -Feature $feature `
            -Session $session `
            -Operation Claim `
            -Agent $agent `
            -OwnerId $ownerId `
            -Suffix "$agent-claim"
        Invoke-Owner `
            -Feature $feature `
            -Operation Claim `
            -Workflow SUPERPOWERS `
            -Agent $agent `
            -OwnerId $ownerId |
            Out-Null
        $owner = Read-OwnerRecord $name
        Assert-Equal $owner.schemaVersion "1.1" (
            "$agent did not create Owner 1.1."
        )
        Assert-Equal $owner.workflow "SUPERPOWERS" (
            "$agent owner workflow mismatch."
        )
        Assert-Equal $owner.sessionBinding.sessionKey (
            $session.Record.sessionKey
        ) "$agent owner sessionKey mismatch."
        Assert-Equal $owner.sessionBinding.sessionEpochId (
            $session.Record.sessionEpochId
        ) "$agent owner epoch mismatch."
        Assert-Equal $owner.ownerId $ownerId "$agent ownerId changed."
        $claimedSession = Get-AiSopWorkflowSession `
            -SessionKey $session.Record.sessionKey
        Assert-Equal $claimedSession.Record.boundFeature $name (
            "$agent session was not bound."
        )
        Assert-Equal (
            (Get-Content -LiteralPath $claimGrant.GrantPath -Raw |
                ConvertFrom-Json).status
        ) "CONSUMED" "$agent Claim grant was not consumed."

        $validateGrant = New-Grant `
            -Feature $feature `
            -Session $claimedSession `
            -Operation Validate `
            -Agent $agent `
            -OwnerId $ownerId `
            -Suffix "$agent-validate"
        $validation = Invoke-Owner `
            -Feature $feature `
            -Operation Validate `
            -Workflow SUPERPOWERS `
            -Agent $agent `
            -OwnerId $ownerId
        Assert-Equal ([string]$validation) "VALID" (
            "$agent Owner 1.1 Validate failed."
        )
        Assert-Equal (
            (Get-Content -LiteralPath $validateGrant.GrantPath -Raw |
                ConvertFrom-Json).status
        ) "CONSUMED" "$agent Validate grant was not consumed."

        $completeSession = Get-AiSopWorkflowSession `
            -SessionKey $session.Record.sessionKey
        $completeGrant = New-Grant `
            -Feature $feature `
            -Session $completeSession `
            -Operation Complete `
            -Agent $agent `
            -OwnerId $ownerId `
            -Suffix "$agent-complete"
        Invoke-Owner `
            -Feature $feature `
            -Operation Complete `
            -Workflow SUPERPOWERS `
            -Agent $agent `
            -OwnerId $ownerId |
            Out-Null
        $completedOwner = Read-OwnerRecord $name
        Assert-Equal $completedOwner.status "COMPLETE" (
            "$agent owner did not complete."
        )
        $completedSession = Get-AiSopWorkflowSession `
            -SessionKey $session.Record.sessionKey
        Assert-Equal $completedSession.Record.boundFeature "" (
            "$agent completed session remained bound."
        )
        Assert-Equal (
            (Get-Content -LiteralPath $completeGrant.GrantPath -Raw |
                ConvertFrom-Json).status
        ) "CONSUMED" "$agent Complete grant was not consumed."
    }

    # Direct Claim, Validate, and Complete without pre-issued grant auto-bootstraps session and grant.
    $noGrantFeature = New-TestFeature "NoGrantFeature"
    $noGrantOut = Invoke-Owner `
        -Feature $noGrantFeature `
        -Operation Claim `
        -Workflow SUPERPOWERS `
        -Agent CURSOR `
        -OwnerId "no-grant-owner"
    $noGrantOwner = Read-OwnerRecord "NoGrantFeature"
    Assert-Equal $noGrantOwner.status "ACTIVE" "Direct claim without pre-grant failed to create active owner."

    $valOut = Invoke-Owner `
        -Feature $noGrantFeature `
        -Operation Validate `
        -Workflow SUPERPOWERS `
        -Agent CURSOR `
        -OwnerId "no-grant-owner"
    Assert-Equal $valOut "VALID" "Direct validate without pre-grant failed."

    $compOut = Invoke-Owner `
        -Feature $noGrantFeature `
        -Operation Complete `
        -Workflow SUPERPOWERS `
        -Agent CURSOR `
        -OwnerId "no-grant-owner"
    $compOwner = Read-OwnerRecord "NoGrantFeature"
    Assert-Equal $compOwner.status "COMPLETE" "Direct complete without pre-grant failed."

    # Validate must re-read and re-check the session after acquiring the final
    # session -> owner -> grant lock set. SessionEnd wins this ordered barrier.
    $raceFeature = New-TestFeature "ValidateSessionEndRace"
    $raceOwnerId = "validate-session-end-owner"
    $raceSession = New-Session `
        -Feature $raceFeature `
        -Agent CURSOR `
        -NativeSessionId "validate-session-end-native"
    New-Grant `
        -Feature $raceFeature `
        -Session $raceSession `
        -Operation Claim `
        -Agent CURSOR `
        -OwnerId $raceOwnerId `
        -Suffix "validate-session-end-claim" |
        Out-Null
    Invoke-Owner `
        -Feature $raceFeature `
        -Operation Claim `
        -Workflow SUPERPOWERS `
        -Agent CURSOR `
        -OwnerId $raceOwnerId |
        Out-Null
    $raceBoundSession = Get-AiSopWorkflowSession `
        -SessionKey $raceSession.Record.sessionKey
    $raceValidateGrant = New-Grant `
        -Feature $raceFeature `
        -Session $raceBoundSession `
        -Operation Validate `
        -Agent CURSOR `
        -OwnerId $raceOwnerId `
        -Suffix "validate-session-end-validate"
    $raceMarker = Join-Path $TestRoot "validate-session-end.marker"
    $raceRelease = Join-Path $TestRoot "validate-session-end.release"
    $raceOut = Join-Path $TestRoot "validate-session-end.out"
    $raceErr = Join-Path $TestRoot "validate-session-end.err"
    $savedPausePoint = $env:SERVER_NEW_WORKFLOW_OWNER_PAUSE_POINT
    $savedPauseMarker = $env:SERVER_NEW_WORKFLOW_OWNER_PAUSE_MARKER
    $savedPauseRelease = $env:SERVER_NEW_WORKFLOW_OWNER_PAUSE_RELEASE
    $env:SERVER_NEW_WORKFLOW_OWNER_PAUSE_POINT = "BEFORE_VALIDATE_FINAL_LOCK"
    $env:SERVER_NEW_WORKFLOW_OWNER_PAUSE_MARKER = $raceMarker
    $env:SERVER_NEW_WORKFLOW_OWNER_PAUSE_RELEASE = $raceRelease
    try {
        $raceProcess = Start-Process -FilePath (Get-Process -Id $PID).Path `
            -WindowStyle Hidden `
            -ArgumentList @(
                "-NoProfile",
                "-File",
                $OwnerScript,
                "-Operation",
                "Validate",
                "-SpecDirectory",
                $raceFeature.Spec,
                "-Feature",
                $raceFeature.Feature,
                "-Workflow",
                "SUPERPOWERS",
                "-Agent",
                "CURSOR",
                "-OwnerId",
                $raceOwnerId
            ) `
            -RedirectStandardOutput $raceOut `
            -RedirectStandardError $raceErr `
            -PassThru
        $raceLimit = [DateTimeOffset]::UtcNow.AddSeconds(5)
        while (
            -not (Test-Path -LiteralPath $raceMarker) -and
            -not $raceProcess.HasExited -and
            [DateTimeOffset]::UtcNow -lt $raceLimit
        ) {
            Start-Sleep -Milliseconds 10
            $raceProcess.Refresh()
        }
        Assert-True (Test-Path -LiteralPath $raceMarker) (
            "Owner Validate did not expose the final-lock SessionEnd barrier."
        )
        Invoke-AiSopWorkflowSession `
            -Operation End `
            -Agent CURSOR `
            -NativeSessionId "validate-session-end-native" `
            -WorkspacePath $raceFeature.Workspace `
            -AcceptedAt ([DateTimeOffset]::UtcNow) |
            Out-Null
        [System.IO.File]::WriteAllText($raceRelease, "release", $Utf8NoBom)
        $raceProcess.WaitForExit()
        Assert-True ($raceProcess.ExitCode -ne 0) (
            "Owner Validate succeeded after SessionEnd won the final-lock race."
        )
        Assert-Equal (
            (Get-Content -LiteralPath $raceValidateGrant.GrantPath -Raw |
                ConvertFrom-Json).status
        ) "ISSUED" "SessionEnd race rewrote historical Validate grant."
        $raceIntentIndex = Get-Content `
            -LiteralPath (
                Get-AiSopWorkflowCommandGrantActiveIndexPath `
                    $raceValidateGrant.Record.intentSha256
            ) `
            -Raw |
            ConvertFrom-Json
        Assert-Equal @(
            $raceIntentIndex.entries |
                Where-Object {
                    $_.grantId -ceq $raceValidateGrant.Record.grantId -and
                    $_.active
                }
        ).Count 0 "SessionEnd race left Validate grant authorization active."
    } finally {
        foreach ($entry in @(
            @("SERVER_NEW_WORKFLOW_OWNER_PAUSE_POINT", $savedPausePoint),
            @("SERVER_NEW_WORKFLOW_OWNER_PAUSE_MARKER", $savedPauseMarker),
            @("SERVER_NEW_WORKFLOW_OWNER_PAUSE_RELEASE", $savedPauseRelease)
        )) {
            if ($null -eq $entry[1]) {
                Remove-Item "Env:$($entry[0])" -ErrorAction SilentlyContinue
            } else {
                Set-Item "Env:$($entry[0])" -Value $entry[1]
            }
        }
    }

    # The current-style SUPERPOWERS/CURSOR 1.0 record upgrades in place.
    $migration = New-TestFeature "MigrationFeature"
    $migrationOwnerId = "cursor-p0-7bb519c61ff3"
    Write-LegacyOwner `
        -Feature $migration `
        -Workflow SUPERPOWERS `
        -Agent CURSOR `
        -OwnerId $migrationOwnerId
    $migrationSession = New-Session `
        -Feature $migration `
        -Agent CURSOR `
        -NativeSessionId "current-cursor-session"
    New-Grant `
        -Feature $migration `
        -Session $migrationSession `
        -Operation BindSession `
        -Agent CURSOR `
        -OwnerId $migrationOwnerId `
        -Suffix "migration-bind" |
        Out-Null
    Invoke-Owner `
        -Feature $migration `
        -Operation BindSession `
        -Workflow SUPERPOWERS `
        -Agent CURSOR `
        -OwnerId $migrationOwnerId |
        Out-Null
    $migrated = Read-OwnerRecord $migration.Feature
    Assert-Equal $migrated.schemaVersion "1.1" (
        "Current Cursor Owner 1.0 was not upgraded."
    )
    Assert-Equal $migrated.ownerId $migrationOwnerId (
        "Current Cursor migration changed OwnerId."
    )

    # Same native session cannot revive an expired bound epoch; exact Rebind can.
    $migrationSessionPath = Get-AiSopWorkflowSessionPath (
        $migrationSession.Record.sessionKey
    )
    $expiredSession = Get-Content -LiteralPath $migrationSessionPath -Raw |
        ConvertFrom-Json -AsHashtable -DateKind String
    $oldEpoch = $expiredSession.sessionEpochId
    $expiredSession.expiresAt =
        [DateTimeOffset]::UtcNow.AddSeconds(-1).ToString("o")
    [System.IO.File]::WriteAllText(
        $migrationSessionPath,
        ($expiredSession | ConvertTo-Json -Depth 30),
        $Utf8NoBom
    )
    $rebindGrant = New-Grant `
        -Feature $migration `
        -Session ([pscustomobject]@{
            Record = [pscustomobject]$expiredSession
        }) `
        -Operation RebindSession `
        -Agent CURSOR `
        -OwnerId $migrationOwnerId `
        -Suffix "migration-rebind"
    Assert-True (
        $rebindGrant.Record.sessionEpochId -cne $oldEpoch
    ) "Rebind grant reused the expired epoch."
    Invoke-Owner `
        -Feature $migration `
        -Operation RebindSession `
        -Workflow SUPERPOWERS `
        -Agent CURSOR `
        -OwnerId $migrationOwnerId |
        Out-Null
    $rebound = Read-OwnerRecord $migration.Feature
    Assert-Equal $rebound.sessionBinding.sessionEpochId (
        $rebindGrant.Record.sessionEpochId
    ) "Owner did not switch to the Rebind epoch."
    $reboundSession = Get-AiSopWorkflowSession `
        -SessionKey $migrationSession.Record.sessionKey
    Assert-Equal $reboundSession.EffectiveStatus "ACTIVE" (
        "Rebound session is not ACTIVE."
    )
    Assert-Equal $reboundSession.Record.sessionEpochId (
        $rebindGrant.Record.sessionEpochId
    ) "Session did not switch to the Rebind epoch."

    # Rebind re-checks the exact Owner workspace and old bound tuple before the
    # final transaction. Mutate one field only after a valid grant was issued.
    $exactRebind = New-CrossSessionRebindCase `
        -Name "ExactCrossSessionRebind" `
        -AcceptedAt ([DateTimeOffset]::UtcNow)
    Invoke-Owner `
        -Feature $exactRebind.Feature `
        -Operation RebindSession `
        -Workflow SUPERPOWERS `
        -Agent CURSOR `
        -OwnerId $exactRebind.OwnerId |
        Out-Null
    $exactReboundOwner = Read-OwnerRecord $exactRebind.Feature.Feature
    Assert-Equal $exactReboundOwner.sessionBinding.sessionKey (
        $exactRebind.NewSession.Record.sessionKey
    ) "Exact cross-session Rebind positive control failed."

    $ownerRebindFailures = [System.Collections.Generic.List[string]]::new()
    foreach ($rebindMutation in @(
        [pscustomobject]@{
            Name = "OwnerWorkspace"
            OwnerField = "workspacePath"
            SessionField = ""
            Value = ""
        },
        [pscustomobject]@{
            Name = "BoundFeature"
            OwnerField = ""
            SessionField = "boundFeature"
            Value = "OtherFeature"
        },
        [pscustomobject]@{
            Name = "BoundWorkflow"
            OwnerField = ""
            SessionField = "boundWorkflow"
            Value = "CUSTOM_SKILLS"
        },
        [pscustomobject]@{
            Name = "BoundOwnerId"
            OwnerField = ""
            SessionField = "boundOwnerId"
            Value = "other-owner-id"
        },
        [pscustomobject]@{
            Name = "BoundEpoch"
            OwnerField = ""
            SessionField = "boundSessionEpochId"
            Value = "other-bound-epoch"
        }
    )) {
        $case = New-CrossSessionRebindCase `
            -Name "Final$($rebindMutation.Name)" `
            -AcceptedAt ([DateTimeOffset]::UtcNow)
        if (-not [string]::IsNullOrEmpty($rebindMutation.OwnerField)) {
            $mutatedOwner = Get-Content -LiteralPath $case.OwnerPath -Raw |
                ConvertFrom-Json -AsHashtable -DateKind String
            $wrongWorkspace = Join-Path $TestRoot (
                "wrong-workspace-$($rebindMutation.Name)"
            )
            [System.IO.Directory]::CreateDirectory($wrongWorkspace) |
                Out-Null
            $mutatedOwner[$rebindMutation.OwnerField] =
                [System.IO.Path]::GetFullPath($wrongWorkspace)
            [System.IO.File]::WriteAllText(
                $case.OwnerPath,
                ($mutatedOwner | ConvertTo-Json -Depth 30),
                $Utf8NoBom
            )
        } else {
            $mutatedOldSession = Get-Content `
                -LiteralPath $case.OldSessionPath `
                -Raw |
                ConvertFrom-Json -AsHashtable -DateKind String
            $mutatedOldSession[$rebindMutation.SessionField] =
                $rebindMutation.Value
            [System.IO.File]::WriteAllText(
                $case.OldSessionPath,
                ($mutatedOldSession | ConvertTo-Json -Depth 30),
                $Utf8NoBom
            )
        }
        $rebindFailed = $false
        try {
            Invoke-Owner `
                -Feature $case.Feature `
                -Operation RebindSession `
                -Workflow SUPERPOWERS `
                -Agent CURSOR `
                -OwnerId $case.OwnerId |
                Out-Null
        } catch {
            $rebindFailed = $true
        }
        if (-not $rebindFailed) {
            $ownerRebindFailures.Add($rebindMutation.Name)
            continue
        }
        $unchangedOwner = Read-OwnerRecord $case.Feature.Feature
        Assert-Equal $unchangedOwner.sessionBinding.sessionKey (
            $case.OldRecord.sessionKey
        ) "Rejected $($rebindMutation.Name) Rebind changed Owner binding."
        Assert-Equal (
            (Get-Content -LiteralPath $case.Grant.GrantPath -Raw |
                ConvertFrom-Json).status
        ) "ISSUED" "Rejected $($rebindMutation.Name) Rebind consumed its grant."
    }
    Assert-Equal $ownerRebindFailures.Count 0 (
        "Owner final Rebind accepted wrong exact tuple fields: " +
        ($ownerRebindFailures -join ", ")
    )

    # Existing legacy 1.0 identities retain only Validate/Complete.
    foreach ($legacyCase in @(
        [pscustomobject]@{
            Name = "LegacyCustom"
            Workflow = "CUSTOM_SKILLS"
            Agent = "COPILOT"
        },
        [pscustomobject]@{
            Name = "LegacyGemini"
            Workflow = "CUSTOM_SKILLS"
            Agent = "GEMINI"
        }
    )) {
        $legacy = New-TestFeature $legacyCase.Name
        $legacyOwnerId = "legacy-$($legacyCase.Agent.ToLowerInvariant())"
        Write-LegacyOwner `
            -Feature $legacy `
            -Workflow $legacyCase.Workflow `
            -Agent $legacyCase.Agent `
            -OwnerId $legacyOwnerId
        $legacyValidation = Invoke-Owner `
            -Feature $legacy `
            -Operation Validate `
            -Workflow $legacyCase.Workflow `
            -Agent $legacyCase.Agent `
            -OwnerId $legacyOwnerId
        Assert-Equal ([string]$legacyValidation) "VALID" (
            "$($legacyCase.Agent) legacy Validate failed."
        )
        Assert-Fails -Message "$($legacyCase.Agent) legacy Bind expanded privilege." -Action {
            Invoke-Owner `
                -Feature $legacy `
                -Operation BindSession `
                -Workflow $legacyCase.Workflow `
                -Agent $legacyCase.Agent `
                -OwnerId $legacyOwnerId
        }
        Assert-Fails -Message "$($legacyCase.Agent) legacy Rebind expanded privilege." -Action {
            Invoke-Owner `
                -Feature $legacy `
                -Operation RebindSession `
                -Workflow $legacyCase.Workflow `
                -Agent $legacyCase.Agent `
                -OwnerId $legacyOwnerId
        }
        Invoke-Owner `
            -Feature $legacy `
            -Operation Complete `
            -Workflow $legacyCase.Workflow `
            -Agent $legacyCase.Agent `
            -OwnerId $legacyOwnerId |
            Out-Null
        Assert-Equal (Read-OwnerRecord $legacy.Feature).status "COMPLETE" (
            "$($legacyCase.Agent) legacy Complete failed."
        )
    }

    foreach ($invalid in @(
        [pscustomobject]@{
            Name = "NewCustom"
            Workflow = "CUSTOM_SKILLS"
            Agent = "COPILOT"
        },
        [pscustomobject]@{
            Name = "NewGemini"
            Workflow = "SUPERPOWERS"
            Agent = "GEMINI"
        }
    )) {
        $feature = New-TestFeature $invalid.Name
        Assert-Fails -Message "$($invalid.Name) created a new owner." -Action {
            Invoke-Owner `
                -Feature $feature `
                -Operation Claim `
                -Workflow $invalid.Workflow `
                -Agent $invalid.Agent `
                -OwnerId "invalid-new-owner"
        }
    }

    Assert-True (
        @(
            Get-ChildItem -LiteralPath $env:SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY `
                -Filter *.json -File -ErrorAction SilentlyContinue
        ).Count -eq 0
    ) "Resolved Owner transactions left journals behind."

    # Transfer: user switches tool mid-feature (e.g. Claude Code -> Cursor).
    $transferFeature = New-TestFeature "OwnerTransfer"
    $transferOwnerId = "owner-transfer"
    $claudeSession = New-Session `
        -Feature $transferFeature `
        -Agent CLAUDE_CODE `
        -NativeSessionId "native-transfer-claude"
    New-Grant `
        -Feature $transferFeature `
        -Session $claudeSession `
        -Operation Claim `
        -Agent CLAUDE_CODE `
        -OwnerId $transferOwnerId `
        -Suffix "transfer-claim" | Out-Null
    Invoke-Owner `
        -Feature $transferFeature `
        -Operation Claim `
        -Workflow SUPERPOWERS `
        -Agent CLAUDE_CODE `
        -OwnerId $transferOwnerId | Out-Null

    $cursorSession = New-Session `
        -Feature $transferFeature `
        -Agent CURSOR `
        -NativeSessionId "native-transfer-cursor"
    New-Grant `
        -Feature $transferFeature `
        -Session $cursorSession `
        -Operation Transfer `
        -Agent CURSOR `
        -OwnerId $transferOwnerId `
        -Suffix "transfer-transfer" | Out-Null
    Invoke-Owner `
        -Feature $transferFeature `
        -Operation Transfer `
        -Workflow SUPERPOWERS `
        -Agent CURSOR `
        -OwnerId $transferOwnerId | Out-Null

    $transferredOwner = Read-OwnerRecord "OwnerTransfer"
    Assert-Equal $transferredOwner.agent "CURSOR" (
        "Transfer did not change owner.agent to CURSOR."
    )
    Assert-Equal $transferredOwner.ownerId $transferOwnerId (
        "Transfer must preserve ownerId."
    )
    Assert-Equal $transferredOwner.status "ACTIVE" (
        "Transfer must keep status ACTIVE."
    )
    Assert-Equal $transferredOwner.sessionBinding.sessionKey (
        $cursorSession.Record.sessionKey
    ) "Transfer must rebind session to the new tool's session."

    # Validate with the new agent succeeds.
    New-Grant `
        -Feature $transferFeature `
        -Session $cursorSession `
        -Operation Validate `
        -Agent CURSOR `
        -OwnerId $transferOwnerId `
        -Suffix "transfer-validate" | Out-Null
    $transferValidation = Invoke-Owner `
        -Feature $transferFeature `
        -Operation Validate `
        -Workflow SUPERPOWERS `
        -Agent CURSOR `
        -OwnerId $transferOwnerId
    Assert-Equal ([string]$transferValidation) "VALID" (
        "Transferred owner Validate with CURSOR failed."
    )

    # Complete with the new agent.
    New-Grant `
        -Feature $transferFeature `
        -Session $cursorSession `
        -Operation Complete `
        -Agent CURSOR `
        -OwnerId $transferOwnerId `
        -Suffix "transfer-complete" | Out-Null
    Invoke-Owner `
        -Feature $transferFeature `
        -Operation Complete `
        -Workflow SUPERPOWERS `
        -Agent CURSOR `
        -OwnerId $transferOwnerId | Out-Null
    $completedTransfer = Read-OwnerRecord "OwnerTransfer"
    Assert-Equal $completedTransfer.status "COMPLETE" (
        "Transferred owner did not Complete with CURSOR."
    )

    # Transfer to a mismatched ownerId must fail (cannot steal ownership).
    $stealFeature = New-TestFeature "OwnerTransferSteal"
    $stealOwnerId = "owner-steal-real"
    $stealClaudeSession = New-Session `
        -Feature $stealFeature `
        -Agent CLAUDE_CODE `
        -NativeSessionId "native-steal-claude"
    New-Grant `
        -Feature $stealFeature `
        -Session $stealClaudeSession `
        -Operation Claim `
        -Agent CLAUDE_CODE `
        -OwnerId $stealOwnerId `
        -Suffix "steal-claim" | Out-Null
    Invoke-Owner `
        -Feature $stealFeature `
        -Operation Claim `
        -Workflow SUPERPOWERS `
        -Agent CLAUDE_CODE `
        -OwnerId $stealOwnerId | Out-Null
    $stealCursorSession = New-Session `
        -Feature $stealFeature `
        -Agent CURSOR `
        -NativeSessionId "native-steal-cursor"
    New-Grant `
        -Feature $stealFeature `
        -Session $stealCursorSession `
        -Operation Transfer `
        -Agent CURSOR `
        -OwnerId "$stealOwnerId-wrong" `
        -Suffix "steal-transfer" | Out-Null
    Assert-Fails -Message "Transfer with mismatched ownerId must be rejected." -Action {
        Invoke-Owner `
            -Feature $stealFeature `
            -Operation Transfer `
            -Workflow SUPERPOWERS `
            -Agent CURSOR `
            -OwnerId "$stealOwnerId-wrong"
    }

    # ForceRelease: emergency recovery for an orphaned ACTIVE owner (session
    # crashed/exited without Complete). Requires exact Feature+OwnerId.
    $orphanFeature = New-TestFeature "OwnerOrphanRelease"
    $orphanOwnerId = "owner-orphan"
    $orphanSession = New-Session `
        -Feature $orphanFeature `
        -Agent CLAUDE_CODE `
        -NativeSessionId "native-orphan"
    New-Grant `
        -Feature $orphanFeature `
        -Session $orphanSession `
        -Operation Claim `
        -Agent CLAUDE_CODE `
        -OwnerId $orphanOwnerId `
        -Suffix "orphan-claim" | Out-Null
    Invoke-Owner `
        -Feature $orphanFeature `
        -Operation Claim `
        -Workflow SUPERPOWERS `
        -Agent CLAUDE_CODE `
        -OwnerId $orphanOwnerId | Out-Null

    # ForceRelease with mismatched ownerId must fail (cannot release others' ownership).
    Assert-Fails -Message "ForceRelease with wrong ownerId must be rejected." -Action {
        Invoke-Owner `
            -Feature $orphanFeature `
            -Operation ForceRelease `
            -Workflow SUPERPOWERS `
            -Agent CLAUDE_CODE `
            -OwnerId "$orphanOwnerId-wrong"
    }
    # Correct ForceRelease succeeds.
    Invoke-Owner `
        -Feature $orphanFeature `
        -Operation ForceRelease `
        -Workflow SUPERPOWERS `
        -Agent CLAUDE_CODE `
        -OwnerId $orphanOwnerId | Out-Null
    $releasedOwner = Read-OwnerRecord "OwnerOrphanRelease"
    Assert-Equal $releasedOwner.status "RELEASED" (
        "ForceRelease must set status to RELEASED."
    )
    # After RELEASED, a new Claim must succeed (the feature is unblocked).
    $orphanSession2 = New-Session `
        -Feature $orphanFeature `
        -Agent CURSOR `
        -NativeSessionId "native-orphan-2"
    New-Grant `
        -Feature $orphanFeature `
        -Session $orphanSession2 `
        -Operation Claim `
        -Agent CURSOR `
        -OwnerId "$orphanOwnerId-reclaimed" `
        -Suffix "orphan-reclaim" | Out-Null
    Invoke-Owner `
        -Feature $orphanFeature `
        -Operation Claim `
        -Workflow SUPERPOWERS `
        -Agent CURSOR `
        -OwnerId "$orphanOwnerId-reclaimed" | Out-Null
    $reclaimedOwner = Read-OwnerRecord "OwnerOrphanRelease"
    Assert-Equal $reclaimedOwner.status "ACTIVE" (
        "After ForceRelease, a new Claim must succeed (status ACTIVE)."
    )
    Assert-Equal $reclaimedOwner.agent "CURSOR" (
        "Reclaimed owner must have the new agent (CURSOR)."
    )
    # After reclaim (ACTIVE), ForceRelease should succeed again (it's ACTIVE).
    Invoke-Owner `
        -Feature $orphanFeature `
        -Operation ForceRelease `
        -Workflow SUPERPOWERS `
        -Agent CURSOR `
        -OwnerId "$orphanOwnerId-reclaimed" | Out-Null
    $reReleasedOwner = Read-OwnerRecord "OwnerOrphanRelease"
    Assert-Equal $reReleasedOwner.status "RELEASED" (
        "ForceRelease on re-claimed ACTIVE owner must succeed."
    )

    # Test Claim automatic feature-state.json projection and Tier parameter
    $tierTestFeature = New-TestFeature "OwnerTierTestFeature"
    $tierTestSpec = $tierTestFeature.Spec
    $tierSession = New-Session `
        -Feature $tierTestFeature `
        -Agent CLAUDE_CODE `
        -NativeSessionId "native-tier-test-1"
    New-Grant `
        -Feature $tierTestFeature `
        -Session $tierSession `
        -Operation Claim `
        -Agent CLAUDE_CODE `
        -OwnerId "tier-test-owner-1" `
        -Suffix "tier-default" | Out-Null
    
    # 1. Default Claim -> tier=T2, phase=CLAIMED, schema-valid
    Invoke-Owner `
        -Feature $tierTestFeature `
        -Operation Claim `
        -Workflow SUPERPOWERS `
        -Agent CLAUDE_CODE `
        -OwnerId "tier-test-owner-1" | Out-Null
    
    $featStatePath = Join-Path $tierTestSpec "feature-state.json"
    Assert-True (Test-Path -LiteralPath $featStatePath) "Claim must write feature-state.json"
    $fsContent = Get-Content -LiteralPath $featStatePath -Raw | ConvertFrom-Json
    Assert-Equal $fsContent.tier "T2" "Default Claim must write tier=T2"
    Assert-Equal $fsContent.phase "CLAIMED" "Claim must write phase=CLAIMED"
    Assert-Equal $fsContent.ownerSession.ownerId "tier-test-owner-1" "Claim must write ownerSession.ownerId"
    Assert-Equal $fsContent.ownerSession.agent "CLAUDE_CODE" "Claim must write ownerSession.agent"
    Assert-True (-not [string]::IsNullOrWhiteSpace($fsContent.updatedAt)) "Claim must write updatedAt"
    
    # 2. Release & Re-claim with explicit -Tier T3 -> writes tier=T3
    Invoke-Owner `
        -Feature $tierTestFeature `
        -Operation ForceRelease `
        -Workflow SUPERPOWERS `
        -Agent CLAUDE_CODE `
        -OwnerId "tier-test-owner-1" | Out-Null
    Remove-Item -LiteralPath $featStatePath -Force -ErrorAction SilentlyContinue
    
    $tierSession2 = New-Session `
        -Feature $tierTestFeature `
        -Agent CLAUDE_CODE `
        -NativeSessionId "native-tier-test-2"
    New-Grant `
        -Feature $tierTestFeature `
        -Session $tierSession2 `
        -Operation Claim `
        -Agent CLAUDE_CODE `
        -OwnerId "tier-test-owner-2" `
        -Suffix "tier-t3" | Out-Null
    
    Invoke-Owner `
        -Feature $tierTestFeature `
        -Operation Claim `
        -Workflow SUPERPOWERS `
        -Agent CLAUDE_CODE `
        -OwnerId "tier-test-owner-2" `
        -Tier "T3" | Out-Null
        
    $fsContent2 = Get-Content -LiteralPath $featStatePath -Raw | ConvertFrom-Json
    Assert-Equal $fsContent2.tier "T3" "Explicit Claim with -Tier T3 must write tier=T3"

    # 3. Test Complete with embedded VerifyCompletion
    # For $tierTestFeature (tier=T3, but no gates approved): Complete must fail because VerifyCompletion fails
    New-Grant `
        -Feature $tierTestFeature `
        -Session $tierSession2 `
        -Operation Complete `
        -Agent CLAUDE_CODE `
        -OwnerId "tier-test-owner-2" `
        -Suffix "complete-fail" | Out-Null
    
    Assert-Fails -Message "Complete must be rejected when VerifyCompletion fails on unapproved T3 feature." -Action {
        Invoke-Owner `
            -Feature $tierTestFeature `
            -Operation Complete `
            -Workflow SUPERPOWERS `
            -Agent CLAUDE_CODE `
            -OwnerId "tier-test-owner-2"
    }

    # Now change feature-state to T2 so VerifyCompletion passes
    $fsContent2.tier = "T2"
    $fsContent2.phase = "IMPLEMENTING"
    [System.IO.File]::WriteAllText($featStatePath, ($fsContent2 | ConvertTo-Json -Depth 10), $Utf8NoBom)
    
    # Since the previous transaction aborted before commit, the original Complete grant is still active and can be consumed
    Invoke-Owner `
        -Feature $tierTestFeature `
        -Operation Complete `
        -Workflow SUPERPOWERS `
        -Agent CLAUDE_CODE `
        -OwnerId "tier-test-owner-2" | Out-Null
        
    $completedOwner = Read-OwnerRecord "OwnerTierTestFeature"
    Assert-Equal $completedOwner.status "COMPLETE" "Complete must succeed once VerifyCompletion passes."

    # 4. Test Git baseline fork-point authoritative stamping
    $gitFeature = New-TestFeature "GitBaselineForkTest"
    $ws = $gitFeature.Workspace
    & git -C $ws init -b main 2>&1 | Out-Null
    & git -C $ws config user.email "test@example.com" 2>&1 | Out-Null
    & git -C $ws config user.name "Test" 2>&1 | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $ws "init.txt"), "init")
    & git -C $ws add init.txt 2>&1 | Out-Null
    & git -C $ws commit -m "initial commit on main" 2>&1 | Out-Null
    $mainSha = (& git -C $ws rev-parse HEAD 2>&1 | Out-String).Trim()

    # Create feature branch and add 2 commits
    & git -C $ws checkout -b feature/test-branch 2>&1 | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $ws "feat1.txt"), "feat1")
    & git -C $ws add feat1.txt 2>&1 | Out-Null
    & git -C $ws commit -m "feat 1" 2>&1 | Out-Null
    $feat1Sha = (& git -C $ws rev-parse HEAD 2>&1 | Out-String).Trim()

    [System.IO.File]::WriteAllText((Join-Path $ws "feat2.txt"), "feat2")
    & git -C $ws add feat2.txt 2>&1 | Out-Null
    & git -C $ws commit -m "feat 2" 2>&1 | Out-Null
    $feat2Sha = (& git -C $ws rev-parse HEAD 2>&1 | Out-String).Trim()

    $gitSession = New-Session -Feature $gitFeature -Agent CLAUDE_CODE -NativeSessionId "session-git-1"
    New-Grant -Feature $gitFeature -Session $gitSession -Operation Claim -Agent CLAUDE_CODE -OwnerId "git-owner-1" -Suffix "git-claim" | Out-Null

    # Claim WITHOUT passing -Baseline on feature branch: MUST record $mainSha (the fork-point), NOT $feat2Sha (HEAD)
    Invoke-Owner `
        -Feature $gitFeature `
        -Operation Claim `
        -Workflow SUPERPOWERS `
        -Agent CLAUDE_CODE `
        -OwnerId "git-owner-1" | Out-Null

    $gitOwnerRecord = Read-OwnerRecord "GitBaselineForkTest"
    Assert-Equal $gitOwnerRecord.baseline $mainSha "Claim without -Baseline on a feature branch must record trunk fork-point, not HEAD."

    # Test explicit mutation: BindSession with baseline ahead of fork-point must throw BASELINE_MUTATION_DETECTED
    $v1Feature = New-TestFeature "GitBaselineBindTest"
    $wsV1 = $v1Feature.Workspace
    & git -C $wsV1 init -b main 2>&1 | Out-Null
    & git -C $wsV1 config user.email "test@example.com" 2>&1 | Out-Null
    & git -C $wsV1 config user.name "Test" 2>&1 | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $wsV1 "init.txt"), "init")
    & git -C $wsV1 add init.txt 2>&1 | Out-Null
    & git -C $wsV1 commit -m "init" 2>&1 | Out-Null
    $v1MainSha = (& git -C $wsV1 rev-parse HEAD 2>&1 | Out-String).Trim()

    & git -C $wsV1 checkout -b feat/v1 2>&1 | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $wsV1 "feat.txt"), "feat")
    & git -C $wsV1 add feat.txt 2>&1 | Out-Null
    & git -C $wsV1 commit -m "feat" 2>&1 | Out-Null
    $v1FeatSha = (& git -C $wsV1 rev-parse HEAD 2>&1 | Out-String).Trim()

    # Pre-create 1.0 owner with trunk baseline
    $v1OwnerPath = Join-Path (Get-AiSopWorkflowOwnerRegistryRoot -WorkspacePath $wsV1) "gitbaselinebindtest.json"
    $v1OwnerObj = [ordered]@{
        schemaVersion = "1.0"
        feature = "GitBaselineBindTest"
        workflow = "SUPERPOWERS"
        agent = "CLAUDE_CODE"
        ownerId = "v1-owner"
        specDirectory = $v1Feature.Spec
        status = "ACTIVE"
        startedAt = [DateTimeOffset]::UtcNow.ToString("o")
        completedAt = ""
        baseline = $v1MainSha
    }
    [System.IO.File]::WriteAllText($v1OwnerPath, ($v1OwnerObj | ConvertTo-Json -Depth 10), $Utf8NoBom)

    $v1Session = New-Session -Feature $v1Feature -Agent CLAUDE_CODE -NativeSessionId "session-v1"
    New-Grant -Feature $v1Feature -Session $v1Session -Operation BindSession -Agent CLAUDE_CODE -OwnerId "v1-owner" -Suffix "v1-bind" | Out-Null

    Assert-Fails -Message "BindSession with baseline ahead of fork-point must throw BASELINE_MUTATION_DETECTED." -Action {
        & (Join-Path $PSScriptRoot "..\workflow-owner.ps1") `
            -Operation BindSession `
            -SpecDirectory $v1Feature.Spec `
            -Feature "GitBaselineBindTest" `
            -Workflow SUPERPOWERS `
            -Agent CLAUDE_CODE `
            -OwnerId "v1-owner" `
            -Baseline $v1FeatSha `
            -SessionKey $v1Session.Record.sessionKey `
            -SessionEpochId $v1Session.Record.sessionEpochId
    }

    # Negative Test: Git repository with multiple commits but no trunk branch throws BASELINE_MISSING on Claim without -Baseline
    $noTrunkRepo = Join-Path $TestRoot "no_trunk_repo"
    [System.IO.Directory]::CreateDirectory($noTrunkRepo) | Out-Null
    & git -C $noTrunkRepo init -b "feature-only" --quiet
    $dummyFile = Join-Path $noTrunkRepo "file1.txt"
    [System.IO.File]::WriteAllText($dummyFile, "hello 1`n", $Utf8NoBom)
    & git -C $noTrunkRepo add .
    & git -C $noTrunkRepo commit -m "c1" --quiet
    $dummyFile2 = Join-Path $noTrunkRepo "file2.txt"
    [System.IO.File]::WriteAllText($dummyFile2, "hello 2`n", $Utf8NoBom)
    & git -C $noTrunkRepo add .
    & git -C $noTrunkRepo commit -m "c2" --quiet

    $noTrunkWs = Join-Path $noTrunkRepo ".ai-workspace\specs\features\NoTrunkFeature"
    [System.IO.Directory]::CreateDirectory($noTrunkWs) | Out-Null
    $noTrunkFeatureObj = [pscustomobject]@{
        Feature = "NoTrunkFeature"
        Workspace = (Resolve-PhysicalPathIdentity -Path $noTrunkRepo)
        Spec = $noTrunkWs
    }

    $noTrunkSession = New-Session -Feature $noTrunkFeatureObj -Agent CLAUDE_CODE -NativeSessionId "session-notrunk"
    New-Grant -Feature $noTrunkFeatureObj -Session $noTrunkSession -Operation Claim -Agent CLAUDE_CODE -OwnerId "notrunk-owner" -Suffix "notrunk-claim" | Out-Null

    Assert-Fails -Message "Claim without -Baseline on repo with no trunk branch must throw BASELINE_MISSING." -Action {
        & (Join-Path $PSScriptRoot "..\workflow-owner.ps1") `
            -Operation Claim `
            -SpecDirectory $noTrunkWs `
            -Feature "NoTrunkFeature" `
            -Workflow SUPERPOWERS `
            -Agent CLAUDE_CODE `
            -OwnerId "notrunk-owner" `
            -SessionKey $noTrunkSession.Record.sessionKey `
            -SessionEpochId $noTrunkSession.Record.sessionEpochId
    }

    Write-Output "All workflow owner tests passed."
} finally {
    foreach ($name in @(
        "SERVER_NEW_WORKFLOW_REGISTRY",
        "SERVER_NEW_WORKFLOW_SESSION_REGISTRY",
        "SERVER_NEW_WORKFLOW_COMMAND_GRANT_REGISTRY",
        "SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY"
    )) {
        Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $TestRoot) {
        try {
            Get-ChildItem -LiteralPath $TestRoot -Recurse -Force | ForEach-Object {
                if ($_.Attributes -band [System.IO.FileAttributes]::ReadOnly) {
                    $_.Attributes = $_.Attributes -bxor [System.IO.FileAttributes]::ReadOnly
                }
            }
            Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
        } catch {}
    }
}
