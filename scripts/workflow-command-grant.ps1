#requires -Version 7.0

# Exact, one-use command grants. Records contain the canonical Owner tuple and
# hashes only; command text, native session identifiers, tokens, and payloads
# are never persisted.

$script:WorkflowGrantClaudeRoot = Split-Path -Parent $PSScriptRoot
$script:WorkflowGrantSchemaPath = Join-Path (
    $script:WorkflowGrantClaudeRoot
) "schemas\workflow-command-grant.schema.json"
$script:WorkflowGrantOwnerSchemaPath = Join-Path (
    $script:WorkflowGrantClaudeRoot
) "schemas\workflow-owner.schema.json"
$script:WorkflowGrantTransactionScript = Join-Path (
    $PSScriptRoot
) "workflow-transaction.ps1"
$script:WorkflowGrantSessionScript = Join-Path $PSScriptRoot "workflow-session.ps1"
$script:WorkflowGrantPathIdentityScript = Join-Path $PSScriptRoot "path-identity.ps1"

if (-not (Get-Command Get-AiSopWorkflowSha256 -ErrorAction SilentlyContinue)) {
    . $script:WorkflowGrantTransactionScript
}
if (-not (Get-Command Resolve-PhysicalPathIdentity -ErrorAction SilentlyContinue)) {
    . $script:WorkflowGrantPathIdentityScript
}
if (-not (Get-Command Read-AiSopWorkflowSessionRecord -ErrorAction SilentlyContinue)) {
    . $script:WorkflowGrantSessionScript
}

function Test-AiSopWorkflowPathWithinRoot {
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

function Resolve-AiSopWorkflowOwnerTuple {
    param(
        [ValidateSet(
            "Claim",
            "BindSession",
            "RebindSession",
            "Validate",
            "Complete",
            "Transfer"
        )]
        [string]$GrantOperation,
        [string]$SpecDirectory,
        [string]$Feature,
        [string]$Workflow,
        [string]$Agent,
        [string]$OwnerId,
        [string]$WorkspacePath
    )

    if (
        $Workflow -cne "SUPERPOWERS" -or
        $Agent -notin @("CLAUDE_CODE", "COPILOT", "ANTIGRAVITY", "CURSOR", "PI") -or
        $OwnerId -notmatch "^[A-Za-z0-9._:-]+$" -or
        $Feature -notmatch
            "^[A-Za-z0-9](?:[A-Za-z0-9._-]*[A-Za-z0-9_-])?$"
    ) {
        throw "COMMAND_AST_INVALID"
    }
    try {
        $workspace = Resolve-PhysicalPathIdentity -Path $WorkspacePath
        $specCandidate = if ([System.IO.Path]::IsPathRooted($SpecDirectory)) {
            $SpecDirectory
        } else {
            Join-Path $workspace $SpecDirectory
        }
        $spec = Resolve-PhysicalPathIdentity -Path $specCandidate
    } catch {
        throw "COMMAND_AST_INVALID"
    }
    if (-not (Test-AiSopWorkflowPathWithinRoot $spec $workspace)) {
        throw "COMMAND_AST_INVALID"
    }
    $trimmedSpec = $spec.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
    $featuresDirectory = Split-Path -Parent $trimmedSpec
    $specsDirectory = Split-Path -Parent $featuresDirectory
    $claudeDirectory = Split-Path -Parent $specsDirectory
    $derivedWorkspace = Split-Path -Parent $claudeDirectory
    if (
        -not (Split-Path -Leaf $trimmedSpec).Equals(
            $Feature,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        -not (Split-Path -Leaf $featuresDirectory).Equals(
            "features",
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        -not (Split-Path -Leaf $specsDirectory).Equals(
            "specs",
            [System.StringComparison]::OrdinalIgnoreCase
        ) -or
        -not (
            (Split-Path -Leaf $claudeDirectory).Equals(
                ".ai-sop",
                [System.StringComparison]::OrdinalIgnoreCase
            ) -or
            (Split-Path -Leaf $claudeDirectory).Equals(
                ".ai-workspace",
                [System.StringComparison]::OrdinalIgnoreCase
            )
        ) -or
        -not $derivedWorkspace.Equals(
            $workspace,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw "COMMAND_AST_INVALID"
    }
    return [pscustomobject][ordered]@{
        operation = $GrantOperation
        feature = $Feature
        specDirectory = $trimmedSpec
        workflow = $Workflow
        agent = $Agent
        ownerId = $OwnerId
        workspacePath = $workspace
    }
}

function Get-AiSopOwnerIntentSha256 {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Intent
    )

    $required = @(
        "operation",
        "feature",
        "specDirectory",
        "workflow",
        "agent",
        "ownerId",
        "workspacePath"
    )
    foreach ($name in $required) {
        if ([string]::IsNullOrWhiteSpace([string]$Intent.$name)) {
            throw "COMMAND_AST_INVALID"
        }
    }
    return Get-AiSopWorkflowSha256 (
        [string]$Intent.operation + [char]0 +
        [string]$Intent.feature + [char]0 +
        ([string]$Intent.specDirectory).ToLowerInvariant() + [char]0 +
        [string]$Intent.workflow + [char]0 +
        [string]$Intent.agent + [char]0 +
        [string]$Intent.ownerId + [char]0 +
        ([string]$Intent.workspacePath).ToLowerInvariant()
    )
}

function ConvertFrom-AiSopOwnerCommandIntent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CommandText,

        [Parameter(Mandatory)]
        [string]$WorkspacePath
    )

    $tokens = $null
    $parseErrors = $null
    try {
        $ast = [System.Management.Automation.Language.Parser]::ParseInput(
            $CommandText,
            [ref]$tokens,
            [ref]$parseErrors
        )
    } catch {
        throw "COMMAND_AST_INVALID"
    }
    if (
        @($parseErrors).Count -ne 0 -or
        @($ast.EndBlock.Statements).Count -ne 1 -or
        $ast.EndBlock.Statements[0] -isnot
            [System.Management.Automation.Language.PipelineAst] -or
        @($ast.EndBlock.Statements[0].PipelineElements).Count -ne 1
    ) {
        throw "COMMAND_AST_INVALID"
    }
    $commandAst = $ast.EndBlock.Statements[0].PipelineElements[0]
    if (
        $commandAst -isnot
            [System.Management.Automation.Language.CommandAst] -or
        @($commandAst.Redirections).Count -ne 0 -or
        @(
            $ast.FindAll(
                {
                    param($node)
                    $node -is
                        [System.Management.Automation.Language.VariableExpressionAst] -or
                    $node -is
                        [System.Management.Automation.Language.ExpandableStringExpressionAst] -or
                    $node -is
                        [System.Management.Automation.Language.SubExpressionAst] -or
                    $node -is
                        [System.Management.Automation.Language.ScriptBlockExpressionAst]
                },
                $true
            )
        ).Count -ne 0
    ) {
        throw "COMMAND_AST_INVALID"
    }

    $escapedBacktick = [regex]::Escape([string][char]96)
    $normalized = [regex]::Replace(
        $CommandText,
        $escapedBacktick + "\r?\n",
        " "
    )
    if ($normalized -match "[\r\n]") {
        throw "COMMAND_AST_INVALID"
    }
    $pattern = (
        "^\s*(?i:pwsh(?:\.exe)?)\s+(?i:-NoProfile)\s+" +
        "(?i:-File)\s+'(?<script>[^']+)'\s+" +
        "(?i:-Operation)\s+'(?<operation>Claim|BindSession|RebindSession|Validate|Complete|Transfer)'\s+" +
        "(?i:-SpecDirectory)\s+'(?<spec>[^']+)'\s+" +
        "(?i:-Feature)\s+'(?<feature>[^']+)'\s+" +
        "(?i:-Workflow)\s+'(?<workflow>[^']+)'\s+" +
        "(?i:-Agent)\s+'(?<agent>[^']+)'\s+" +
        "(?i:-OwnerId)\s+'(?<owner>[^']+)'\s*$"
    )
    $match = [regex]::Match($normalized, $pattern)
    if (-not $match.Success) {
        throw "COMMAND_AST_INVALID"
    }

    try {
        $workspace = Resolve-PhysicalPathIdentity -Path $WorkspacePath
        $scriptCandidate = if (
            [System.IO.Path]::IsPathRooted($match.Groups["script"].Value)
        ) {
            $match.Groups["script"].Value
        } else {
            Join-Path $workspace $match.Groups["script"].Value
        }
        $scriptPath = Resolve-PhysicalPathIdentity -Path $scriptCandidate
        $expectedScript = Resolve-PhysicalPathIdentity -Path (
            Join-Path $workspace ".ai-sop\scripts\workflow-owner.ps1"
        )
    } catch {
        throw "COMMAND_AST_INVALID"
    }
    if (
        -not $scriptPath.Equals(
            $expectedScript,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    ) {
        throw "COMMAND_AST_INVALID"
    }
    return Resolve-AiSopWorkflowOwnerTuple `
        -GrantOperation $match.Groups["operation"].Value `
        -SpecDirectory $match.Groups["spec"].Value `
        -Feature $match.Groups["feature"].Value `
        -Workflow $match.Groups["workflow"].Value `
        -Agent $match.Groups["agent"].Value `
        -OwnerId $match.Groups["owner"].Value `
        -WorkspacePath $workspace
}

function Get-AiSopWorkflowCommandGrantPath {
    param(
        [string]$GrantId,
        [AllowEmptyString()]
        [string]$IntentSha256 = ""
    )

    if ($GrantId -notmatch "^[0-9a-f]{64}$") {
        throw "COMMAND_GRANT_ID_INVALID"
    }
    $root = Get-AiSopWorkflowCommandGrantRegistryRoot
    if (-not [string]::IsNullOrEmpty($IntentSha256)) {
        if ($IntentSha256 -notmatch "^[0-9a-f]{64}$") {
            throw "COMMAND_GRANT_ARGUMENT_INVALID"
        }
        return Join-Path $root "$IntentSha256\records\$GrantId.json"
    }
    if ([System.IO.Directory]::Exists($root)) {
        $matches = @(
            [System.IO.Directory]::EnumerateFiles(
                $root,
                "$GrantId.json",
                [System.IO.SearchOption]::AllDirectories
            ) |
                Where-Object {
                    (Split-Path -Leaf (Split-Path -Parent $_)) -ceq "records" -or
                    (Split-Path -Parent $_) -eq $root
                }
        )
        if ($matches.Count -gt 1) {
            throw "COMMAND_GRANT_CORRUPT"
        }
        if ($matches.Count -eq 1) {
            return $matches[0]
        }
    }
    return Join-Path $root "$GrantId.json"
}

function Get-AiSopWorkflowCommandGrantMarkerPath {
    param(
        [string]$IntentSha256,
        [string]$GrantId,
        [ValidateSet("active", "issued")]
        [string]$MarkerKind
    )

    return Join-Path (
        Get-AiSopWorkflowCommandGrantRegistryRoot
    ) "$IntentSha256\$MarkerKind\$GrantId.ref"
}

function Get-AiSopWorkflowCommandGrantActiveIndexPath {
    param([string]$IntentSha256)

    if ($IntentSha256 -notmatch "^[0-9a-f]{64}$") {
        throw "COMMAND_GRANT_ARGUMENT_INVALID"
    }
    return Join-Path (
        Get-AiSopWorkflowCommandGrantRegistryRoot
    ) "$IntentSha256\active-index.json"
}

function Get-AiSopWorkflowCommandGrantSessionIndexPath {
    param(
        [string]$SessionKey,
        [string]$SessionEpochId
    )

    if (
        $SessionKey -notmatch "^[0-9a-f]{64}$" -or
        $SessionEpochId -notmatch "^[A-Za-z0-9._:-]+$"
    ) {
        throw "COMMAND_GRANT_ARGUMENT_INVALID"
    }
    return Join-Path (
        Get-AiSopWorkflowCommandGrantRegistryRoot
    ) "sessions\$SessionKey\$SessionEpochId.json"
}

function New-AiSopWorkflowCommandGrantIndexEntry {
    param(
        [object]$Grant,
        [bool]$Active
    )

    return [ordered]@{
        grantId = [string]$Grant.grantId
        intentSha256 = [string]$Grant.intentSha256
        sessionKey = [string]$Grant.sessionKey
        sessionEpochId = [string]$Grant.sessionEpochId
        operation = [string]$Grant.operation
        expiresAt = [string]$Grant.expiresAt
        active = $Active
    }
}

function Assert-AiSopWorkflowCommandGrantIndex {
    param(
        [System.Collections.IDictionary]$Index,
        [ValidateSet("INTENT", "SESSION")]
        [string]$ExpectedKind,
        [string]$ExpectedIntentSha256 = "",
        [string]$ExpectedSessionKey = "",
        [string]$ExpectedSessionEpochId = ""
    )

    $expectedKeyCount = if ($ExpectedKind -eq "INTENT") { 4 } else { 5 }
    if (
        @($Index.Keys).Count -ne $expectedKeyCount -or
        -not $Index.Contains("schemaVersion") -or
        -not $Index.Contains("indexKind") -or
        -not $Index.Contains("entries") -or
        [string]$Index.schemaVersion -cne "1.0" -or
        [string]$Index.indexKind -cne $ExpectedKind
    ) {
        throw "COMMAND_GRANT_CORRUPT"
    }
    if (
        (
            $ExpectedKind -eq "INTENT" -and
            (
                -not $Index.Contains("intentSha256") -or
                [string]$Index.intentSha256 -cne $ExpectedIntentSha256
            )
        ) -or
        (
            $ExpectedKind -eq "SESSION" -and
            (
                -not $Index.Contains("sessionKey") -or
                -not $Index.Contains("sessionEpochId") -or
                [string]$Index.sessionKey -cne $ExpectedSessionKey -or
                [string]$Index.sessionEpochId -cne $ExpectedSessionEpochId
            )
        )
    ) {
        throw "COMMAND_GRANT_CORRUPT"
    }
    $seen = [System.Collections.Generic.HashSet[string]]::new(
        [System.StringComparer]::Ordinal
    )
    foreach ($entry in @($Index.entries)) {
        if (
            $entry -isnot [System.Collections.IDictionary] -or
            @($entry.Keys).Count -ne 7 -or
            -not $entry.Contains("grantId") -or
            -not $entry.Contains("intentSha256") -or
            -not $entry.Contains("sessionKey") -or
            -not $entry.Contains("sessionEpochId") -or
            -not $entry.Contains("operation") -or
            -not $entry.Contains("expiresAt") -or
            -not $entry.Contains("active") -or
            [string]$entry.grantId -notmatch "^[0-9a-f]{64}$" -or
            [string]$entry.intentSha256 -notmatch "^[0-9a-f]{64}$" -or
            [string]$entry.sessionKey -notmatch "^[0-9a-f]{64}$" -or
            [string]$entry.sessionEpochId -notmatch "^[A-Za-z0-9._:-]+$" -or
            [string]$entry.operation -notin @(
                "Claim",
                "BindSession",
                "RebindSession",
                "Validate",
                "Complete",
                "Transfer"
            ) -or
            $entry.active -isnot [bool] -or
            -not $seen.Add([string]$entry.grantId)
        ) {
            throw "COMMAND_GRANT_CORRUPT"
        }
        $parsedExpiry = [DateTimeOffset]::MinValue
        if (
            -not [DateTimeOffset]::TryParse(
                [string]$entry.expiresAt,
                [System.Globalization.CultureInfo]::InvariantCulture,
                [System.Globalization.DateTimeStyles]::RoundtripKind,
                [ref]$parsedExpiry
            )
        ) {
            throw "COMMAND_GRANT_CORRUPT"
        }
        if (
            (
                $ExpectedKind -eq "INTENT" -and
                [string]$entry.intentSha256 -cne $ExpectedIntentSha256
            ) -or
            (
                $ExpectedKind -eq "SESSION" -and
                (
                    [string]$entry.sessionKey -cne $ExpectedSessionKey -or
                    [string]$entry.sessionEpochId -cne $ExpectedSessionEpochId
                )
            )
        ) {
            throw "COMMAND_GRANT_CORRUPT"
        }
    }
}

function Read-AiSopWorkflowCommandGrantIndex {
    param(
        [string]$IndexPath,
        [ValidateSet("INTENT", "SESSION")]
        [string]$ExpectedKind,
        [string]$ExpectedIntentSha256 = "",
        [string]$ExpectedSessionKey = "",
        [string]$ExpectedSessionEpochId = "",
        [switch]$AllowMissing
    )

    if (-not [System.IO.File]::Exists($IndexPath)) {
        if ($AllowMissing) {
            $empty = [ordered]@{
                schemaVersion = "1.0"
                indexKind = $ExpectedKind
                entries = @()
            }
            if ($ExpectedKind -eq "INTENT") {
                $empty.intentSha256 = $ExpectedIntentSha256
            } else {
                $empty.sessionKey = $ExpectedSessionKey
                $empty.sessionEpochId = $ExpectedSessionEpochId
            }
            return $empty
        }
        throw "COMMAND_GRANT_CORRUPT"
    }
    try {
        $raw = [System.IO.File]::ReadAllText($IndexPath)
    } catch {
        throw "COMMAND_GRANT_IO_ERROR"
    }
    try {
        $index = ConvertFrom-AiSopWorkflowJson -Json $raw -AsHashtable
        Assert-AiSopWorkflowCommandGrantIndex `
            -Index $index `
            -ExpectedKind $ExpectedKind `
            -ExpectedIntentSha256 $ExpectedIntentSha256 `
            -ExpectedSessionKey $ExpectedSessionKey `
            -ExpectedSessionEpochId $ExpectedSessionEpochId
    } catch {
        throw "COMMAND_GRANT_CORRUPT"
    }
    return $index
}

function Write-AiSopWorkflowCommandGrantIndex {
    param(
        [string]$IndexPath,
        [System.Collections.IDictionary]$Index
    )

    try {
        Assert-AiSopWorkflowCommandGrantIndex `
            -Index $Index `
            -ExpectedKind ([string]$Index.indexKind) `
            -ExpectedIntentSha256 ([string]$Index.intentSha256) `
            -ExpectedSessionKey ([string]$Index.sessionKey) `
            -ExpectedSessionEpochId ([string]$Index.sessionEpochId)
        $json = ConvertTo-AiSopWorkflowCanonicalJson $Index
        Write-AiSopWorkflowTextAtomic -Path $IndexPath -Text $json
    } catch {
        if ($_.Exception.Message -eq "COMMAND_GRANT_CORRUPT") {
            throw
        }
        if ($_.Exception.Message -eq "WORKFLOW_REGISTRY_IO_ERROR") {
            throw "COMMAND_GRANT_IO_ERROR"
        }
        throw
    }
}

function Set-AiSopWorkflowCommandGrantActiveIndexEntry {
    param(
        [object]$Grant,
        [bool]$Active,
        [Nullable[DateTimeOffset]]$DeadlineUtc
    )

    $intentSha256 = [string]$Grant.intentSha256
    $sessionKey = [string]$Grant.sessionKey
    $sessionEpochId = [string]$Grant.sessionEpochId
    $descriptors = @(
        [pscustomobject]@{
            Path = Get-AiSopWorkflowCommandGrantActiveIndexPath $intentSha256
            Kind = "INTENT"
        },
        [pscustomobject]@{
            Path = Get-AiSopWorkflowCommandGrantSessionIndexPath `
                -SessionKey $sessionKey `
                -SessionEpochId $sessionEpochId
            Kind = "SESSION"
        }
    ) | Sort-Object Path
    $locks = @()
    try {
        foreach ($descriptor in $descriptors) {
            $locks += Enter-AiSopWorkflowFileLock `
                -LockPath ($descriptor.Path + ".lock") `
                -DeadlineUtc $DeadlineUtc
        }
        foreach ($descriptor in $descriptors) {
            $index = Read-AiSopWorkflowCommandGrantIndex `
                -IndexPath $descriptor.Path `
                -ExpectedKind $descriptor.Kind `
                -ExpectedIntentSha256 $intentSha256 `
                -ExpectedSessionKey $sessionKey `
                -ExpectedSessionEpochId $sessionEpochId `
                -AllowMissing
            $entries = @(
                @($index.entries) |
                    Where-Object {
                        [string]$_.grantId -cne [string]$Grant.grantId
                    }
            )
            $entries += New-AiSopWorkflowCommandGrantIndexEntry `
                -Grant $Grant `
                -Active $Active
            $index.entries = @(
                $entries |
                    Sort-Object { [string]$_.grantId }
            )
            Write-AiSopWorkflowCommandGrantIndex `
                -IndexPath $descriptor.Path `
                -Index $index
        }
    } finally {
        for ($lockIndex = $locks.Count - 1; $lockIndex -ge 0; $lockIndex--) {
            $locks[$lockIndex].Dispose()
        }
        foreach ($descriptor in $descriptors) {
            try {
                [System.IO.File]::Delete($descriptor.Path + ".lock")
            } catch {
                # Lock-file cleanup is not authorization state.
            }
        }
    }
}

function Get-AiSopWorkflowCommandGrantIndexTransitions {
    param(
        [object]$Grant,
        [bool]$Active
    )

    $intentSha256 = [string]$Grant.intentSha256
    $sessionKey = [string]$Grant.sessionKey
    $sessionEpochId = [string]$Grant.sessionEpochId
    $descriptors = @(
        [pscustomobject]@{
            Path = Get-AiSopWorkflowCommandGrantActiveIndexPath $intentSha256
            Kind = "INTENT"
        },
        [pscustomobject]@{
            Path = Get-AiSopWorkflowCommandGrantSessionIndexPath `
                -SessionKey $sessionKey `
                -SessionEpochId $sessionEpochId
            Kind = "SESSION"
        }
    )
    $result = @()
    foreach ($descriptor in $descriptors) {
        $before = Read-AiSopWorkflowCommandGrantIndex `
            -IndexPath $descriptor.Path `
            -ExpectedKind $descriptor.Kind `
            -ExpectedIntentSha256 $intentSha256 `
            -ExpectedSessionKey $sessionKey `
            -ExpectedSessionEpochId $sessionEpochId
        $after = ConvertFrom-AiSopWorkflowJson `
            -Json (ConvertTo-AiSopWorkflowCanonicalJson $before) `
            -AsHashtable
        $matched = 0
        foreach ($entry in @($after.entries)) {
            if ([string]$entry.grantId -ceq [string]$Grant.grantId) {
                if (
                    [string]$entry.intentSha256 -cne $intentSha256 -or
                    [string]$entry.sessionKey -cne $sessionKey -or
                    [string]$entry.sessionEpochId -cne $sessionEpochId -or
                    [string]$entry.expiresAt -cne [string]$Grant.expiresAt
                ) {
                    throw "COMMAND_GRANT_CORRUPT"
                }
                $entry.active = $Active
                $matched++
            }
        }
        if ($matched -ne 1) {
            throw "COMMAND_GRANT_CORRUPT"
        }
        $result += [pscustomobject]@{
            Path = $descriptor.Path
            Before = $before
            After = $after
        }
    }
    return @($result)
}

function Write-AiSopWorkflowCommandGrantMarker {
    param(
        [string]$Path,
        [string]$GrantId
    )

    Write-AiSopWorkflowTextAtomic -Path $Path -Text $GrantId
}

function Remove-AiSopWorkflowCommandGrantActiveMarker {
    param(
        [object]$Grant,
        [Nullable[DateTimeOffset]]$DeadlineUtc
    )

    Set-AiSopWorkflowCommandGrantActiveIndexEntry `
        -Grant $Grant `
        -Active $false `
        -DeadlineUtc $DeadlineUtc
    $path = Get-AiSopWorkflowCommandGrantMarkerPath `
        -IntentSha256 ([string]$Grant.intentSha256) `
        -GrantId ([string]$Grant.grantId) `
        -MarkerKind active
    try {
        [System.IO.File]::Delete($path)
    } catch {
        throw "COMMAND_GRANT_IO_ERROR"
    }
}

function Read-AiSopWorkflowCommandGrantRecord {
    param(
        [string]$GrantPath,
        [AllowEmptyString()]
        [string]$ExpectedGrantId = ""
    )

    if (-not [System.IO.File]::Exists($GrantPath)) {
        throw "COMMAND_GRANT_NOT_FOUND"
    }
    try {
        $raw = [System.IO.File]::ReadAllText($GrantPath)
        if (-not ($raw | Test-Json -SchemaFile $script:WorkflowGrantSchemaPath)) {
            throw "COMMAND_GRANT_CORRUPT"
        }
        $record = ConvertFrom-AiSopWorkflowJson -Json $raw -AsHashtable
    } catch {
        if ($_.Exception.Message -eq "COMMAND_GRANT_CORRUPT") {
            throw
        }
        throw "COMMAND_GRANT_IO_ERROR"
    }
    if (
        -not [string]::IsNullOrEmpty($ExpectedGrantId) -and
        [string]$record.grantId -cne $ExpectedGrantId
    ) {
        throw "COMMAND_GRANT_CORRUPT"
    }
    return $record
}

function Write-AiSopWorkflowCommandGrantRecord {
    param(
        [string]$GrantPath,
        [System.Collections.IDictionary]$Record
    )

    $json = ConvertTo-AiSopWorkflowCanonicalJson $Record
    try {
        if (-not ($json | Test-Json -SchemaFile $script:WorkflowGrantSchemaPath)) {
            throw "COMMAND_GRANT_CORRUPT"
        }
        Write-AiSopWorkflowTextAtomic -Path $GrantPath -Text $json
    } catch {
        if ($_.Exception.Message -eq "COMMAND_GRANT_CORRUPT") {
            throw
        }
        throw "COMMAND_GRANT_IO_ERROR"
    }
}

function New-AiSopWorkflowCommandGrantResult {
    param(
        [System.Collections.IDictionary]$Record,
        [string]$GrantPath,
        [bool]$Mutated
    )

    return [pscustomobject][ordered]@{
        Record = [pscustomobject]$Record
        GrantPath = $GrantPath
        Mutated = $Mutated
    }
}

function Test-AiSopWorkflowGrantMatchesIntent {
    param(
        [System.Collections.IDictionary]$Grant,
        [object]$Intent,
        [string]$IntentSha256
    )

    return (
        [string]$Grant.operation -ceq [string]$Intent.operation -and
        [string]$Grant.feature -ceq [string]$Intent.feature -and
        ([string]$Grant.specDirectory).Equals(
            [string]$Intent.specDirectory,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -and
        [string]$Grant.workflow -ceq [string]$Intent.workflow -and
        [string]$Grant.agent -ceq [string]$Intent.agent -and
        [string]$Grant.ownerId -ceq [string]$Intent.ownerId -and
        ([string]$Grant.workspacePath).Equals(
            [string]$Intent.workspacePath,
            [System.StringComparison]::OrdinalIgnoreCase
        ) -and
        [string]$Grant.intentSha256 -ceq $IntentSha256
    )
}

function Get-AiSopWorkflowGrantIntentFromParameters {
    param(
        [string]$GrantOperation,
        [string]$SpecDirectory,
        [string]$Feature,
        [string]$Workflow,
        [string]$Agent,
        [string]$OwnerId
    )

    try {
        $resolvedSpec = Resolve-PhysicalPathIdentity -Path $SpecDirectory
    } catch {
        throw "COMMAND_GRANT_NOT_FOUND"
    }
    $features = Split-Path -Parent $resolvedSpec
    $specs = Split-Path -Parent $features
    $claude = Split-Path -Parent $specs
    $workspace = Split-Path -Parent $claude
    try {
        return Resolve-AiSopWorkflowOwnerTuple `
            -GrantOperation $GrantOperation `
            -SpecDirectory $resolvedSpec `
            -Feature $Feature `
            -Workflow $Workflow `
            -Agent $Agent `
            -OwnerId $OwnerId `
            -WorkspacePath $workspace
    } catch {
        throw "COMMAND_GRANT_NOT_FOUND"
    }
}

function Set-AiSopWorkflowGrantExpired {
    param(
        [System.Collections.IDictionary]$Grant,
        [string]$GrantPath,
        [Nullable[DateTimeOffset]]$DeadlineUtc
    )

    if ([string]$Grant.status -eq "ISSUED") {
        # Remove authorization visibility first. A kill before the status write
        # leaves an ISSUED record that Find cannot authorize.
        Remove-AiSopWorkflowCommandGrantActiveMarker `
            -Grant $Grant `
            -DeadlineUtc $DeadlineUtc
        $Grant.status = "EXPIRED"
        $Grant.consumedAt = ""
        Write-AiSopWorkflowCommandGrantRecord `
            -GrantPath $GrantPath `
            -Record $Grant
        return $true
    }
    return $false
}

function New-AiSopWorkflowCommandGrantAfterConsume {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Grant,

        [Parameter(Mandatory)]
        [DateTimeOffset]$AcceptedAt,

        [Parameter(Mandatory)]
        [ValidatePattern("^[A-Za-z0-9._:-]+$")]
        [string]$TransactionId
    )

    $after = $Grant |
        ConvertTo-Json -Depth 50 |
        ForEach-Object {
            ConvertFrom-AiSopWorkflowJson -Json $_ -AsHashtable
        }
    $after.status = "CONSUMED"
    $after.consumedAt = $AcceptedAt.ToUniversalTime().ToString("o")
    $after.consumedTransactionId = $TransactionId
    return $after
}

function Find-AiSopWorkflowCommandGrant {
    param(
        [object]$Intent,
        [DateTimeOffset]$AcceptedAt,
        [Nullable[DateTimeOffset]]$DeadlineUtc
    )

    $intentSha256 = Get-AiSopOwnerIntentSha256 $Intent
    $indexPath = Get-AiSopWorkflowCommandGrantActiveIndexPath $intentSha256
    $indexLockPath = "$indexPath.lock"
    $indexLock = Enter-AiSopWorkflowFileLock `
        -LockPath $indexLockPath `
        -DeadlineUtc $DeadlineUtc
    try {
        $index = Read-AiSopWorkflowCommandGrantIndex `
            -IndexPath $indexPath `
            -ExpectedKind INTENT `
            -ExpectedIntentSha256 $intentSha256 `
            -AllowMissing
        $activeEntries = @()
        $indexChanged = $false
        foreach ($entry in @($index.entries)) {
            Assert-AiSopWorkflowDeadline $DeadlineUtc
            try {
                $expiresAt = [DateTimeOffset]::Parse(
                    [string]$entry.expiresAt,
                    [System.Globalization.CultureInfo]::InvariantCulture
                )
            } catch {
                throw "COMMAND_GRANT_CORRUPT"
            }
            if ([bool]$entry.active -and $AcceptedAt -lt $expiresAt) {
                $activeEntries += $entry
            } elseif ([bool]$entry.active) {
                $entry.active = $false
                $indexChanged = $true
            }
        }
        if ($indexChanged) {
            Write-AiSopWorkflowCommandGrantIndex `
                -IndexPath $indexPath `
                -Index $index
        }
    } finally {
        $indexLock.Dispose()
        try {
            [System.IO.File]::Delete($indexLockPath)
        } catch {
            # Lock-file cleanup is not authorization state.
        }
    }
    $validSessionEntries = @()
    $sessionValidity = @{}
    foreach ($entry in @($activeEntries)) {
        $sessionIdentity = (
            [string]$entry.sessionKey + [char]0 +
            [string]$entry.sessionEpochId + [char]0 +
            [string]$entry.operation
        )
        if (-not $sessionValidity.ContainsKey($sessionIdentity)) {
            $sessionPath = Get-AiSopWorkflowSessionPath (
                [string]$entry.sessionKey
            )
            $sessionLockPath = "$sessionPath.lock"
            $sessionLock = Enter-AiSopWorkflowFileLock `
                -LockPath $sessionLockPath `
                -DeadlineUtc $DeadlineUtc
            try {
                $session = Read-AiSopWorkflowSessionRecord `
                    -SessionPath $sessionPath `
                    -ExpectedSessionKey ([string]$entry.sessionKey)
                $sessionIndexPath =
                    Get-AiSopWorkflowCommandGrantSessionIndexPath `
                        -SessionKey ([string]$entry.sessionKey) `
                        -SessionEpochId ([string]$entry.sessionEpochId)
                $sessionIndexLock = Enter-AiSopWorkflowFileLock `
                    -LockPath ($sessionIndexPath + ".lock") `
                    -DeadlineUtc $DeadlineUtc
                try {
                    $sessionIndex = Read-AiSopWorkflowCommandGrantIndex `
                        -IndexPath $sessionIndexPath `
                        -ExpectedKind SESSION `
                        -ExpectedSessionKey ([string]$entry.sessionKey) `
                        -ExpectedSessionEpochId ([string]$entry.sessionEpochId)
                } finally {
                    $sessionIndexLock.Dispose()
                    [System.IO.File]::Delete($sessionIndexPath + ".lock")
                }
                $activeSessionEntries = @{}
                foreach ($sessionEntry in @($sessionIndex.entries)) {
                    if ([bool]$sessionEntry.active) {
                        $activeSessionEntries[
                            [string]$sessionEntry.grantId
                        ] = $sessionEntry
                    }
                }
                $sessionValidity[$sessionIdentity] = [pscustomobject]@{
                    StateValid = (
                    [string]$session.lifecycleProof -ceq "CONFIRMED" -and
                    (
                        (
                            [string]$entry.operation -ceq "RebindSession" -and
                            [string]$session.sessionEpochId -cne
                                [string]$entry.sessionEpochId
                        ) -or
                        (
                            [string]$session.status -cne "ENDED" -and
                            [string]$session.sessionEpochId -ceq
                                [string]$entry.sessionEpochId -and
                            [string]::IsNullOrEmpty([string]$session.endedAt)
                        )
                    )
                    )
                    ActiveEntries = $activeSessionEntries
                }
            } finally {
                $sessionLock.Dispose()
                [System.IO.File]::Delete($sessionLockPath)
            }
        }
        $sessionCheck = $sessionValidity[$sessionIdentity]
        $sessionEntry = $sessionCheck.ActiveEntries[[string]$entry.grantId]
        if (
            [bool]$sessionCheck.StateValid -and
            $null -ne $sessionEntry -and
            [string]$sessionEntry.intentSha256 -ceq
                [string]$entry.intentSha256 -and
            [string]$sessionEntry.operation -ceq [string]$entry.operation -and
            [string]$sessionEntry.expiresAt -ceq [string]$entry.expiresAt
        ) {
            $validSessionEntries += $entry
        }
    }
    $activeEntries = @($validSessionEntries)
    $candidates = @()
    foreach ($entry in @($activeEntries)) {
        Assert-AiSopWorkflowDeadline $DeadlineUtc
        $grantId = [string]$entry.grantId
        $grantPath = Get-AiSopWorkflowCommandGrantPath `
            -GrantId $grantId `
            -IntentSha256 $intentSha256
        $lockPath = "$grantPath.lock"
        $lock = Enter-AiSopWorkflowFileLock `
            -LockPath $lockPath `
            -DeadlineUtc $DeadlineUtc
        try {
            $grant = Read-AiSopWorkflowCommandGrantRecord `
                -GrantPath $grantPath `
                -ExpectedGrantId $grantId
            if (
                [string]$grant.status -cne "ISSUED" -or
                [string]$grant.expiresAt -cne [string]$entry.expiresAt -or
                -not (
                    Test-AiSopWorkflowGrantMatchesIntent `
                        -Grant $grant `
                        -Intent $Intent `
                        -IntentSha256 $intentSha256
                )
            ) {
                throw "COMMAND_GRANT_CORRUPT"
            }
            $candidates += New-AiSopWorkflowCommandGrantResult `
                -Record $grant `
                -GrantPath $grantPath `
                -Mutated $false
        } finally {
            $lock.Dispose()
            try {
                [System.IO.File]::Delete($lockPath)
            } catch {
                # Lock-file cleanup is not authorization state.
            }
        }
    }
    Invoke-AiSopWorkflowCommandGrantScavenge `
        -IntentSha256 $intentSha256 `
        -AcceptedAt $AcceptedAt `
        -DeadlineUtc $DeadlineUtc
    if ($candidates.Count -eq 0) {
        throw "COMMAND_GRANT_NOT_FOUND"
    }
    if ($candidates.Count -ne 1) {
        throw "COMMAND_GRANT_AMBIGUOUS"
    }
    return $candidates[0]
}

function Invoke-AiSopWorkflowCommandGrantScavenge {
    param(
        [string]$IntentSha256,
        [DateTimeOffset]$AcceptedAt,
        [Nullable[DateTimeOffset]]$DeadlineUtc,
        [int]$Limit = 16
    )

    $recordsRoot = Join-Path (
        Get-AiSopWorkflowCommandGrantRegistryRoot
    ) "$IntentSha256\records"
    if (-not [System.IO.Directory]::Exists($recordsRoot)) {
        return
    }
    $cutoff = $AcceptedAt.AddDays(-1)
    $examined = 0
    foreach ($grantPath in @(
        [System.IO.Directory]::EnumerateFiles($recordsRoot, "*.json") |
            Sort-Object
    )) {
        if ($examined -ge $Limit) {
            break
        }
        $examined++
        Assert-AiSopWorkflowDeadline $DeadlineUtc
        $grantId = [System.IO.Path]::GetFileNameWithoutExtension($grantPath)
        $lockPath = "$grantPath.lock"
        $lock = Enter-AiSopWorkflowFileLock `
            -LockPath $lockPath `
            -DeadlineUtc $DeadlineUtc
        try {
            $grant = Read-AiSopWorkflowCommandGrantRecord `
                -GrantPath $grantPath `
                -ExpectedGrantId $grantId
            $issuedAt = [DateTimeOffset]::Parse(
                [string]$grant.issuedAt,
                [System.Globalization.CultureInfo]::InvariantCulture
            )
            if (
                [string]$grant.status -ne "ISSUED" -and
                $issuedAt -lt $cutoff
            ) {
                [System.IO.File]::Delete($grantPath)
                foreach ($kind in @("active", "issued")) {
                    [System.IO.File]::Delete(
                        (Get-AiSopWorkflowCommandGrantMarkerPath `
                            -IntentSha256 $IntentSha256 `
                            -GrantId $grantId `
                            -MarkerKind $kind)
                    )
                }
            }
        } finally {
            $lock.Dispose()
            [System.IO.File]::Delete($lockPath)
        }
    }
}

function Resolve-AiSopWorkflowCommandGrantPlan {
    param(
        [System.Collections.IDictionary]$Session,
        [string]$CommandText,
        [string]$SessionKey,
        [string]$SessionEpochId,
        [string]$DedupKey,
        [DateTimeOffset]$AcceptedAt
    )

    $intent = ConvertFrom-AiSopOwnerCommandIntent `
        -CommandText $CommandText `
        -WorkspacePath ([string]$Session.workspacePath)
    if ([string]$intent.agent -cne [string]$Session.agent) {
        throw "SESSION_IDENTITY_MISMATCH"
    }
    $intentSha256 = Get-AiSopOwnerIntentSha256 $intent
    $effective = Get-AiSopWorkflowSessionEffectiveStatus `
        -Record $Session `
        -AcceptedAt $AcceptedAt
    $grantEpoch = $SessionEpochId
    if ([string]$intent.operation -eq "RebindSession") {
        if ($effective -in @("ENDED", "EXPIRED")) {
            if (
                [string]::IsNullOrEmpty([string]$Session.boundFeature) -or
                [string]$Session.boundFeature -cne
                    [string]$intent.feature -or
                [string]$Session.boundWorkflow -cne
                    [string]$intent.workflow -or
                [string]$Session.boundOwnerId -cne
                    [string]$intent.ownerId
            ) {
                throw "SESSION_INACTIVE"
            }
            if ($grantEpoch -ceq [string]$Session.sessionEpochId) {
                $grantEpoch = Get-AiSopWorkflowSha256 (
                    "rebind-epoch" + [char]0 +
                    $SessionKey + [char]0 +
                    [string]$Session.sessionEpochId + [char]0 +
                    $intentSha256 + [char]0 +
                    $DedupKey
                )
            }
        } elseif (
            $effective -ne "ACTIVE" -or
            [string]$Session.lifecycleProof -ne "CONFIRMED" -or
            -not [string]::IsNullOrEmpty(
                [string]$Session.boundFeature
            ) -or
            $grantEpoch -cne [string]$Session.sessionEpochId
        ) {
            throw "SESSION_INACTIVE"
        }
    } elseif (
        $effective -ne "ACTIVE" -or
        [string]$Session.lifecycleProof -ne "CONFIRMED" -or
        $grantEpoch -cne [string]$Session.sessionEpochId
    ) {
        throw "SESSION_INACTIVE"
    }
    $grantId = Get-AiSopWorkflowSha256 (
        $SessionKey + [char]0 + $grantEpoch + [char]0 +
        $intentSha256 + [char]0 + $DedupKey
    )
    return [pscustomobject][ordered]@{
        GrantId = $grantId
        SessionEpochId = $grantEpoch
        IntentSha256 = $intentSha256
        Intent = $intent
    }
}

function Read-AiSopWorkflowGrantOwnerRecord {
    param(
        [string]$OwnerPath,
        [switch]$AllowMissing
    )

    if (-not [System.IO.File]::Exists($OwnerPath)) {
        if ($AllowMissing) {
            return $null
        }
        throw "COMMAND_GRANT_OWNER_STATE_INVALID"
    }
    try {
        $raw = [System.IO.File]::ReadAllText($OwnerPath)
        if (-not ($raw | Test-Json -SchemaFile $script:WorkflowGrantOwnerSchemaPath)) {
            throw "COMMAND_GRANT_OWNER_STATE_INVALID"
        }
        return ConvertFrom-AiSopWorkflowJson -Json $raw -AsHashtable
    } catch {
        if ($_.Exception.Message -eq "COMMAND_GRANT_OWNER_STATE_INVALID") {
            throw
        }
        throw "COMMAND_GRANT_OWNER_STATE_INVALID"
    }
}

function Test-AiSopWorkflowGrantSessionUnbound {
    param([System.Collections.IDictionary]$Session)

    return (
        [string]::IsNullOrEmpty([string]$Session.boundFeature) -and
        [string]::IsNullOrEmpty([string]$Session.boundWorkflow) -and
        [string]::IsNullOrEmpty([string]$Session.boundOwnerId) -and
        [string]::IsNullOrEmpty([string]$Session.boundSessionEpochId)
    )
}

function Assert-AiSopWorkflowCommandGrantIssueGate {
    param(
        [object]$Intent,
        [System.Collections.IDictionary]$Session,
        [AllowNull()]
        [System.Collections.IDictionary]$Owner,
        [AllowNull()]
        [System.Collections.IDictionary]$OldSession,
        [DateTimeOffset]$AcceptedAt
    )

    $ownerExact = (
        $null -ne $Owner -and
        [string]$Owner.feature -ceq [string]$Intent.feature -and
        [string]$Owner.workflow -ceq [string]$Intent.workflow -and
        [string]$Owner.agent -ceq [string]$Intent.agent -and
        [string]$Owner.ownerId -ceq [string]$Intent.ownerId -and
        ([string]$Owner.specDirectory).Equals(
            [string]$Intent.specDirectory,
            [System.StringComparison]::OrdinalIgnoreCase
        )
    )
    switch ([string]$Intent.operation) {
        "Claim" {
            if (
                -not (Test-AiSopWorkflowGrantSessionUnbound $Session) -or
                ($null -ne $Owner -and [string]$Owner.status -eq "ACTIVE")
            ) {
                throw "COMMAND_GRANT_OWNER_STATE_INVALID"
            }
        }
        "BindSession" {
            if (
                -not $ownerExact -or
                [string]$Owner.schemaVersion -cne "1.0" -or
                [string]$Owner.status -cne "ACTIVE" -or
                [string]$Owner.workflow -cne "SUPERPOWERS" -or
                -not (Test-AiSopWorkflowGrantSessionUnbound $Session)
            ) {
                throw "COMMAND_GRANT_OWNER_STATE_INVALID"
            }
        }
        "RebindSession" {
            if (
                -not $ownerExact -or
                [string]$Owner.schemaVersion -cne "1.1" -or
                [string]$Owner.status -cne "ACTIVE" -or
                -not ([string]$Owner.workspacePath).Equals(
                    [string]$Intent.workspacePath,
                    [System.StringComparison]::OrdinalIgnoreCase
                ) -or
                $null -eq $OldSession -or
                [string]$OldSession.sessionKey -cne
                    [string]$Owner.sessionBinding.sessionKey -or
                [string]$OldSession.sessionEpochId -cne
                    [string]$Owner.sessionBinding.sessionEpochId -or
                [string]$OldSession.boundFeature -cne
                    [string]$Owner.feature -or
                [string]$OldSession.boundWorkflow -cne
                    [string]$Owner.workflow -or
                [string]$OldSession.boundOwnerId -cne
                    [string]$Owner.ownerId -or
                [string]$OldSession.boundSessionEpochId -cne
                    [string]$Owner.sessionBinding.sessionEpochId -or
                (
                    Get-AiSopWorkflowSessionEffectiveStatus `
                        -Record $OldSession `
                        -AcceptedAt $AcceptedAt
                ) -notin @("ENDED", "EXPIRED") -or
                (
                    [string]$Session.sessionKey -cne
                        [string]$OldSession.sessionKey -and
                    -not (Test-AiSopWorkflowGrantSessionUnbound $Session)
                )
            ) {
                throw "COMMAND_GRANT_OWNER_STATE_INVALID"
            }
        }
        { $_ -in @("Validate", "Complete") } {
            if (
                -not $ownerExact -or
                [string]$Owner.schemaVersion -cne "1.1" -or
                [string]$Owner.status -cne "ACTIVE" -or
                -not ([string]$Owner.workspacePath).Equals(
                    [string]$Intent.workspacePath,
                    [System.StringComparison]::OrdinalIgnoreCase
                ) -or
                [string]$Owner.sessionBinding.sessionKey -cne
                    [string]$Session.sessionKey -or
                [string]$Owner.sessionBinding.sessionEpochId -cne
                    [string]$Session.sessionEpochId -or
                [string]$Session.boundFeature -cne [string]$Intent.feature -or
                [string]$Session.boundWorkflow -cne [string]$Intent.workflow -or
                [string]$Session.boundOwnerId -cne [string]$Intent.ownerId -or
                [string]$Session.boundSessionEpochId -cne
                    [string]$Session.sessionEpochId
            ) {
                throw "COMMAND_GRANT_OWNER_STATE_INVALID"
            }
        }
    }
}

function Get-AiSopWorkflowCommandGrantPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$CommandText,

        [Parameter(Mandatory)]
        [ValidatePattern("^[0-9a-f]{64}$")]
        [string]$SessionKey,

        [Parameter(Mandatory)]
        [ValidatePattern("^[A-Za-z0-9._:-]+$")]
        [string]$SessionEpochId,

        [Parameter(Mandatory)]
        [ValidatePattern("^[0-9a-f]{64}$")]
        [string]$DedupKey,

        [Parameter(Mandatory)]
        [DateTimeOffset]$AcceptedAt,

        [Nullable[DateTimeOffset]]$DeadlineUtc
    )

    Assert-AiSopWorkflowDeadline $DeadlineUtc
    Invoke-AiSopWorkflowTransactionRecovery -DeadlineUtc $DeadlineUtc |
        Out-Null
    $sessionPath = Get-AiSopWorkflowSessionPath $SessionKey
    $lockPath = "$sessionPath.lock"
    $lock = Enter-AiSopWorkflowFileLock `
        -LockPath $lockPath `
        -DeadlineUtc $DeadlineUtc
    try {
        $session = Read-AiSopWorkflowSessionRecord `
            -SessionPath $sessionPath `
            -ExpectedSessionKey $SessionKey
        return Resolve-AiSopWorkflowCommandGrantPlan `
            -Session $session `
            -CommandText $CommandText `
            -SessionKey $SessionKey `
            -SessionEpochId $SessionEpochId `
            -DedupKey $DedupKey `
            -AcceptedAt $AcceptedAt
    } finally {
        $lock.Dispose()
        try {
            [System.IO.File]::Delete($lockPath)
        } catch {
            # Lock-file cleanup is not authorization state.
        }
    }
}

function Invoke-AiSopWorkflowCommandGrant {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet("Issue", "Find", "Consume", "Expire")]
        [string]$Operation,

        [string]$CommandText = "",

        [string]$SessionKey = "",

        [string]$SessionEpochId = "",

        [string]$DedupKey = "",

        [string]$GrantId = "",

        [ValidateSet(
            "",
            "Claim",
            "BindSession",
            "RebindSession",
            "Validate",
            "Complete",
            "Transfer"
        )]
        [string]$GrantOperation = "",

        [string]$SpecDirectory = "",

        [string]$Feature = "",

        [string]$Workflow = "",

        [string]$Agent = "",

        [string]$OwnerId = "",

        [Parameter(Mandatory)]
        [DateTimeOffset]$AcceptedAt,

        [string]$TransactionId = "",

        # Grant consumption window in seconds (default 10 keeps synchronous
        # harness hooks unchanged). Pi bootstrap passes a larger value because
        # its grant is issued in a separate process and consumed on a later
        # tool-call / human step rather than in the same hook cycle.
        [int]$GrantTtlSeconds = 10,

        [Nullable[DateTimeOffset]]$DeadlineUtc
    )

    if ($GrantTtlSeconds -lt 1 -or $GrantTtlSeconds -gt 86400) {
        throw "COMMAND_GRANT_ARGUMENT_INVALID"
    }
    Assert-AiSopWorkflowDeadline $DeadlineUtc
    Invoke-AiSopWorkflowTransactionRecovery -DeadlineUtc $DeadlineUtc |
        Out-Null
    switch ($Operation) {
        "Issue" {
            if (
                $SessionKey -notmatch "^[0-9a-f]{64}$" -or
                $SessionEpochId -notmatch "^[A-Za-z0-9._:-]+$" -or
                $DedupKey -notmatch "^[0-9a-f]{64}$" -or
                $TransactionId -notmatch "^[A-Za-z0-9._:-]+$"
            ) {
                throw "COMMAND_GRANT_ARGUMENT_INVALID"
            }
            $sessionPath = Get-AiSopWorkflowSessionPath $SessionKey
            $initialSession = Read-AiSopWorkflowSessionRecord `
                -SessionPath $sessionPath `
                -ExpectedSessionKey $SessionKey
            $initialPlan = Resolve-AiSopWorkflowCommandGrantPlan `
                -Session $initialSession `
                -CommandText $CommandText `
                -SessionKey $SessionKey `
                -SessionEpochId $SessionEpochId `
                -DedupKey $DedupKey `
                -AcceptedAt $AcceptedAt
            $intent = $initialPlan.Intent
            $intentSha256 = $initialPlan.IntentSha256
            $ownerPath = Join-Path (
                Get-AiSopWorkflowOwnerRegistryRoot
            ) (([string]$intent.feature).ToLowerInvariant() + ".json")
            $initialOwner = Read-AiSopWorkflowGrantOwnerRecord `
                -OwnerPath $ownerPath `
                -AllowMissing
            $sessionKeys = @($SessionKey)
            if (
                [string]$intent.operation -eq "RebindSession" -and
                $null -ne $initialOwner -and
                [string]$initialOwner.schemaVersion -eq "1.1"
            ) {
                $sessionKeys += [string]$initialOwner.sessionBinding.sessionKey
            }
            $grantPath = Get-AiSopWorkflowCommandGrantPath `
                -GrantId $initialPlan.GrantId `
                -IntentSha256 $intentSha256
            $lockResult = Enter-AiSopWorkflowTransactionLocks `
                -SessionKeys $sessionKeys `
                -OwnerPath $ownerPath `
                -Targets @([pscustomobject]@{
                    kind = "COMMAND_GRANT"
                    path = $grantPath
                }) `
                -DeadlineUtc $DeadlineUtc
            try {
                $session = Read-AiSopWorkflowSessionRecord `
                    -SessionPath $sessionPath `
                    -ExpectedSessionKey $SessionKey
                $plan = Resolve-AiSopWorkflowCommandGrantPlan `
                    -Session $session `
                    -CommandText $CommandText `
                    -SessionKey $SessionKey `
                    -SessionEpochId $SessionEpochId `
                    -DedupKey $DedupKey `
                    -AcceptedAt $AcceptedAt
                $intent = $plan.Intent
                $intentSha256 = $plan.IntentSha256
                $grantEpoch = $plan.SessionEpochId
                $computedGrantId = $plan.GrantId
                if (
                    $computedGrantId -cne $initialPlan.GrantId -or
                    $intentSha256 -cne $initialPlan.IntentSha256
                ) {
                    throw "COMMAND_GRANT_OWNER_STATE_INVALID"
                }
                $owner = Read-AiSopWorkflowGrantOwnerRecord `
                    -OwnerPath $ownerPath `
                    -AllowMissing
                $oldSession = $null
                if (
                    [string]$intent.operation -eq "RebindSession" -and
                    $null -ne $owner -and
                    [string]$owner.schemaVersion -eq "1.1"
                ) {
                    $oldSessionPath = Get-AiSopWorkflowSessionPath (
                        [string]$owner.sessionBinding.sessionKey
                    )
                    $oldSession = Read-AiSopWorkflowSessionRecord `
                        -SessionPath $oldSessionPath `
                        -ExpectedSessionKey ([string]$owner.sessionBinding.sessionKey)
                }
                Assert-AiSopWorkflowCommandGrantIssueGate `
                    -Intent $intent `
                    -Session $session `
                    -Owner $owner `
                    -OldSession $oldSession `
                    -AcceptedAt $AcceptedAt
                $issuedMarkerPath = Get-AiSopWorkflowCommandGrantMarkerPath `
                    -IntentSha256 $intentSha256 `
                    -GrantId $computedGrantId `
                    -MarkerKind issued
                $activeMarkerPath = Get-AiSopWorkflowCommandGrantMarkerPath `
                    -IntentSha256 $intentSha256 `
                    -GrantId $computedGrantId `
                    -MarkerKind active
                if ([System.IO.File]::Exists($grantPath)) {
                        $existing = Read-AiSopWorkflowCommandGrantRecord `
                            -GrantPath $grantPath `
                            -ExpectedGrantId $computedGrantId
                        if (
                            [string]$existing.sessionKey -cne $SessionKey -or
                            [string]$existing.sessionEpochId -cne $grantEpoch -or
                            [string]$existing.dedupKey -cne $DedupKey -or
                            -not (Test-AiSopWorkflowGrantMatchesIntent `
                                -Grant $existing `
                                -Intent $intent `
                                -IntentSha256 $intentSha256)
                        ) {
                            throw "COMMAND_GRANT_CORRUPT"
                        }
                        if ([string]$existing.status -ne "ISSUED") {
                            throw "COMMAND_GRANT_REPLAYED"
                        }
                        if (
                            [string]$existing.issuedTransactionId -cne
                                $TransactionId
                        ) {
                            throw "COMMAND_GRANT_CORRUPT"
                        }
                        $existingExpiry = [DateTimeOffset]::Parse(
                            [string]$existing.expiresAt,
                            [System.Globalization.CultureInfo]::InvariantCulture
                        )
                        if ($AcceptedAt -ge $existingExpiry) {
                            Set-AiSopWorkflowGrantExpired `
                                -Grant $existing `
                                -GrantPath $grantPath `
                                -DeadlineUtc $DeadlineUtc |
                                Out-Null
                            throw "COMMAND_GRANT_REPLAYED"
                        }
                        Write-AiSopWorkflowCommandGrantMarker `
                            -Path $issuedMarkerPath `
                            -GrantId $computedGrantId
                        Write-AiSopWorkflowCommandGrantMarker `
                            -Path $activeMarkerPath `
                            -GrantId $computedGrantId
                        Set-AiSopWorkflowCommandGrantActiveIndexEntry `
                            -Grant $existing `
                            -Active $true `
                            -DeadlineUtc $DeadlineUtc
                        return New-AiSopWorkflowCommandGrantResult `
                            -Record $existing `
                            -GrantPath $grantPath `
                            -Mutated $false
                }
                $record = [ordered]@{
                        schemaVersion = "1.1"
                        grantId = $computedGrantId
                        status = "ISSUED"
                        sessionKey = $SessionKey
                        sessionEpochId = $grantEpoch
                        agent = [string]$intent.agent
                        workspacePath = [string]$intent.workspacePath
                        operation = [string]$intent.operation
                        feature = [string]$intent.feature
                        specDirectory = [string]$intent.specDirectory
                        workflow = [string]$intent.workflow
                        ownerId = [string]$intent.ownerId
                        intentSha256 = $intentSha256
                        dedupKey = $DedupKey
                        issuedAt = $AcceptedAt.ToUniversalTime().ToString("o")
                        expiresAt =
                            $AcceptedAt.AddSeconds($GrantTtlSeconds).ToUniversalTime().ToString("o")
                        consumedAt = ""
                        issuedTransactionId = $TransactionId
                        consumedTransactionId = ""
                        transactionId = $TransactionId
                }
                # Immutable issuance proof is the exact grant record plus issued
                # marker. Session metadata remains observational and may advance.
                $session.lastGrantId = $computedGrantId
                $session.lastGrantIntentSha256 = $intentSha256
                $session.lastTransactionId = $TransactionId
                Write-AiSopWorkflowSessionRecord `
                    -SessionPath $sessionPath `
                    -Record $session
                Write-AiSopWorkflowCommandGrantRecord `
                    -GrantPath $grantPath `
                    -Record $record
                Write-AiSopWorkflowCommandGrantMarker `
                    -Path $issuedMarkerPath `
                    -GrantId $computedGrantId
                Write-AiSopWorkflowCommandGrantMarker `
                    -Path $activeMarkerPath `
                    -GrantId $computedGrantId
                Set-AiSopWorkflowCommandGrantActiveIndexEntry `
                    -Grant $record `
                    -Active $true `
                    -DeadlineUtc $DeadlineUtc
                return New-AiSopWorkflowCommandGrantResult `
                    -Record $record `
                    -GrantPath $grantPath `
                    -Mutated $true
            } finally {
                Exit-AiSopWorkflowLocks $lockResult.Locks
            }
        }
        "Find" {
            $intent = Get-AiSopWorkflowGrantIntentFromParameters `
                -GrantOperation $GrantOperation `
                -SpecDirectory $SpecDirectory `
                -Feature $Feature `
                -Workflow $Workflow `
                -Agent $Agent `
                -OwnerId $OwnerId
            return Find-AiSopWorkflowCommandGrant `
                -Intent $intent `
                -AcceptedAt $AcceptedAt `
                -DeadlineUtc $DeadlineUtc
        }
        "Consume" {
            if (
                $GrantId -notmatch "^[0-9a-f]{64}$" -or
                $TransactionId -notmatch "^[A-Za-z0-9._:-]+$"
            ) {
                throw "COMMAND_GRANT_ARGUMENT_INVALID"
            }
            $grantPath = Get-AiSopWorkflowCommandGrantPath $GrantId
            $lockPath = "$grantPath.lock"
            $lock = Enter-AiSopWorkflowFileLock `
                -LockPath $lockPath `
                -DeadlineUtc $DeadlineUtc
            try {
                $grant = Read-AiSopWorkflowCommandGrantRecord `
                    -GrantPath $grantPath `
                    -ExpectedGrantId $GrantId
                if ([string]$grant.status -ne "ISSUED") {
                    throw "COMMAND_GRANT_NOT_FOUND"
                }
                $expiresAt = [DateTimeOffset]::Parse(
                    [string]$grant.expiresAt,
                    [System.Globalization.CultureInfo]::InvariantCulture
                )
                if ($AcceptedAt -ge $expiresAt) {
                    Set-AiSopWorkflowGrantExpired `
                        -Grant $grant `
                        -GrantPath $grantPath `
                        -DeadlineUtc $DeadlineUtc |
                        Out-Null
                    throw "COMMAND_GRANT_NOT_FOUND"
                }
                $after = New-AiSopWorkflowCommandGrantAfterConsume `
                    -Grant $grant `
                    -AcceptedAt $AcceptedAt `
                    -TransactionId $TransactionId
                Remove-AiSopWorkflowCommandGrantActiveMarker `
                    -Grant $grant `
                    -DeadlineUtc $DeadlineUtc
                Write-AiSopWorkflowCommandGrantRecord `
                    -GrantPath $grantPath `
                    -Record $after
                return New-AiSopWorkflowCommandGrantResult `
                    -Record $after `
                    -GrantPath $grantPath `
                    -Mutated $true
            } finally {
                $lock.Dispose()
                try {
                    [System.IO.File]::Delete($lockPath)
                } catch {
                    # Lock-file cleanup is not authorization state.
                }
            }
        }
        "Expire" {
            if ($GrantId -notmatch "^[0-9a-f]{64}$") {
                throw "COMMAND_GRANT_ARGUMENT_INVALID"
            }
            $grantPath = Get-AiSopWorkflowCommandGrantPath $GrantId
            $lockPath = "$grantPath.lock"
            $lock = Enter-AiSopWorkflowFileLock `
                -LockPath $lockPath `
                -DeadlineUtc $DeadlineUtc
            try {
                $grant = Read-AiSopWorkflowCommandGrantRecord `
                    -GrantPath $grantPath `
                    -ExpectedGrantId $GrantId
                $mutated = Set-AiSopWorkflowGrantExpired `
                    -Grant $grant `
                    -GrantPath $grantPath `
                    -DeadlineUtc $DeadlineUtc
                return New-AiSopWorkflowCommandGrantResult `
                    -Record $grant `
                    -GrantPath $grantPath `
                    -Mutated $mutated
            } finally {
                $lock.Dispose()
                try {
                    [System.IO.File]::Delete($lockPath)
                } catch {
                    # Lock-file cleanup is not authorization state.
                }
            }
        }
    }
}

function Expire-AiSopWorkflowCommandGrantsForSession {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern("^[0-9a-f]{64}$")]
        [string]$SessionKey,

        [Parameter(Mandatory)]
        [ValidatePattern("^[A-Za-z0-9._:-]+$")]
        [string]$SessionEpochId,

        [Parameter(Mandatory)]
        [DateTimeOffset]$AcceptedAt,

        [Nullable[DateTimeOffset]]$DeadlineUtc
    )

    $sessionIndexPath = Get-AiSopWorkflowCommandGrantSessionIndexPath `
        -SessionKey $SessionKey `
        -SessionEpochId $SessionEpochId
    if (-not [System.IO.File]::Exists($sessionIndexPath)) {
        return @()
    }
    $probeLockPath = "$sessionIndexPath.lock"
    $probeLock = Enter-AiSopWorkflowFileLock `
        -LockPath $probeLockPath `
        -DeadlineUtc $DeadlineUtc
    try {
        $probe = Read-AiSopWorkflowCommandGrantIndex `
            -IndexPath $sessionIndexPath `
            -ExpectedKind SESSION `
            -ExpectedSessionKey $SessionKey `
            -ExpectedSessionEpochId $SessionEpochId
        $intentHashes = @(
            $probe.entries |
                Where-Object { [bool]$_.active } |
                ForEach-Object { [string]$_.intentSha256 } |
                Sort-Object -Unique
        )
    } finally {
        $probeLock.Dispose()
        [System.IO.File]::Delete($probeLockPath)
    }
    $paths = @(
        $sessionIndexPath
        foreach ($intentHash in $intentHashes) {
            Get-AiSopWorkflowCommandGrantActiveIndexPath $intentHash
        }
    ) | Sort-Object -Unique
    $locks = @()
    try {
        foreach ($path in $paths) {
            $locks += Enter-AiSopWorkflowFileLock `
                -LockPath ($path + ".lock") `
                -DeadlineUtc $DeadlineUtc
        }
        $sessionIndex = Read-AiSopWorkflowCommandGrantIndex `
            -IndexPath $sessionIndexPath `
            -ExpectedKind SESSION `
            -ExpectedSessionKey $SessionKey `
            -ExpectedSessionEpochId $SessionEpochId
        $activeEntries = @(
            $sessionIndex.entries |
                Where-Object { [bool]$_.active }
        )
        $expired = @($activeEntries | ForEach-Object { [string]$_.grantId })
        foreach ($intentHash in @(
            $activeEntries |
                ForEach-Object { [string]$_.intentSha256 } |
                Sort-Object -Unique
        )) {
            Assert-AiSopWorkflowDeadline $DeadlineUtc
            $intentPath = Get-AiSopWorkflowCommandGrantActiveIndexPath (
                $intentHash
            )
            $intentIndex = Read-AiSopWorkflowCommandGrantIndex `
                -IndexPath $intentPath `
                -ExpectedKind INTENT `
                -ExpectedIntentSha256 $intentHash
            $sessionGrantIds = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::Ordinal
            )
            foreach ($entry in @(
                $activeEntries |
                    Where-Object {
                        [string]$_.intentSha256 -ceq $intentHash
                    }
            )) {
                [void]$sessionGrantIds.Add([string]$entry.grantId)
            }
            foreach ($entry in @($intentIndex.entries)) {
                if ($sessionGrantIds.Contains([string]$entry.grantId)) {
                    $entry.active = $false
                }
            }
            Write-AiSopWorkflowCommandGrantIndex `
                -IndexPath $intentPath `
                -Index $intentIndex
        }
        foreach ($entry in @($sessionIndex.entries)) {
            $entry.active = $false
        }
        Write-AiSopWorkflowCommandGrantIndex `
            -IndexPath $sessionIndexPath `
            -Index $sessionIndex
        return @($expired)
    } finally {
        for ($lockIndex = $locks.Count - 1; $lockIndex -ge 0; $lockIndex--) {
            $locks[$lockIndex].Dispose()
        }
        foreach ($path in $paths) {
            try {
                [System.IO.File]::Delete($path + ".lock")
            } catch {
                # Lock-file cleanup is not authorization state.
            }
        }
    }
}

function Test-AiSopWorkflowCommandGrantIndexedIssuance {
    param([object]$Grant)

    $intentIndex = Read-AiSopWorkflowCommandGrantIndex `
        -IndexPath (
            Get-AiSopWorkflowCommandGrantActiveIndexPath (
                [string]$Grant.intentSha256
            )
        ) `
        -ExpectedKind INTENT `
        -ExpectedIntentSha256 ([string]$Grant.intentSha256)
    $sessionIndex = Read-AiSopWorkflowCommandGrantIndex `
        -IndexPath (
            Get-AiSopWorkflowCommandGrantSessionIndexPath `
                -SessionKey ([string]$Grant.sessionKey) `
                -SessionEpochId ([string]$Grant.sessionEpochId)
        ) `
        -ExpectedKind SESSION `
        -ExpectedSessionKey ([string]$Grant.sessionKey) `
        -ExpectedSessionEpochId ([string]$Grant.sessionEpochId)
    foreach ($index in @($intentIndex, $sessionIndex)) {
        $entry = @(
            $index.entries |
                Where-Object {
                    [string]$_.grantId -ceq [string]$Grant.grantId
                }
        )
        if (
            $entry.Count -ne 1 -or
            [string]$entry[0].intentSha256 -cne
                [string]$Grant.intentSha256 -or
            [string]$entry[0].sessionKey -cne [string]$Grant.sessionKey -or
            [string]$entry[0].sessionEpochId -cne
                [string]$Grant.sessionEpochId -or
            [string]$entry[0].operation -cne [string]$Grant.operation -or
            [string]$entry[0].expiresAt -cne [string]$Grant.expiresAt
        ) {
            return $false
        }
    }
    return $true
}

function Get-AiSopWorkflowCommandGrantProofState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern("^[A-Za-z0-9._:-]+$")]
        [string]$TransactionId,

        [AllowEmptyString()]
        [string]$GrantId = "",

        [Nullable[DateTimeOffset]]$DeadlineUtc,

        [int64]$RemainingMilliseconds = -1
    )

    if ($RemainingMilliseconds -eq 0) {
        return "INDETERMINATE"
    }
    try {
        Assert-AiSopWorkflowDeadline $DeadlineUtc
        $root = Get-AiSopWorkflowCommandGrantRegistryRoot
        if (-not [System.IO.Directory]::Exists($root)) {
            return "NOT_APPLIED"
        }
        $paths = if ([string]::IsNullOrEmpty($GrantId)) {
            @(
                [System.IO.Directory]::EnumerateFiles(
                    $root,
                    "*.json",
                    [System.IO.SearchOption]::AllDirectories
                ) |
                    Where-Object {
                        (Split-Path -Leaf (Split-Path -Parent $_)) -ceq
                            "records" -or
                        (Split-Path -Parent $_) -eq $root
                    }
            )
        } else {
            @(Get-AiSopWorkflowCommandGrantPath $GrantId)
        }
        $matches = @()
        foreach ($path in $paths) {
            Assert-AiSopWorkflowDeadline $DeadlineUtc
            if (-not [System.IO.File]::Exists($path)) {
                continue
            }
            $expectedId = [System.IO.Path]::GetFileNameWithoutExtension($path)
            $grant = Read-AiSopWorkflowCommandGrantRecord `
                -GrantPath $path `
                -ExpectedGrantId $expectedId
            $issuedTransactionId = if (
                [string]::IsNullOrEmpty([string]$grant.issuedTransactionId)
            ) {
                [string]$grant.transactionId
            } else {
                [string]$grant.issuedTransactionId
            }
            if ($issuedTransactionId -ceq $TransactionId) {
                $issuedMarker = Get-AiSopWorkflowCommandGrantMarkerPath `
                    -IntentSha256 ([string]$grant.intentSha256) `
                    -GrantId ([string]$grant.grantId) `
                    -MarkerKind issued
                if (
                    -not [System.IO.File]::Exists($issuedMarker) -or
                    [System.IO.File]::ReadAllText($issuedMarker) -cne
                        [string]$grant.grantId -or
                    -not (
                        Test-AiSopWorkflowCommandGrantIndexedIssuance `
                            -Grant $grant
                    )
                ) {
                    return "INDETERMINATE"
                }
                $matches += $grant
            } elseif (
                -not [string]::IsNullOrEmpty($GrantId) -and
                [string]$grant.grantId -ceq $GrantId
            ) {
                return "INDETERMINATE"
            }
        }
        if ($matches.Count -eq 1) {
            return "APPLIED"
        }
        if ($matches.Count -gt 1) {
            return "INDETERMINATE"
        }
        return "NOT_APPLIED"
    } catch {
        return "INDETERMINATE"
    }
}

function Test-AiSopWorkflowCommandGrantProof {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern("^[A-Za-z0-9._:-]+$")]
        [string]$TransactionId,

        [AllowEmptyString()]
        [string]$GrantId = "",

        [ValidateSet("ISSUED", "CONSUMED", "EXPIRED")]
        [string]$ExpectedStatus = "ISSUED",

        [Nullable[DateTimeOffset]]$DeadlineUtc,

        [int64]$RemainingMilliseconds = -1
    )

    if (
        $ExpectedStatus -ne "ISSUED" -and
        -not [string]::IsNullOrEmpty($GrantId)
    ) {
        try {
            Assert-AiSopWorkflowDeadline $DeadlineUtc
            $grantPath = Get-AiSopWorkflowCommandGrantPath $GrantId
            $grant = Read-AiSopWorkflowCommandGrantRecord `
                -GrantPath $grantPath `
                -ExpectedGrantId $GrantId
            return (
                [string]$grant.consumedTransactionId -ceq $TransactionId -and
                [string]$grant.status -ceq $ExpectedStatus
            )
        } catch {
            return $false
        }
    }
    if (
        (
            Get-AiSopWorkflowCommandGrantProofState `
                -TransactionId $TransactionId `
                -GrantId $GrantId `
                -DeadlineUtc $DeadlineUtc `
                -RemainingMilliseconds $RemainingMilliseconds
        ) -cne "APPLIED"
    ) {
        return $false
    }
    if ([string]::IsNullOrEmpty($GrantId)) {
        return $true
    }
    try {
        $grantPath = Get-AiSopWorkflowCommandGrantPath $GrantId
        $grant = Read-AiSopWorkflowCommandGrantRecord `
            -GrantPath $grantPath `
            -ExpectedGrantId $GrantId
        return [string]$grant.status -ceq $ExpectedStatus
    } catch {
        return $false
    }
}
