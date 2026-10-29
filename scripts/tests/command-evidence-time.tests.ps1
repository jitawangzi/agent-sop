#requires -Version 7.0
[CmdletBinding()]
param([string]$StateScript = (Join-Path (Split-Path -Parent $PSScriptRoot) 'workflow-state.ps1'))
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('command-evidence-time-' + [guid]::NewGuid().ToString('N'))
$fixture = Join-Path $root 'compile-evidence.json'
$script:assertions = 0
$script:now = [DateTimeOffset]::Parse('2026-10-29T09:33:31Z', [Globalization.CultureInfo]::InvariantCulture)
$instant = $script:now.AddTicks(1234567)

function Assert-Equal($Actual, $Expected, [string]$Message) {
    $script:assertions++
    if ($Actual -cne $Expected) { throw "$Message expected=<$Expected> actual=<$Actual>" }
}

# Import the actual function without executing the CLI. Freeze only its two
# clock reads in this test copy; production has no clock override or new policy.
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($StateScript, [ref]$null, [ref]$errors)
if ($errors) { throw "Cannot parse $StateScript : $errors" }
$definition = $ast.Find({ param($node)
    $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-CommandEvidenceProblem'
}, $false)
if (-not $definition) { throw 'Get-CommandEvidenceProblem not found' }
. ([scriptblock]::Create($definition.Extent.Text.Replace('[DateTimeOffset]::UtcNow', '$script:now')))

# Keep digest verification observable without requiring Git or any host input.
function Get-SpecWorkspaceDigest { return $script:currentDigest }
$script:currentDigest = 'a' * 64

function Write-Fixture($Timestamp, [hashtable]$Overrides = @{}) {
    $evidence = [ordered]@{
        exitCode = 0; command = 'pwsh -NoProfile -File ./verify.ps1'
        executedAt = $Timestamp; workingTreeDigest = ('a' * 64)
        testCount = 2; failedCount = 0
    }
    foreach ($key in $Overrides.Keys) { $evidence[$key] = $Overrides[$key] }
    [IO.File]::WriteAllText($fixture, ($evidence | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}

function Assert-Instant([scriptblock]$ReadEvidence, [DateTimeOffset]$Expected, [string]$Label) {
    # Boundaries establish tick-accurate preservation of the instant, including
    # on a UTC host where losing Kind alone would otherwise go unnoticed.
    $script:now = $Expected.AddMinutes(-5)
    Assert-Equal (& $ReadEvidence) $null "$Label at future grace boundary"
    $script:now = $Expected.AddMinutes(-5).AddTicks(-1)
    Assert-Equal (& $ReadEvidence) 'executedAt is in the future' "$Label past future boundary"
    $script:now = $Expected.AddDays(7)
    Assert-Equal (& $ReadEvidence) $null "$Label at freshness boundary"
    $script:now = $Expected.AddDays(7).AddTicks(1)
    Assert-Equal (& $ReadEvidence) 'stale (older than 7 days)' "$Label past freshness boundary"
}

try {
    [IO.Directory]::CreateDirectory($root) | Out-Null
    # This file goes through the unmodified Get-Content | ConvertFrom-Json reader.
    Write-Fixture '2026-10-29T09:33:31Z'
    $materialized = Get-Content -LiteralPath $fixture -Raw | ConvertFrom-Json
    Assert-Equal ($materialized.executedAt -is [datetime]) $true 'JSON reader materializes DateTime'
    Assert-Equal $materialized.executedAt.Kind ([DateTimeKind]::Utc) 'JSON Z retains UTC Kind'
    Assert-Equal (Get-CommandEvidenceProblem -EvidencePath $fixture) $null 'Fresh UTC JSON evidence (HEAD regression)'

    foreach ($offset in @(0, 330, -420)) {
        $text = $instant.ToOffset([TimeSpan]::FromMinutes($offset)).ToString('o')
        Write-Fixture $text
        Assert-Instant { Get-CommandEvidenceProblem -EvidencePath $fixture } $instant "JSON roundtrip offset=$offset"
    }
    Write-Fixture $instant.UtcDateTime.ToString('o')
    Assert-Instant { Get-CommandEvidenceProblem -EvidencePath $fixture } $instant 'JSON Z fractional seconds'

    # Exercise types the reader may return across PS versions, plus strings
    # before automatic date materialization. Only ConvertFrom-Json is stubbed
    # in this child scope; the actual file reader and validator still execute.
    & {
        function ConvertFrom-Json {
            param([Parameter(ValueFromPipeline)]$InputObject)
            process { return $script:typedEvidence }
        }
        $values = @(
            $instant.UtcDateTime,
            $instant.LocalDateTime,
            $instant,
            $instant.ToOffset([TimeSpan]::FromHours(9)),
            $instant.ToOffset([TimeSpan]::FromHours(-7)),
            $instant.UtcDateTime.ToString('o'),
            $instant.ToOffset([TimeSpan]::FromHours(9)).ToString('o'),
            $instant.ToOffset([TimeSpan]::FromHours(-7)).ToString('o')
        )
        foreach ($value in $values) {
            $script:typedEvidence = [pscustomobject]@{exitCode=0; command='verify'; executedAt=$value}
            Assert-Instant { Get-CommandEvidenceProblem -EvidencePath $fixture } $instant "Typed $($value.GetType().Name) $value"
        }
        # These distinct UTC instants share a local wall clock during Denver's
        # autumn overlap. Local DateTime must preserve which instant it denotes.
        # Other host zones exercise the same conversions without changing TZ.
        foreach ($utcText in @('2026-11-01T07:30:00Z', '2026-11-01T08:30:00Z')) {
            $overlap = [DateTimeOffset]::Parse($utcText, [Globalization.CultureInfo]::InvariantCulture)
            $script:typedEvidence = [pscustomobject]@{exitCode=0; command='verify'; executedAt=$overlap.LocalDateTime}
            Assert-Instant { Get-CommandEvidenceProblem -EvidencePath $fixture } $overlap "Local DST overlap $utcText"
        }
        # No-offset values retain the existing local-time contract. Do not
        # invent a UTC zone for an Unspecified DateTime or a no-offset string.
        $unspecified = [DateTime]::SpecifyKind($instant.LocalDateTime, [DateTimeKind]::Unspecified)
        foreach ($value in @($unspecified, $unspecified.ToString('yyyy-MM-ddTHH:mm:ss.fffffff'))) {
            $script:typedEvidence = [pscustomobject]@{exitCode=0; command='verify'; executedAt=$value}
            Assert-Instant { Get-CommandEvidenceProblem -EvidencePath $fixture } ([DateTimeOffset]::new($unspecified)) 'No-offset local contract'
        }
    }

    $script:now = $instant
    foreach ($value in @($null, '', '   ')) {
        Write-Fixture $value
        Assert-Equal (Get-CommandEvidenceProblem -EvidencePath $fixture) 'executedAt missing' 'Missing timestamp'
    }
    foreach ($value in @('not-a-date', '2026-99-29T09:33:31Z', $true, 1, 20261029, 1.25, @('2026-10-29T09:33:31Z'), @{at='2026-10-29T09:33:31Z'})) {
        Write-Fixture $value
        Assert-Equal (Get-CommandEvidenceProblem -EvidencePath $fixture) 'executedAt is not a timestamp' "Invalid timestamp type/value $value"
    }
    # Real no-offset JSON is materialized as Unspecified on supported readers.
    $localText = $instant.LocalDateTime.ToString('yyyy-MM-ddTHH:mm:ss.fffffff')
    Write-Fixture $localText
    Assert-Instant { Get-CommandEvidenceProblem -EvidencePath $fixture } $instant 'JSON no-offset local contract'

    $script:now = $instant
    Write-Fixture $instant.ToString('o') @{exitCode=1}
    Assert-Equal (Get-CommandEvidenceProblem -EvidencePath $fixture) 'exitCode=1' 'Failed command still rejects'
    Write-Fixture $instant.ToString('o') @{command=' '}
    Assert-Equal (Get-CommandEvidenceProblem -EvidencePath $fixture) 'command missing' 'Missing command still rejects'
    Write-Fixture $instant.ToString('o') @{failedCount=1}
    Assert-Equal (Get-CommandEvidenceProblem -EvidencePath $fixture -RequireTestCounts) 'failedCount=1' 'Failed tests still reject'
    Write-Fixture $instant.ToString('o') @{testCount=0}
    Assert-Equal (Get-CommandEvidenceProblem -EvidencePath $fixture -RequireTestCounts) 'testCount=0' 'Empty test run still rejects'
    Write-Fixture $instant.ToString('o') @{workingTreeDigest='invalid'}
    Assert-Equal (Get-CommandEvidenceProblem -EvidencePath $fixture -RequireWorkingTreeDigest) 'workingTreeDigest missing' 'Invalid digest still rejects'
    Write-Fixture $instant.ToString('o') @{workingTreeDigest=('b' * 64)}
    Assert-Equal ((Get-CommandEvidenceProblem -EvidencePath $fixture) -like 'workingTreeDigest stale*') $true 'Changed source digest still rejects'
    $script:currentDigest = $null
    Write-Fixture $instant.ToString('o')
    Assert-Equal (Get-CommandEvidenceProblem -EvidencePath $fixture) 'workingTreeDigest could not be verified (workspace digest unavailable)' 'Unavailable source digest still rejects'
    [IO.File]::WriteAllText($fixture, '{bad-json')
    Assert-Equal ((Get-CommandEvidenceProblem -EvidencePath $fixture) -like 'invalid JSON:*') $true 'Malformed JSON still rejects'
    Write-Output "Command evidence timestamp tests passed: $script:assertions assertions; timezone=$([TimeZoneInfo]::Local.Id)"
} finally {
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
}
