#requires -Version 7.0

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"

$ScriptsRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $ScriptsRoot "hidden-process.ps1")
$SessionScript = Join-Path $ScriptsRoot "workflow-session.ps1"
$GrantScript = Join-Path $ScriptsRoot "workflow-command-grant.ps1"
$ClaudeRoot = Split-Path -Parent $ScriptsRoot
$GrantSchema = Join-Path $ClaudeRoot "schemas\workflow-command-grant.schema.json"
$UnapprovedGrantActiveIndexSchema = Join-Path (
    $ClaudeRoot
) "schemas\workflow-command-grant-active-index.schema.json"
$TestRoot = Join-Path ([System.IO.Path]::GetTempPath()) (
    "workflow-command-grant-tests-" + [guid]::NewGuid().ToString("N")
)
$env:SERVER_NEW_WORKFLOW_SESSION_REGISTRY = Join-Path $TestRoot "sessions"
$env:SERVER_NEW_WORKFLOW_COMMAND_GRANT_REGISTRY = Join-Path $TestRoot "grants"
$env:SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY = Join-Path $TestRoot "transactions"
$env:SERVER_NEW_WORKFLOW_REGISTRY = Join-Path $TestRoot "owners"
$t0 = [DateTimeOffset]::Parse("2026-08-17T11:00:00.0000000Z")

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

function Assert-ThrowsCode {
    param([scriptblock]$Action, [string]$Code, [string]$Message)

    $actual = ""
    try {
        & $Action | Out-Null
    } catch {
        $actual = $_.Exception.Message
    }
    if ($actual -cne $Code) {
        throw "$Message Expected error '$Code', got '$actual'."
    }
}

function New-TestWorkspace {
    param([string]$Name)

    $workspace = Join-Path $TestRoot $Name
    [System.IO.Directory]::CreateDirectory(
        (Join-Path $workspace ".ai-sop\scripts")
    ) | Out-Null
    return $workspace
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

function New-ConfirmedSession {
    param(
        [string]$Workspace,
        [string]$Agent,
        [string]$NativeSessionId,
        [DateTimeOffset]$AcceptedAt = $t0
    )

    $session = Invoke-AiSopWorkflowSession `
        -Operation Register `
        -Agent $Agent `
        -NativeSessionId $NativeSessionId `
        -WorkspacePath $Workspace `
        -LifecycleProof CONFIRMED `
        -AcceptedAt $AcceptedAt
    Assert-Equal $session.Record.stateChangedAt (
        $AcceptedAt.ToUniversalTime().ToString("o")
    ) "Grant test session fixture did not initialize stateChangedAt."
    return $session
}

function Write-TestOwner {
    param(
        [string]$Workspace,
        [string]$Feature,
        [string]$Agent,
        [string]$OwnerId,
        [object]$Session,
        [ValidateSet("1.0", "1.1")]
        [string]$SchemaVersion = "1.1"
    )

    [System.IO.Directory]::CreateDirectory($env:SERVER_NEW_WORKFLOW_REGISTRY) |
        Out-Null
    $spec = Join-Path $Workspace ".ai-workspace\specs\features\$Feature"
    $owner = [ordered]@{
        schemaVersion = $SchemaVersion
        feature = $Feature
        workflow = "SUPERPOWERS"
        agent = $Agent
        ownerId = $OwnerId
        specDirectory = [System.IO.Path]::GetFullPath($spec)
        status = "ACTIVE"
        startedAt = $t0.AddMinutes(-1).ToString("o")
        completedAt = ""
        baseline = "0"
    }
    if ($SchemaVersion -eq "1.1") {
        $owner.workspacePath = [System.IO.Path]::GetFullPath($Workspace)
        $owner.sessionBinding = [ordered]@{
            sessionKey = [string]$Session.sessionKey
            sessionEpochId = [string]$Session.sessionEpochId
            boundAt = $t0.AddMinutes(-1).ToString("o")
        }
        $owner.lastTransactionId = "test-owner-state"
    }
    [System.IO.File]::WriteAllText(
        (Join-Path $env:SERVER_NEW_WORKFLOW_REGISTRY (
            $Feature.ToLowerInvariant() + ".json"
        )),
        ($owner | ConvertTo-Json -Depth 30),
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Issue-Grant {
    param(
        [string]$CommandText,
        [object]$Session,
        [string]$DedupKey,
        [DateTimeOffset]$IssuedAt,
        [string]$TransactionId,
        [int]$GrantTtlSeconds = 10
    )

    return Invoke-AiSopWorkflowCommandGrant `
        -Operation Issue `
        -CommandText $CommandText `
        -SessionKey $Session.Record.sessionKey `
        -SessionEpochId $Session.Record.sessionEpochId `
        -DedupKey $DedupKey `
        -AcceptedAt $IssuedAt `
        -TransactionId $TransactionId `
        -GrantTtlSeconds $GrantTtlSeconds
}

function Find-Grant {
    param(
        [string]$Workspace,
        [string]$GrantOperation,
        [string]$Feature,
        [string]$Workflow,
        [string]$Agent,
        [string]$OwnerId,
        [DateTimeOffset]$AcceptedAt
    )

    return Invoke-AiSopWorkflowCommandGrant `
        -Operation Find `
        -GrantOperation $GrantOperation `
        -SpecDirectory (Join-Path $Workspace ".ai-workspace\specs\features\$Feature") `
        -Feature $Feature `
        -Workflow $Workflow `
        -Agent $Agent `
        -OwnerId $OwnerId `
        -AcceptedAt $AcceptedAt
}

try {
    foreach ($requiredPath in @(
        $SessionScript,
        $GrantScript,
        $GrantSchema
    )) {
        if (-not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
            throw "Required Task 3 artifact does not exist: $requiredPath"
        }
    }
    Assert-True (
        -not (
            Test-Path `
                -LiteralPath $UnapprovedGrantActiveIndexSchema `
                -PathType Leaf
        )
    ) "Fix Round 3 retained an unapproved active-index schema file."
    . $SessionScript
    . $GrantScript
    $grantFixtureRoot = Join-Path (
        $PSScriptRoot
    ) "fixtures\workflow-command-grants"
    foreach ($fixtureName in @("claim-issued.json", "claim-consumed.json")) {
        $fixturePath = Join-Path $grantFixtureRoot $fixtureName
        if (-not (Test-Path -LiteralPath $fixturePath -PathType Leaf)) {
            throw "Required Task 3 fixture does not exist: $fixturePath"
        }
        Assert-True (
            [System.IO.File]::ReadAllText($fixturePath) |
                Test-Json -SchemaFile $GrantSchema
        ) "Command grant fixture is schema-invalid: $fixtureName"
    }
    $ambiguousFixturePath = Join-Path $grantFixtureRoot "claim-ambiguous.json"
    if (-not (Test-Path -LiteralPath $ambiguousFixturePath -PathType Leaf)) {
        throw "Required Task 3 fixture does not exist: $ambiguousFixturePath"
    }
    $ambiguousFixture = ConvertFrom-AiSopWorkflowJson `
        -Json ([System.IO.File]::ReadAllText($ambiguousFixturePath))
    Assert-Equal @($ambiguousFixture).Count 2 (
        "Ambiguous command grant fixture must contain two records."
    )
    foreach ($fixtureGrant in @($ambiguousFixture)) {
        Assert-True (
            ($fixtureGrant | ConvertTo-Json -Depth 30) |
                Test-Json -SchemaFile $GrantSchema
        ) "Ambiguous command grant fixture contains an invalid record."
    }
    foreach ($functionName in @(
        "ConvertFrom-AiSopOwnerCommandIntent",
        "Get-AiSopOwnerIntentSha256",
        "Get-AiSopWorkflowCommandGrantActiveIndexPath",
        "Get-AiSopWorkflowCommandGrantSessionIndexPath",
        "Get-AiSopWorkflowCommandGrantPlan",
        "Invoke-AiSopWorkflowCommandGrant",
        "Get-AiSopWorkflowCommandGrantProofState",
        "Test-AiSopWorkflowCommandGrantProof"
    )) {
        Assert-True ($null -ne (Get-Command $functionName -ErrorAction SilentlyContinue)) (
            "Command grant API is missing $functionName."
        )
    }

    # Every supported harness may issue a grant only from its own active session.
    foreach ($agent in @("CLAUDE_CODE", "COPILOT", "ANTIGRAVITY", "CURSOR")) {
        $workspace = New-TestWorkspace "workspace-$($agent.ToLowerInvariant())"
        $feature = "Feature$($agent.Replace('_', ''))"
        [System.IO.Directory]::CreateDirectory(
            (Join-Path $workspace ".ai-workspace\specs\features\$feature")
        ) | Out-Null
        $session = New-ConfirmedSession `
            -Workspace $workspace `
            -Agent $agent `
            -NativeSessionId "native-$agent"
        $command = New-OwnerCommand `
            -Operation Claim `
            -Feature $feature `
            -Workflow SUPERPOWERS `
            -Agent $agent `
            -OwnerId "owner-$($agent.ToLowerInvariant())"
        $dedupKey = Get-AiSopWorkflowSha256 "dedup-$agent"
        $transactionId = "grant-$($agent.ToLowerInvariant())"
        $grant = Issue-Grant `
            -CommandText $command `
            -Session $session `
            -DedupKey $dedupKey `
            -IssuedAt $t0 `
            -TransactionId $transactionId

        Assert-Equal $grant.Record.status "ISSUED" (
            "$agent grant was not ISSUED."
        )
        Assert-Equal $grant.Record.agent $agent "$agent grant identity mismatch."
        Assert-Equal $grant.Record.sessionKey $session.Record.sessionKey (
            "$agent grant session binding mismatch."
        )
        Assert-Equal (
            [DateTimeOffset]::Parse($grant.Record.expiresAt)
        ) $t0.AddSeconds(10) "$agent grant TTL is not exactly 10 seconds."
        # Explicit GrantTtlSeconds must override the 10s default (used by Pi
        # bootstrap, whose grant is consumed on a later tool-call).
        $customTtl = Issue-Grant `
            -CommandText $command `
            -Session $session `
            -DedupKey (Get-AiSopWorkflowSha256 "dedup-$agent-customttl") `
            -IssuedAt $t0 `
            -TransactionId "grant-$($agent.ToLowerInvariant())-customttl" `
            -GrantTtlSeconds 120
        Assert-Equal (
            [DateTimeOffset]::Parse($customTtl.Record.expiresAt)
        ) $t0.AddSeconds(120) "$agent custom GrantTtlSeconds not honored."
        $rawGrant = [System.IO.File]::ReadAllText($grant.GrantPath)
        Assert-True ($rawGrant | Test-Json -SchemaFile $GrantSchema) (
            "$agent grant does not satisfy schema."
        )
        Assert-True (
            $rawGrant -notmatch
                "native-$agent|token|secret|rawPayload|commandText|transcript"
        ) "$agent grant leaked native identity, command text, or secret."

        $duplicate = Issue-Grant `
            -CommandText $command `
            -Session $session `
            -DedupKey $dedupKey `
            -IssuedAt $t0.AddSeconds(1) `
            -TransactionId $transactionId
        Assert-Equal $duplicate.Record.grantId $grant.Record.grantId (
            "Duplicate hook did not reuse deterministic grantId for $agent."
        )
        Assert-Equal $duplicate.Record.expiresAt $grant.Record.expiresAt (
            "Duplicate hook renewed grant TTL for $agent."
        )
        Assert-Equal $duplicate.Mutated $false (
            "Duplicate hook rewrote grant for $agent."
        )
    }

    # Task 2 PREPARED reconciliation uses only durable transactionId proof and
    # forwards its shared absolute deadline and remaining budget.
    $proofWorkspace = New-TestWorkspace "proof-workspace"
    $proofFeature = "ProofFeature"
    [System.IO.Directory]::CreateDirectory(
        (Join-Path $proofWorkspace ".ai-workspace\specs\features\$proofFeature")
    ) | Out-Null
    $proofSession = New-ConfirmedSession `
        -Workspace $proofWorkspace `
        -Agent CURSOR `
        -NativeSessionId "proof-native-session"
    $proofCommand = New-OwnerCommand `
        -Operation Claim `
        -Feature $proofFeature `
        -Workflow SUPERPOWERS `
        -Agent CURSOR `
        -OwnerId "proof-owner"
    $proofTransactionId = "proof-issue-transaction"
    $grantCountBeforePlan = @(
        Get-ChildItem `
            -LiteralPath $env:SERVER_NEW_WORKFLOW_COMMAND_GRANT_REGISTRY `
            -Filter *.json -File -ErrorAction SilentlyContinue
    ).Count
    $proofPlan = Get-AiSopWorkflowCommandGrantPlan `
        -CommandText $proofCommand `
        -SessionKey $proofSession.Record.sessionKey `
        -SessionEpochId $proofSession.Record.sessionEpochId `
        -DedupKey (Get-AiSopWorkflowSha256 "proof-dedup") `
        -AcceptedAt $t0
    Assert-Equal @(
        Get-ChildItem `
            -LiteralPath $env:SERVER_NEW_WORKFLOW_COMMAND_GRANT_REGISTRY `
            -Filter *.json -File -ErrorAction SilentlyContinue
    ).Count $grantCountBeforePlan (
        "Pure grant planning wrote command-grant state."
    )
    $proofGrant = Issue-Grant `
        -CommandText $proofCommand `
        -Session $proofSession `
        -DedupKey (Get-AiSopWorkflowSha256 "proof-dedup") `
        -IssuedAt $t0 `
        -TransactionId $proofTransactionId
    $proofIntentIndexPath = Get-AiSopWorkflowCommandGrantActiveIndexPath `
        -IntentSha256 $proofGrant.Record.intentSha256
    $proofSessionIndexPath = Get-AiSopWorkflowCommandGrantSessionIndexPath `
        -SessionKey $proofGrant.Record.sessionKey `
        -SessionEpochId $proofGrant.Record.sessionEpochId
    Assert-True (
        [System.IO.File]::ReadAllText($proofIntentIndexPath) |
            Test-Json -SchemaFile $GrantSchema
    ) "Intent index does not satisfy the approved command-grant schema."
    Assert-True (
        [System.IO.File]::ReadAllText($proofSessionIndexPath) |
            Test-Json -SchemaFile $GrantSchema
    ) "Session index does not satisfy the approved command-grant schema."
    Assert-Equal $proofPlan.GrantId $proofGrant.Record.grantId (
        "Task 4 grant plan and Issue computed different grantId values."
    )
    Assert-Equal $proofPlan.IntentSha256 $proofGrant.Record.intentSha256 (
        "Task 4 grant plan and Issue computed different intent hashes."
    )
    $proofIssuedMarker = Get-AiSopWorkflowCommandGrantMarkerPath `
        -IntentSha256 $proofGrant.Record.intentSha256 `
        -GrantId $proofGrant.Record.grantId `
        -MarkerKind issued
    [System.IO.File]::Delete($proofIssuedMarker)
    Assert-Equal (
        Get-AiSopWorkflowCommandGrantProofState `
            -TransactionId $proofTransactionId `
            -GrantId $proofGrant.Record.grantId `
            -DeadlineUtc ([DateTimeOffset]::UtcNow.AddSeconds(2)) `
            -RemainingMilliseconds 1500
    ) "INDETERMINATE" "Partial issuance incorrectly proved APPLIED."
    $proofReplay = Issue-Grant `
        -CommandText $proofCommand `
        -Session $proofSession `
        -DedupKey (Get-AiSopWorkflowSha256 "proof-dedup") `
        -IssuedAt $t0.AddMilliseconds(1) `
        -TransactionId $proofTransactionId
    Assert-Equal $proofReplay.Mutated $false (
        "Strong-kill issuance replay forked or rewrote the grant."
    )
    $proofDeadline = [DateTimeOffset]::UtcNow.AddSeconds(2)
    $proofRemaining = [int64][Math]::Floor(
        ($proofDeadline - [DateTimeOffset]::UtcNow).TotalMilliseconds
    )
    $reconcileState = Get-AiSopWorkflowCommandGrantProofState `
        -TransactionId $proofTransactionId `
        -GrantId $proofGrant.Record.grantId `
        -DeadlineUtc $proofDeadline `
        -RemainingMilliseconds $proofRemaining
    Assert-Equal $reconcileState "APPLIED" (
        "Task 2 reconciliation could not prove the issued grant transaction."
    )
    foreach ($partialIndexPath in @(
        $proofIntentIndexPath,
        $proofSessionIndexPath
    )) {
        [System.IO.File]::Delete($partialIndexPath)
        Assert-Equal (
            Get-AiSopWorkflowCommandGrantProofState `
                -TransactionId $proofTransactionId `
                -GrantId $proofGrant.Record.grantId `
                -DeadlineUtc ([DateTimeOffset]::UtcNow.AddSeconds(2)) `
                -RemainingMilliseconds 1500
        ) "INDETERMINATE" "Partial index write incorrectly proved APPLIED."
        Assert-ThrowsCode `
            -Code $(if (
                $partialIndexPath -eq $proofIntentIndexPath
            ) {
                "COMMAND_GRANT_NOT_FOUND"
            } else {
                "COMMAND_GRANT_CORRUPT"
            }) `
            -Message "ISSUED grant missing an index did not fail closed." `
            -Action {
                Find-Grant `
                    -Workspace $proofWorkspace `
                    -GrantOperation Claim `
                    -Feature $proofFeature `
                    -Workflow SUPERPOWERS `
                    -Agent CURSOR `
                    -OwnerId "proof-owner" `
                    -AcceptedAt $t0.AddMilliseconds(2)
            }
        $partialReplay = Issue-Grant `
            -CommandText $proofCommand `
            -Session $proofSession `
            -DedupKey (Get-AiSopWorkflowSha256 "proof-dedup") `
            -IssuedAt $t0.AddMilliseconds(2) `
            -TransactionId $proofTransactionId
        Assert-Equal $partialReplay.Mutated $false (
            "Partial index recovery rewrote the immutable grant."
        )
        Assert-Equal (
            Get-AiSopWorkflowCommandGrantProofState `
                -TransactionId $proofTransactionId `
                -GrantId $proofGrant.Record.grantId `
                -DeadlineUtc ([DateTimeOffset]::UtcNow.AddSeconds(2)) `
                -RemainingMilliseconds 1500
        ) "APPLIED" "Issue replay did not rebuild the missing bounded index."
    }
    Assert-Equal (
        Get-AiSopWorkflowCommandGrantProofState `
            -TransactionId "proof-never-applied" `
            -GrantId ("9" * 64) `
            -DeadlineUtc $proofDeadline `
            -RemainingMilliseconds $proofRemaining
    ) "NOT_APPLIED" (
        "Task 2 reconciliation cannot safely retry an absent grant transaction."
    )
    Assert-Equal (
        Get-AiSopWorkflowCommandGrantProofState `
            -TransactionId $proofTransactionId `
            -GrantId $proofGrant.Record.grantId `
            -DeadlineUtc ([DateTimeOffset]::UtcNow.AddMilliseconds(-1)) `
            -RemainingMilliseconds 0
    ) "INDETERMINATE" "Grant transaction proof ignored the passed deadline."

    $laterProofFeature = "LaterProofFeature"
    [System.IO.Directory]::CreateDirectory(
        (Join-Path $proofWorkspace ".ai-workspace\specs\features\$laterProofFeature")
    ) | Out-Null
    $laterProofCommand = New-OwnerCommand `
        -Operation Claim `
        -Feature $laterProofFeature `
        -Workflow SUPERPOWERS `
        -Agent CURSOR `
        -OwnerId "later-proof-owner"
    Issue-Grant `
        -CommandText $laterProofCommand `
        -Session $proofSession `
        -DedupKey (Get-AiSopWorkflowSha256 "later-proof-dedup") `
        -IssuedAt $t0.AddSeconds(1) `
        -TransactionId "later-proof-transaction" |
        Out-Null
    Assert-Equal (
        Get-AiSopWorkflowCommandGrantProofState `
            -TransactionId $proofTransactionId `
            -GrantId $proofGrant.Record.grantId `
            -DeadlineUtc ([DateTimeOffset]::UtcNow.AddSeconds(2)) `
            -RemainingMilliseconds 1500
    ) "APPLIED" "A later grant invalidated immutable issuance proof."
    Invoke-AiSopWorkflowCommandGrant `
        -Operation Consume `
        -GrantId $proofGrant.Record.grantId `
        -AcceptedAt $t0.AddSeconds(2) `
        -TransactionId "proof-consume-transaction" |
        Out-Null
    $consumedProofRecord = Get-Content -LiteralPath $proofGrant.GrantPath -Raw |
        ConvertFrom-Json
    Assert-Equal $consumedProofRecord.issuedTransactionId $proofTransactionId (
        "Grant consumption overwrote issuedTransactionId."
    )
    Assert-Equal $consumedProofRecord.consumedTransactionId (
        "proof-consume-transaction"
    ) "Grant consumption did not persist its separate transaction identity."
    Assert-Equal (
        Get-AiSopWorkflowCommandGrantProofState `
            -TransactionId $proofTransactionId `
            -GrantId $proofGrant.Record.grantId `
            -DeadlineUtc ([DateTimeOffset]::UtcNow.AddSeconds(2)) `
            -RemainingMilliseconds 1500
    ) "APPLIED" "Grant consumption invalidated immutable issuance proof."

    $savedIntentIndex = [System.IO.File]::ReadAllText($proofIntentIndexPath)
    [System.IO.File]::Delete($proofIntentIndexPath)
    Assert-Equal (
        Get-AiSopWorkflowCommandGrantProofState `
            -TransactionId $proofTransactionId `
            -GrantId $proofGrant.Record.grantId `
            -DeadlineUtc ([DateTimeOffset]::UtcNow.AddSeconds(2)) `
            -RemainingMilliseconds 1500
    ) "INDETERMINATE" "Missing intent index incorrectly proved Issue APPLIED."
    [System.IO.File]::WriteAllText(
        $proofIntentIndexPath,
        $savedIntentIndex,
        [System.Text.UTF8Encoding]::new($false)
    )
    $savedSessionIndex = [System.IO.File]::ReadAllText($proofSessionIndexPath)
    [System.IO.File]::Delete($proofSessionIndexPath)
    Assert-Equal (
        Get-AiSopWorkflowCommandGrantProofState `
            -TransactionId $proofTransactionId `
            -GrantId $proofGrant.Record.grantId `
            -DeadlineUtc ([DateTimeOffset]::UtcNow.AddSeconds(2)) `
            -RemainingMilliseconds 1500
    ) "INDETERMINATE" "Missing session index incorrectly proved Issue APPLIED."
    [System.IO.File]::WriteAllText(
        $proofSessionIndexPath,
        $savedSessionIndex,
        [System.Text.UTF8Encoding]::new($false)
    )

    # Same-native-session Rebind derives a deterministic next epoch so a
    # PREPARED NOT_APPLIED retry cannot fork grants or epochs.
    $rebindWorkspace = New-TestWorkspace "rebind-workspace"
    $rebindFeature = "RebindFeature"
    [System.IO.Directory]::CreateDirectory(
        (Join-Path $rebindWorkspace ".ai-workspace\specs\features\$rebindFeature")
    ) | Out-Null
    $rebindSession = New-ConfirmedSession `
        -Workspace $rebindWorkspace `
        -Agent CURSOR `
        -NativeSessionId "rebind-native-session"
    $rebindSessionPath = Get-AiSopWorkflowSessionPath (
        $rebindSession.Record.sessionKey
    )
    $rebindRecord = ConvertFrom-AiSopWorkflowJson `
        -Json ([System.IO.File]::ReadAllText($rebindSessionPath)) `
        -AsHashtable
    $rebindRecord.boundFeature = $rebindFeature
    $rebindRecord.boundWorkflow = "SUPERPOWERS"
    $rebindRecord.boundOwnerId = "rebind-owner"
    $rebindRecord.boundSessionEpochId = $rebindRecord.sessionEpochId
    $rebindRecord.expiresAt = $t0.AddSeconds(-1).ToString("o")
    [System.IO.File]::WriteAllText(
        $rebindSessionPath,
        ($rebindRecord | ConvertTo-Json -Depth 30),
        [System.Text.UTF8Encoding]::new($false)
    )
    Write-TestOwner `
        -Workspace $rebindWorkspace `
        -Feature $rebindFeature `
        -Agent CURSOR `
        -OwnerId "rebind-owner" `
        -Session $rebindRecord
    $rebindCommand = New-OwnerCommand `
        -Operation RebindSession `
        -Feature $rebindFeature `
        -Workflow SUPERPOWERS `
        -Agent CURSOR `
        -OwnerId "rebind-owner"
    $rebindDedup = Get-AiSopWorkflowSha256 "rebind-dedup"
    $rebindFirst = Invoke-AiSopWorkflowCommandGrant `
        -Operation Issue `
        -CommandText $rebindCommand `
        -SessionKey $rebindSession.Record.sessionKey `
        -SessionEpochId $rebindSession.Record.sessionEpochId `
        -DedupKey $rebindDedup `
        -AcceptedAt $t0 `
        -TransactionId "rebind-proof-transaction"
    $rebindRetry = Invoke-AiSopWorkflowCommandGrant `
        -Operation Issue `
        -CommandText $rebindCommand `
        -SessionKey $rebindSession.Record.sessionKey `
        -SessionEpochId $rebindSession.Record.sessionEpochId `
        -DedupKey $rebindDedup `
        -AcceptedAt $t0.AddSeconds(1) `
        -TransactionId "rebind-proof-transaction"
    Assert-Equal $rebindRetry.Record.sessionEpochId (
        $rebindFirst.Record.sessionEpochId
    ) "Rebind retry forked the proposed session epoch."
    Assert-Equal $rebindRetry.Record.grantId $rebindFirst.Record.grantId (
        "Rebind retry forked the deterministic grantId."
    )
    Assert-Equal $rebindRetry.Mutated $false (
        "Rebind retry wrote a second command grant."
    )
    $endedRebindRecord = ConvertFrom-AiSopWorkflowJson `
        -Json ([System.IO.File]::ReadAllText($rebindSessionPath)) `
        -AsHashtable
    $endedRebindRecord.status = "ENDED"
    $endedRebindRecord.endedAt = $t0.ToString("o")
    $endedRebindRecord.expiresAt = $t0.AddMinutes(30).ToString("o")
    [System.IO.File]::WriteAllText(
        $rebindSessionPath,
        ($endedRebindRecord | ConvertTo-Json -Depth 30),
        [System.Text.UTF8Encoding]::new($false)
    )
    $endedRebindGrant = Invoke-AiSopWorkflowCommandGrant `
        -Operation Issue `
        -CommandText $rebindCommand `
        -SessionKey $rebindSession.Record.sessionKey `
        -SessionEpochId $rebindSession.Record.sessionEpochId `
        -DedupKey (Get-AiSopWorkflowSha256 "ended-rebind-dedup") `
        -AcceptedAt $t0.AddSeconds(2) `
        -TransactionId "ended-rebind-transaction"
    Assert-True (
        $endedRebindGrant.Record.sessionEpochId -cne
            $rebindSession.Record.sessionEpochId
    ) "An ENDED bound session did not mint a replacement Rebind epoch."

    # Focused RED: the first End persists ENDED but times out on the held exact
    # session index; the second End must still finish both-index deactivation.
    $endRetryFeature = "FocusedEndRetryFeature"
    [System.IO.Directory]::CreateDirectory(
        (Join-Path $rebindWorkspace ".ai-workspace\specs\features\$endRetryFeature")
    ) | Out-Null
    $endRetrySession = New-ConfirmedSession `
        -Workspace $rebindWorkspace `
        -Agent CURSOR `
        -NativeSessionId "focused-end-retry"
    $endRetryGrant = Issue-Grant `
        -CommandText (New-OwnerCommand `
            -Operation Claim `
            -Feature $endRetryFeature `
            -Workflow SUPERPOWERS `
            -Agent CURSOR `
            -OwnerId "focused-end-retry-owner") `
        -Session $endRetrySession `
        -DedupKey (Get-AiSopWorkflowSha256 "focused-end-retry-dedup") `
        -IssuedAt $t0 `
        -TransactionId "focused-end-retry-issue"
    $endRetrySessionIndex =
        Get-AiSopWorkflowCommandGrantSessionIndexPath `
            -SessionKey $endRetryGrant.Record.sessionKey `
            -SessionEpochId $endRetryGrant.Record.sessionEpochId
    $endRetryLock = [System.IO.File]::Open(
        $endRetrySessionIndex + ".lock",
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    try {
        Assert-ThrowsCode -Code "WORKFLOW_LOCK_TIMEOUT" `
            -Message "Held session index did not interrupt first SessionEnd." `
            -Action {
                Invoke-AiSopWorkflowSession `
                    -Operation End `
                    -Agent CURSOR `
                    -NativeSessionId "focused-end-retry" `
                    -WorkspacePath $rebindWorkspace `
                    -AcceptedAt $t0.AddSeconds(1) `
                    -DeadlineUtc (
                        [DateTimeOffset]::UtcNow.AddMilliseconds(100)
                    )
            }
    } finally {
        $endRetryLock.Dispose()
        [System.IO.File]::Delete($endRetrySessionIndex + ".lock")
    }
    Invoke-AiSopWorkflowSession `
        -Operation End `
        -Agent CURSOR `
        -NativeSessionId "focused-end-retry" `
        -WorkspacePath $rebindWorkspace `
        -AcceptedAt $t0.AddSeconds(2) `
        -IsDuplicate |
        Out-Null
    $endRetryIndex = Get-Content -LiteralPath $endRetrySessionIndex -Raw |
        ConvertFrom-Json
    Assert-Equal @(
        $endRetryIndex.entries | Where-Object { $_.active }
    ).Count 0 "Repeated SessionEnd skipped exact-epoch index cleanup."

    # Rebind Issue is an exact handoff gate. Validate every old-session bound
    # field and the Owner physical workspace as independent single mutations.
    $rebindNewSession = New-ConfirmedSession `
        -Workspace $rebindWorkspace `
        -Agent CURSOR `
        -NativeSessionId "rebind-new-native-session" `
        -AcceptedAt $t0
    $rebindIntent = ConvertFrom-AiSopOwnerCommandIntent `
        -CommandText $rebindCommand `
        -WorkspacePath $rebindWorkspace
    $rebindOwnerPath = Join-Path $env:SERVER_NEW_WORKFLOW_REGISTRY (
        $rebindFeature.ToLowerInvariant() + ".json"
    )
    $rebindOwner = ConvertFrom-AiSopWorkflowJson `
        -Json ([System.IO.File]::ReadAllText($rebindOwnerPath)) `
        -AsHashtable
    Assert-AiSopWorkflowCommandGrantIssueGate `
        -Intent $rebindIntent `
        -Session (
            ConvertFrom-AiSopWorkflowJson `
                -Json ($rebindNewSession.Record | ConvertTo-Json -Depth 30) `
                -AsHashtable
        ) `
        -Owner $rebindOwner `
        -OldSession $endedRebindRecord `
        -AcceptedAt $t0.AddSeconds(2)
    $rebindGateFailures = [System.Collections.Generic.List[string]]::new()
    foreach ($rebindMutation in @(
        [pscustomobject]@{
            Name = "owner.workspacePath"
            OwnerField = "workspacePath"
            OwnerValue = New-TestWorkspace "rebind-wrong-owner-workspace"
            SessionField = ""
            SessionValue = ""
        },
        [pscustomobject]@{
            Name = "oldSession.boundFeature"
            OwnerField = ""
            OwnerValue = ""
            SessionField = "boundFeature"
            SessionValue = "OtherRebindFeature"
        },
        [pscustomobject]@{
            Name = "oldSession.boundWorkflow"
            OwnerField = ""
            OwnerValue = ""
            SessionField = "boundWorkflow"
            SessionValue = "CUSTOM_SKILLS"
        },
        [pscustomobject]@{
            Name = "oldSession.boundOwnerId"
            OwnerField = ""
            OwnerValue = ""
            SessionField = "boundOwnerId"
            SessionValue = "other-rebind-owner"
        },
        [pscustomobject]@{
            Name = "oldSession.boundSessionEpochId"
            OwnerField = ""
            OwnerValue = ""
            SessionField = "boundSessionEpochId"
            SessionValue = "other-rebind-epoch"
        }
    )) {
        $mutatedOwner = ConvertFrom-AiSopWorkflowJson `
            -Json ($rebindOwner | ConvertTo-Json -Depth 30) `
            -AsHashtable
        $mutatedOldSession = ConvertFrom-AiSopWorkflowJson `
            -Json ($endedRebindRecord | ConvertTo-Json -Depth 30) `
            -AsHashtable
        if (-not [string]::IsNullOrEmpty($rebindMutation.OwnerField)) {
            $mutatedOwner[$rebindMutation.OwnerField] =
                $rebindMutation.OwnerValue
        }
        if (-not [string]::IsNullOrEmpty($rebindMutation.SessionField)) {
            $mutatedOldSession[$rebindMutation.SessionField] =
                $rebindMutation.SessionValue
        }
        try {
            Assert-AiSopWorkflowCommandGrantIssueGate `
                -Intent $rebindIntent `
                -Session (
                    ConvertFrom-AiSopWorkflowJson `
                        -Json ($rebindNewSession.Record |
                            ConvertTo-Json -Depth 30) `
                        -AsHashtable
                ) `
                -Owner $mutatedOwner `
                -OldSession $mutatedOldSession `
                -AcceptedAt $t0.AddSeconds(2)
            $rebindGateFailures.Add($rebindMutation.Name)
        } catch {
            if (
                $_.Exception.Message -cne
                    "COMMAND_GRANT_OWNER_STATE_INVALID"
            ) {
                throw
            }
        }
    }
    Assert-Equal $rebindGateFailures.Count 0 (
        "Rebind Issue gate accepted wrong exact tuple fields: " +
        ($rebindGateFailures -join ", ")
    )

    $workspace = New-TestWorkspace "main-workspace"
    $feature = "FixtureFeature"
    $specDirectory = Join-Path $workspace ".ai-workspace\specs\features\$feature"
    [System.IO.Directory]::CreateDirectory($specDirectory) | Out-Null
    $command = New-OwnerCommand `
        -Operation Claim `
        -Feature $feature `
        -Workflow SUPERPOWERS `
        -Agent CURSOR `
        -OwnerId "fixture-owner-0001"
    $firstSession = New-ConfirmedSession `
        -Workspace $workspace `
        -Agent CURSOR `
        -NativeSessionId "cursor-main-A"
    foreach ($deniedOperation in @(
        "BindSession",
        "RebindSession",
        "Validate",
        "Complete"
    )) {
        $deniedFeature = "Denied$deniedOperation"
        [System.IO.Directory]::CreateDirectory(
            (Join-Path $workspace ".ai-workspace\specs\features\$deniedFeature")
        ) | Out-Null
        Assert-ThrowsCode -Code "COMMAND_GRANT_OWNER_STATE_INVALID" `
            -Message "$deniedOperation issued without its exact Owner state." `
            -Action {
                Issue-Grant `
                    -CommandText (New-OwnerCommand `
                        -Operation $deniedOperation `
                        -Feature $deniedFeature `
                        -Workflow SUPERPOWERS `
                        -Agent CURSOR `
                        -OwnerId "denied-owner") `
                    -Session $firstSession `
                    -DedupKey (Get-AiSopWorkflowSha256 "denied-$deniedOperation") `
                    -IssuedAt $t0 `
                    -TransactionId "denied-$deniedOperation"
            }
    }
    $firstGrant = Issue-Grant `
        -CommandText $command `
        -Session $firstSession `
        -DedupKey (Get-AiSopWorkflowSha256 "main-dedup-A") `
        -IssuedAt $t0 `
        -TransactionId "main-grant-A"

    $found = Find-Grant `
        -Workspace $workspace `
        -GrantOperation Claim `
        -Feature $feature `
        -Workflow SUPERPOWERS `
        -Agent CURSOR `
        -OwnerId "fixture-owner-0001" `
        -AcceptedAt $t0.AddSeconds(1)
    Assert-Equal $found.Record.grantId $firstGrant.Record.grantId (
        "Find did not return the unique matching grant."
    )

    $secondSession = New-ConfirmedSession `
        -Workspace $workspace `
        -Agent CURSOR `
        -NativeSessionId "cursor-main-B"
    $secondGrant = Issue-Grant `
        -CommandText $command `
        -Session $secondSession `
        -DedupKey (Get-AiSopWorkflowSha256 "main-dedup-B") `
        -IssuedAt $t0.AddSeconds(1) `
        -TransactionId "main-grant-B"
    Assert-ThrowsCode -Code "COMMAND_GRANT_AMBIGUOUS" `
        -Message "Two sessions with one tuple were not fail-closed." `
        -Action {
            Find-Grant `
                -Workspace $workspace `
                -GrantOperation Claim `
                -Feature $feature `
                -Workflow SUPERPOWERS `
                -Agent CURSOR `
                -OwnerId "fixture-owner-0001" `
                -AcceptedAt $t0.AddSeconds(2)
        }
    Assert-Equal (
        (Get-Content -LiteralPath $firstGrant.GrantPath -Raw | ConvertFrom-Json).status
    ) "ISSUED" "Ambiguous Find consumed the first grant."
    Assert-Equal (
        (Get-Content -LiteralPath $secondGrant.GrantPath -Raw | ConvertFrom-Json).status
    ) "ISSUED" "Ambiguous Find consumed the second grant."

    Invoke-AiSopWorkflowCommandGrant `
        -Operation Expire `
        -GrantId $secondGrant.Record.grantId `
        -AcceptedAt $t0.AddSeconds(2) | Out-Null
    $uniqueAgain = Find-Grant `
        -Workspace $workspace `
        -GrantOperation Claim `
        -Feature $feature `
        -Workflow SUPERPOWERS `
        -Agent CURSOR `
        -OwnerId "fixture-owner-0001" `
        -AcceptedAt $t0.AddSeconds(2)
    Assert-Equal $uniqueAgain.Record.grantId $firstGrant.Record.grantId (
        "Find did not recover after the ambiguous grant expired."
    )

    # The exact-intent active index is parsed once and pruned once. Expired
    # candidates must not cause one record lock/read per historical entry.
    $activeIndexPath = Get-AiSopWorkflowCommandGrantActiveIndexPath `
        -IntentSha256 $firstGrant.Record.intentSha256
    $activeMarkerRoot = Split-Path -Parent (
        Get-AiSopWorkflowCommandGrantMarkerPath `
            -IntentSha256 $firstGrant.Record.intentSha256 `
            -GrantId $firstGrant.Record.grantId `
            -MarkerKind active
    )
    foreach ($targetCount in @(0, 100, 300, 1000)) {
        $entries = @(
            [ordered]@{
                grantId = [string]$firstGrant.Record.grantId
                intentSha256 = [string]$firstGrant.Record.intentSha256
                sessionKey = [string]$firstGrant.Record.sessionKey
                sessionEpochId = [string]$firstGrant.Record.sessionEpochId
                operation = [string]$firstGrant.Record.operation
                expiresAt = [string]$firstGrant.Record.expiresAt
                active = $true
            }
        )
        for ($historyIndex = 1; $historyIndex -le $targetCount; $historyIndex++) {
            $historyId = "{0:x64}" -f (10000 + $historyIndex)
            $entries += [ordered]@{
                grantId = $historyId
                intentSha256 = [string]$firstGrant.Record.intentSha256
                sessionKey = [string]$firstGrant.Record.sessionKey
                sessionEpochId = [string]$firstGrant.Record.sessionEpochId
                operation = [string]$firstGrant.Record.operation
                expiresAt = $t0.AddSeconds(-1).ToString("o")
                active = $true
            }
            [System.IO.File]::WriteAllText(
                (Join-Path $activeMarkerRoot "$historyId.ref"),
                $historyId,
                [System.Text.UTF8Encoding]::new($false)
            )
        }
        $activeIndex = [ordered]@{
            schemaVersion = "1.0"
            indexKind = "INTENT"
            intentSha256 = [string]$firstGrant.Record.intentSha256
            entries = @($entries)
        }
        $activeIndexJson = ConvertTo-AiSopWorkflowCanonicalJson $activeIndex
        Assert-True (
            $activeIndexJson |
                Test-Json -SchemaFile $GrantSchema
        ) "Exact-intent active index fixture is schema-invalid."
        [System.IO.File]::WriteAllText(
            $activeIndexPath,
            $activeIndexJson,
            [System.Text.UTF8Encoding]::new($false)
        )
        $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $boundedFind = Find-Grant `
            -Workspace $workspace `
            -GrantOperation Claim `
            -Feature $feature `
            -Workflow SUPERPOWERS `
            -Agent CURSOR `
            -OwnerId "fixture-owner-0001" `
            -AcceptedAt $t0.AddSeconds(2)
        $stopwatch.Stop()
        Assert-Equal $boundedFind.Record.grantId $firstGrant.Record.grantId (
            "Intent-indexed Find returned the wrong grant at $targetCount history."
        )
        Assert-True ($stopwatch.ElapsedMilliseconds -lt 750) (
            "Intent-indexed Find exceeded 750ms at $targetCount exact-intent " +
            "active-expired entries: " +
            "$($stopwatch.ElapsedMilliseconds)ms."
        )
        $prunedIndexRaw = [System.IO.File]::ReadAllText($activeIndexPath)
        Assert-True (
            $prunedIndexRaw | Test-Json -SchemaFile $GrantSchema
        ) "Pruned exact-intent active index is schema-invalid."
        $prunedIndex = ConvertFrom-AiSopWorkflowJson `
            -Json $prunedIndexRaw `
            -AsHashtable
        Assert-Equal @(
            $prunedIndex.entries |
                Where-Object { $_.active }
        ).Count 1 (
            "Find did not prune $targetCount expired exact-intent entries in one write."
        )
        Assert-Equal @(
            $prunedIndex.entries |
                Where-Object { $_.active }
        )[0].grantId (
            [string]$firstGrant.Record.grantId
        ) "Find pruned the live exact-intent candidate."
    }

    $validIndex = [System.IO.File]::ReadAllText($activeIndexPath)
    [System.IO.File]::WriteAllText(
        $activeIndexPath,
        "{corrupt-active-index",
        [System.Text.UTF8Encoding]::new($false)
    )
    Assert-ThrowsCode -Code "COMMAND_GRANT_CORRUPT" `
        -Message "A corrupt exact-intent active index did not fail closed." `
        -Action {
            Find-Grant `
                -Workspace $workspace `
                -GrantOperation Claim `
                -Feature $feature `
                -Workflow SUPERPOWERS `
                -Agent CURSOR `
                -OwnerId "fixture-owner-0001" `
                -AcceptedAt $t0.AddSeconds(2)
        }
    [System.IO.File]::WriteAllText(
        $activeIndexPath,
        $validIndex,
        [System.Text.UTF8Encoding]::new($false)
    )
    $heldGrantLock = [System.IO.File]::Open(
        $firstGrant.GrantPath + ".lock",
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    try {
        $lockThrew = $false
        try {
            Invoke-AiSopWorkflowCommandGrant `
                -Operation Find `
                -GrantOperation Claim `
                -SpecDirectory $specDirectory `
                -Feature $feature `
                -Workflow SUPERPOWERS `
                -Agent CURSOR `
                -OwnerId "fixture-owner-0001" `
                -AcceptedAt $t0.AddSeconds(2) `
                -DeadlineUtc ([DateTimeOffset]::UtcNow.AddMilliseconds(200))
        } catch {
            $lockThrew = $true
            if ($_.Exception.Message -notin @("WORKFLOW_LOCK_TIMEOUT", "WORKFLOW_DEADLINE_EXCEEDED")) {
                throw "Unexpected lock error: $($_.Exception.Message)"
            }
        }
        Assert-True $lockThrew "A held exact-candidate lock did not fail closed."
    } finally {
        $heldGrantLock.Dispose()
        Remove-Item -LiteralPath ($firstGrant.GrantPath + ".lock") `
            -Force -ErrorAction SilentlyContinue
    }
    $consumed = Invoke-AiSopWorkflowCommandGrant `
        -Operation Consume `
        -GrantId $firstGrant.Record.grantId `
        -AcceptedAt $t0.AddSeconds(2) `
        -TransactionId "consume-main-A"
    Assert-Equal $consumed.Record.status "CONSUMED" (
        "Consume did not transition ISSUED to CONSUMED."
    )
    Assert-Equal $consumed.Record.consumedTransactionId "consume-main-A" (
        "Consume did not persist transaction proof."
    )
    Assert-ThrowsCode -Code "COMMAND_GRANT_NOT_FOUND" `
        -Message "A consumed grant was replayable." `
        -Action {
            Find-Grant `
                -Workspace $workspace `
                -GrantOperation Claim `
                -Feature $feature `
                -Workflow SUPERPOWERS `
                -Agent CURSOR `
                -OwnerId "fixture-owner-0001" `
                -AcceptedAt $t0.AddSeconds(3)
        }
    Assert-True (
        Test-AiSopWorkflowCommandGrantProof `
            -TransactionId "consume-main-A" `
            -GrantId $firstGrant.Record.grantId `
            -ExpectedStatus CONSUMED
    ) "Consumed transaction proof was not durable."
    Assert-ThrowsCode -Code "COMMAND_GRANT_REPLAYED" `
        -Message "Issue replay revived or returned a consumed grant." `
        -Action {
            Issue-Grant `
                -CommandText $command `
                -Session $firstSession `
                -DedupKey (Get-AiSopWorkflowSha256 "main-dedup-A") `
                -IssuedAt $t0.AddSeconds(3) `
                -TransactionId "main-grant-A"
        }

    # Exact expiry: 9.999 seconds is valid, 10 seconds is expired.
    $boundaryFeature = "BoundaryFeature"
    [System.IO.Directory]::CreateDirectory(
        (Join-Path $workspace ".ai-workspace\specs\features\$boundaryFeature")
    ) | Out-Null
    $boundaryCommand = New-OwnerCommand `
        -Operation Claim `
        -Feature $boundaryFeature `
        -Workflow SUPERPOWERS `
        -Agent CURSOR `
        -OwnerId "boundary-owner"
    $boundaryGrant = Issue-Grant `
        -CommandText $boundaryCommand `
        -Session $firstSession `
        -DedupKey (Get-AiSopWorkflowSha256 "boundary-dedup-A") `
        -IssuedAt $t0 `
        -TransactionId "boundary-A"
    $boundaryFound = Find-Grant `
        -Workspace $workspace `
        -GrantOperation Claim `
        -Feature $boundaryFeature `
        -Workflow SUPERPOWERS `
        -Agent CURSOR `
        -OwnerId "boundary-owner" `
        -AcceptedAt $t0.AddMilliseconds(9999)
    Assert-Equal $boundaryFound.Record.grantId $boundaryGrant.Record.grantId (
        "Grant expired before the 10 second boundary."
    )
    Assert-ThrowsCode -Code "COMMAND_GRANT_NOT_FOUND" `
        -Message "Grant remained valid at exact expiry." `
        -Action {
            Find-Grant `
                -Workspace $workspace `
                -GrantOperation Claim `
                -Feature $boundaryFeature `
                -Workflow SUPERPOWERS `
                -Agent CURSOR `
                -OwnerId "boundary-owner" `
                -AcceptedAt $t0.AddSeconds(10)
        }
    $boundaryIndex = Get-Content -LiteralPath (
        Get-AiSopWorkflowCommandGrantActiveIndexPath `
            -IntentSha256 $boundaryGrant.Record.intentSha256
    ) -Raw | ConvertFrom-Json
    Assert-Equal @(
        $boundaryIndex.entries |
            Where-Object { $_.active }
    ).Count 0 (
        "Find did not prune exact-boundary authorization from the active index."
    )

    # SessionEnd expires every still-issued grant for the exact epoch.
    $endFeature = "EndFeature"
    [System.IO.Directory]::CreateDirectory(
        (Join-Path $workspace ".ai-workspace\specs\features\$endFeature")
    ) | Out-Null
    $endCommand = New-OwnerCommand `
        -Operation Claim `
        -Feature $endFeature `
        -Workflow SUPERPOWERS `
        -Agent CURSOR `
        -OwnerId "end-owner"
    $endGrant = Issue-Grant `
        -CommandText $endCommand `
        -Session $firstSession `
        -DedupKey (Get-AiSopWorkflowSha256 "end-dedup-A") `
        -IssuedAt $t0.AddSeconds(1) `
        -TransactionId "end-grant-A"
    Invoke-AiSopWorkflowSession `
        -Operation End `
        -Agent CURSOR `
        -NativeSessionId "cursor-main-A" `
        -WorkspacePath $workspace `
        -AcceptedAt $t0.AddSeconds(2) | Out-Null
    Assert-Equal (
        (Get-Content -LiteralPath $endGrant.GrantPath -Raw |
            ConvertFrom-Json).status
    ) "ISSUED" "SessionEnd rewrote immutable historical grant state."
    Assert-ThrowsCode -Code "COMMAND_GRANT_NOT_FOUND" `
        -Message "SessionEnd left an indexed grant discoverable." `
        -Action {
            Find-Grant `
                -Workspace $workspace `
                -GrantOperation Claim `
                -Feature $endFeature `
                -Workflow SUPERPOWERS `
                -Agent CURSOR `
                -OwnerId "end-owner" `
                -AcceptedAt $t0.AddSeconds(2)
        }

    # SessionEnd cleanup is retryable even after ENDED is already durable.
    # Cover both an observed lock-timeout and a real kill after ENDED persisted.
    $sessionEndCleanupFailures = [System.Collections.Generic.List[string]]::new()
    $retryEndFeature = "RetryEndFeature"
    [System.IO.Directory]::CreateDirectory(
        (Join-Path $workspace ".ai-workspace\specs\features\$retryEndFeature")
    ) | Out-Null
    $retryEndSession = New-ConfirmedSession `
        -Workspace $workspace `
        -Agent CURSOR `
        -NativeSessionId "retry-end-session"
    $retryEndGrant = Issue-Grant `
        -CommandText (New-OwnerCommand `
            -Operation Claim `
            -Feature $retryEndFeature `
            -Workflow SUPERPOWERS `
            -Agent CURSOR `
            -OwnerId "retry-end-owner") `
        -Session $retryEndSession `
        -DedupKey (Get-AiSopWorkflowSha256 "retry-end-dedup") `
        -IssuedAt $t0 `
        -TransactionId "retry-end-issue"
    $retryEndSessionIndexPath =
        Get-AiSopWorkflowCommandGrantSessionIndexPath `
            -SessionKey $retryEndGrant.Record.sessionKey `
            -SessionEpochId $retryEndGrant.Record.sessionEpochId
    $retryEndIntentIndexPath =
        Get-AiSopWorkflowCommandGrantActiveIndexPath `
            -IntentSha256 $retryEndGrant.Record.intentSha256
    $heldSessionIndex = [System.IO.File]::Open(
        $retryEndSessionIndexPath + ".lock",
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    $firstEndError = ""
    try {
        Invoke-AiSopWorkflowSession `
            -Operation End `
            -Agent CURSOR `
            -NativeSessionId "retry-end-session" `
            -WorkspacePath $workspace `
            -AcceptedAt $t0.AddSeconds(1) `
            -DeadlineUtc ([DateTimeOffset]::UtcNow.AddMilliseconds(100)) |
            Out-Null
    } catch {
        $firstEndError = $_.Exception.Message
    } finally {
        $heldSessionIndex.Dispose()
        [System.IO.File]::Delete($retryEndSessionIndexPath + ".lock")
    }
    if ($firstEndError -cne "WORKFLOW_LOCK_TIMEOUT") {
        $sessionEndCleanupFailures.Add(
            "held-index first End error=$firstEndError"
        )
    }
    $persistedRetryEnd = Get-Content `
        -LiteralPath $retryEndSession.SessionPath `
        -Raw |
        ConvertFrom-Json
    if ([string]$persistedRetryEnd.status -cne "ENDED") {
        $sessionEndCleanupFailures.Add(
            "held-index first End did not persist ENDED"
        )
    }
    Invoke-AiSopWorkflowSession `
        -Operation End `
        -Agent CURSOR `
        -NativeSessionId "retry-end-session" `
        -WorkspacePath $workspace `
        -AcceptedAt $t0.AddSeconds(2) `
        -IsDuplicate |
        Out-Null
    foreach ($retryIndexCase in @(
        [pscustomobject]@{
            Name = "held-index session index"
            Path = $retryEndSessionIndexPath
        },
        [pscustomobject]@{
            Name = "held-index intent index"
            Path = $retryEndIntentIndexPath
        }
    )) {
        $retryIndex = Get-Content -LiteralPath $retryIndexCase.Path -Raw |
            ConvertFrom-Json
        if (@($retryIndex.entries | Where-Object { $_.active }).Count -ne 0) {
            $sessionEndCleanupFailures.Add($retryIndexCase.Name)
        }
    }

    $killEndFeature = "KillEndFeature"
    [System.IO.Directory]::CreateDirectory(
        (Join-Path $workspace ".ai-workspace\specs\features\$killEndFeature")
    ) | Out-Null
    $killEndSession = New-ConfirmedSession `
        -Workspace $workspace `
        -Agent CURSOR `
        -NativeSessionId "kill-end-session"
    $killEndGrant = Issue-Grant `
        -CommandText (New-OwnerCommand `
            -Operation Claim `
            -Feature $killEndFeature `
            -Workflow SUPERPOWERS `
            -Agent CURSOR `
            -OwnerId "kill-end-owner") `
        -Session $killEndSession `
        -DedupKey (Get-AiSopWorkflowSha256 "kill-end-dedup") `
        -IssuedAt $t0 `
        -TransactionId "kill-end-issue"
    $killEndSessionIndexPath =
        Get-AiSopWorkflowCommandGrantSessionIndexPath `
            -SessionKey $killEndGrant.Record.sessionKey `
            -SessionEpochId $killEndGrant.Record.sessionEpochId
    $killEndIntentIndexPath =
        Get-AiSopWorkflowCommandGrantActiveIndexPath `
            -IntentSha256 $killEndGrant.Record.intentSha256
    $killEndWorker = Join-Path $TestRoot "session-end-kill-worker.ps1"
    [System.IO.File]::WriteAllText(
        $killEndWorker,
        @'
param(
    [string]$SessionScript,
    [string]$Workspace,
    [string]$Deadline
)
$ErrorActionPreference = "Stop"
. $SessionScript
Invoke-AiSopWorkflowSession `
    -Operation End `
    -Agent CURSOR `
    -NativeSessionId "kill-end-session" `
    -WorkspacePath $Workspace `
    -AcceptedAt ([DateTimeOffset]::Parse("2026-08-17T11:00:01Z")) `
    -DeadlineUtc ([DateTimeOffset]::Parse($Deadline)) |
    Out-Null
'@,
        [System.Text.UTF8Encoding]::new($false)
    )
    $killEndOut = Join-Path $TestRoot "session-end-kill.out"
    $killEndErr = Join-Path $TestRoot "session-end-kill.err"
    $heldKillSessionIndex = [System.IO.File]::Open(
        $killEndSessionIndexPath + ".lock",
        [System.IO.FileMode]::OpenOrCreate,
        [System.IO.FileAccess]::ReadWrite,
        [System.IO.FileShare]::None
    )
    try {
        $killEndProcess = Start-AiSopHiddenProcess `
            -FilePath (Get-Process -Id $PID).Path `
            -ArgumentList @(
                "-NoProfile",
                "-File",
                $killEndWorker,
                "-SessionScript",
                $SessionScript,
                "-Workspace",
                $workspace,
                "-Deadline",
                [DateTimeOffset]::UtcNow.AddSeconds(10).ToString("o")
            ) `
            -RedirectStandardOutput $killEndOut `
            -RedirectStandardError $killEndErr `
            -PassThru
        $killEndLimit = [DateTimeOffset]::UtcNow.AddSeconds(5)
        $killEndPersisted = $false
        while (
            -not $killEndProcess.HasExited -and
            [DateTimeOffset]::UtcNow -lt $killEndLimit
        ) {
            try {
                $killEndRecord = Get-Content `
                    -LiteralPath $killEndSession.SessionPath `
                    -Raw |
                    ConvertFrom-Json
                if ([string]$killEndRecord.status -ceq "ENDED") {
                    $killEndPersisted = $true
                    break
                }
            } catch {
                # Atomic replacement may briefly race this observational read.
            }
            Start-Sleep -Milliseconds 10
            $killEndProcess.Refresh()
        }
        if (-not $killEndPersisted) {
            $sessionEndCleanupFailures.Add(
                "strong-kill End did not persist ENDED before timeout"
            )
        } elseif ($killEndProcess.HasExited) {
            $sessionEndCleanupFailures.Add(
                "strong-kill End exited before the held-index kill window"
            )
        } else {
            Stop-Process -Id $killEndProcess.Id -Force
            $killEndProcess.WaitForExit()
        }
    } finally {
        $heldKillSessionIndex.Dispose()
        [System.IO.File]::Delete($killEndSessionIndexPath + ".lock")
        if (
            $null -ne $killEndProcess -and
            -not $killEndProcess.HasExited
        ) {
            Stop-Process -Id $killEndProcess.Id -Force `
                -ErrorAction SilentlyContinue
            $killEndProcess.WaitForExit()
        }
    }
    Invoke-AiSopWorkflowSession `
        -Operation End `
        -Agent CURSOR `
        -NativeSessionId "kill-end-session" `
        -WorkspacePath $workspace `
        -AcceptedAt $t0.AddSeconds(2) `
        -IsDuplicate |
        Out-Null
    foreach ($killIndexCase in @(
        [pscustomobject]@{
            Name = "strong-kill session index"
            Path = $killEndSessionIndexPath
        },
        [pscustomobject]@{
            Name = "strong-kill intent index"
            Path = $killEndIntentIndexPath
        }
    )) {
        $killIndex = Get-Content -LiteralPath $killIndexCase.Path -Raw |
            ConvertFrom-Json
        if (@($killIndex.entries | Where-Object { $_.active }).Count -ne 0) {
            $sessionEndCleanupFailures.Add($killIndexCase.Name)
        }
    }
    Assert-Equal $sessionEndCleanupFailures.Count 0 (
        "Repeated SessionEnd did not converge exact-epoch cleanup: " +
        ($sessionEndCleanupFailures -join ", ")
    )

    foreach ($sessionGrantCount in @(0, 100, 300, 1000)) {
        $batchFeature = "SessionBatch$sessionGrantCount"
        [System.IO.Directory]::CreateDirectory(
            (Join-Path $workspace ".ai-workspace\specs\features\$batchFeature")
        ) | Out-Null
        $batchSession = New-ConfirmedSession `
            -Workspace $workspace `
            -Agent CURSOR `
            -NativeSessionId "session-batch-$sessionGrantCount"
        $batchIntent = ConvertFrom-AiSopOwnerCommandIntent `
            -CommandText (New-OwnerCommand `
                -Operation Claim `
                -Feature $batchFeature `
                -Workflow SUPERPOWERS `
                -Agent CURSOR `
                -OwnerId "session-batch-owner-$sessionGrantCount") `
            -WorkspacePath $workspace
        $batchIntentHash = Get-AiSopOwnerIntentSha256 $batchIntent
        $batchEntries = @()
        for ($batchIndex = 1; $batchIndex -le $sessionGrantCount; $batchIndex++) {
            $batchEntries += [ordered]@{
                grantId = "{0:x64}" -f (20000 + $batchIndex)
                intentSha256 = $batchIntentHash
                sessionKey = [string]$batchSession.Record.sessionKey
                sessionEpochId = [string]$batchSession.Record.sessionEpochId
                operation = "Claim"
                expiresAt = $t0.AddSeconds(10).ToString("o")
                active = $true
            }
        }
        $batchSessionIndexPath =
            Get-AiSopWorkflowCommandGrantSessionIndexPath `
                -SessionKey $batchSession.Record.sessionKey `
                -SessionEpochId $batchSession.Record.sessionEpochId
        $batchSessionIndex = [ordered]@{
            schemaVersion = "1.0"
            indexKind = "SESSION"
            sessionKey = [string]$batchSession.Record.sessionKey
            sessionEpochId = [string]$batchSession.Record.sessionEpochId
            entries = @($batchEntries)
        }
        Write-AiSopWorkflowCommandGrantIndex `
            -IndexPath $batchSessionIndexPath `
            -Index $batchSessionIndex
        if ($sessionGrantCount -gt 0) {
            Write-AiSopWorkflowCommandGrantIndex `
                -IndexPath (
                    Get-AiSopWorkflowCommandGrantActiveIndexPath $batchIntentHash
                ) `
                -Index ([ordered]@{
                    schemaVersion = "1.0"
                    indexKind = "INTENT"
                    intentSha256 = $batchIntentHash
                    entries = @($batchEntries)
                })
        }
        $batchStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Invoke-AiSopWorkflowSession `
            -Operation End `
            -Agent CURSOR `
            -NativeSessionId "session-batch-$sessionGrantCount" `
            -WorkspacePath $workspace `
            -AcceptedAt $t0.AddSeconds(2) `
            -DeadlineUtc ([DateTimeOffset]::UtcNow.AddMilliseconds(1500)) |
            Out-Null
        $batchStopwatch.Stop()
        Assert-True ($batchStopwatch.ElapsedMilliseconds -lt 1500) (
            "SessionEnd exceeded 1500ms at $sessionGrantCount active grants: " +
            "$($batchStopwatch.ElapsedMilliseconds)ms."
        )
        $endedBatchIndex = Get-Content `
            -LiteralPath $batchSessionIndexPath `
            -Raw |
            ConvertFrom-Json
        Assert-Equal @(
            $endedBatchIndex.entries |
                Where-Object { $_.active }
        ).Count 0 (
            "SessionEnd left active session-index entries at $sessionGrantCount."
        )
        if ($sessionGrantCount -gt 0) {
            Assert-ThrowsCode -Code "COMMAND_GRANT_NOT_FOUND" `
                -Message (
                    "Ended batch remained discoverable at $sessionGrantCount."
                ) `
                -Action {
                    Find-Grant `
                        -Workspace $workspace `
                        -GrantOperation Claim `
                        -Feature $batchFeature `
                        -Workflow SUPERPOWERS `
                        -Agent CURSOR `
                        -OwnerId "session-batch-owner-$sessionGrantCount" `
                        -AcceptedAt $t0.AddSeconds(2)
                }
        }
    }

    # Canonical AST is deliberately narrower than PowerShell's grammar.
    $invalidCommands = @(
        $command + " | Out-Null",
        $command + " > out.txt",
        $command + "; Write-Host 'extra'",
        $command.Replace("'fixture-owner-0001'", '$env:OWNER_ID'),
        $command.Replace("'fixture-owner-0001'", '"$ownerId"'),
        $command + " -Unknown 'value'",
        $command.Replace("-Feature '$feature'", "-Feature '$feature' -Feature '$feature'"),
        $command.Replace(
            "-SpecDirectory '.ai-workspace\specs\features\$feature'",
            "-SpecDirectory '..\outside\$feature'"
        ),
        $command.Replace("-Agent 'CURSOR'", "-Agent 'GEMINI'"),
        $command.Replace("-Workflow 'SUPERPOWERS'", "-Workflow 'CUSTOM_SKILLS'")
    )
    foreach ($invalidCommand in $invalidCommands) {
        Assert-ThrowsCode -Code "COMMAND_AST_INVALID" `
            -Message "Invalid owner command AST was accepted: $invalidCommand" `
            -Action {
                Invoke-AiSopWorkflowCommandGrant `
                    -Operation Issue `
                    -CommandText $invalidCommand `
                    -SessionKey $secondSession.Record.sessionKey `
                    -SessionEpochId $secondSession.Record.sessionEpochId `
                    -DedupKey (Get-AiSopWorkflowSha256 $invalidCommand) `
                    -AcceptedAt $t0.AddSeconds(3) `
                    -TransactionId "invalid-command"
            }
    }

    Assert-ThrowsCode -Code "COMMAND_GRANT_NOT_FOUND" `
        -Message "Cross-workspace lookup selected a grant." `
        -Action {
            $otherWorkspace = New-TestWorkspace "other-workspace"
            [System.IO.Directory]::CreateDirectory(
                (Join-Path $otherWorkspace ".ai-workspace\specs\features\$feature")
            ) | Out-Null
            Find-Grant `
                -Workspace $otherWorkspace `
                -GrantOperation Claim `
                -Feature $feature `
                -Workflow SUPERPOWERS `
                -Agent CURSOR `
                -OwnerId "fixture-owner-0001" `
                -AcceptedAt $t0.AddSeconds(4)
        }

    Write-Output "All workflow command grant tests passed."
} finally {
    foreach ($name in @(
        "SERVER_NEW_WORKFLOW_SESSION_REGISTRY",
        "SERVER_NEW_WORKFLOW_COMMAND_GRANT_REGISTRY",
        "SERVER_NEW_WORKFLOW_TRANSACTION_REGISTRY",
        "SERVER_NEW_WORKFLOW_REGISTRY"
    )) {
        Remove-Item "Env:$name" -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $TestRoot) {
        [System.IO.Directory]::Delete($TestRoot, $true)
    }
}
