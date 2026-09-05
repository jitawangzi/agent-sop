#requires -Version 7.0
# Harness capability probe + admission decider (DC-004/005).
# Probes per-runtime capabilities from a built-in known-capability table
# (DC-005) and emits a schema-valid harness-capability record. STRICT requires
# all critical capabilities (subagent, evidence); any missing/unknown -> BLOCKED
# (never silently degrade). pauseResume/blockingHook/skillDiscovery are auxiliary.

[CmdletBinding()]
param(
    [ValidateSet("CLAUDE_CODE", "COPILOT", "ANTIGRAVITY", "CURSOR", "PI", "")]
    [string]$Agent = "",

    [ValidateSet("CLI", "APP", "SDK_LOCAL", "CLOUD", "")]
    [string]$Runtime = "",

    [string]$ProductVersion = "unknown",

    [string]$Os = "",

    [string]$PwshVersion = "",

    [switch]$All
)

$ErrorActionPreference = "Stop"
$ClaudeRoot = Split-Path -Parent $PSScriptRoot
$SchemaPath = Join-Path $ClaudeRoot "schemas\harness-capability.schema.json"

# Critical capability set (DC-004): all must be true for STRICT.
# T3 requires independent review, NOT session-resume. So CRITICAL =
# subagent (can dispatch independent-context reviewer) + evidence
# (subagent runs in distinct session with transcript).
# pauseResume/blockingHook are auxiliary (recorded, not gating).
$script:CriticalCapabilities = @(
    "subagent",
    "evidence"
)

# Known capability table (DC-005). Static, based on documented tool behavior.
# subagent is CRITICAL (gating). workspace is auxiliary (recorded, not gating) — recorded for traceability.
function Get-AiSopKnownCapability {
    param([string]$A, [string]$R)
    # Returns a capabilities hashtable + evidence, or $null if unknown.
    switch ($A) {
        "CLAUDE_CODE" {
            if ($R -ne "CLI") { return $null }
            return @{
                capabilities = [ordered]@{
                    skillDiscovery = $true   # .claude/skills
                    subagent       = $true   # native subagent
                    blockingHook   = $true   # PreToolUse deny
                    workspace      = $true
                    pauseResume    = $true   # SessionStart/End + resume
                    evidence       = $true   # subagent distinct session + transcript
                }
                evidence = [ordered]@{
                    skillPath = ".claude/skills"
                    hookConfig = ".claude/settings.json PreToolUse"
                    sessionMechanism = "native session_id"
                    subagentMechanism = "native subagent_type"
                    note = ""
                }
            }
        }
        "COPILOT" {
            if ($R -notin @("CLI", "APP")) { return $null }
            return @{
                capabilities = [ordered]@{
                    skillDiscovery = $true   # .agents/skills
                    subagent       = $true
                    blockingHook   = $true
                    workspace      = $true
                    pauseResume    = $false  # lifecycle support varies; mark false until live-confirmed
                    evidence       = $true   # Task/subagent provides independent context
                }
                evidence = [ordered]@{
                    skillPath = ".agents/skills"
                    hookConfig = ".github/hooks + .claude/hooks"
                    sessionMechanism = "sessionId"
                    subagentMechanism = "native"
                    note = "pauseResume pending live confirmation (P3); subagent+evidence confirmed for T3 review"
                }
            }
        }
        "ANTIGRAVITY" {
            if ($R -notin @("CLI", "APP")) { return $null }
            return @{
                capabilities = [ordered]@{
                    skillDiscovery = $true
                    subagent       = $true
                    blockingHook   = $true
                    workspace      = $true
                    pauseResume    = $false
                    evidence       = $true   # native invoke_subagent provides independent-context review
                }
                evidence = [ordered]@{
                    skillPath = ".agents/skills"
                    hookConfig = ".agents/hooks.json"
                    sessionMechanism = "native"
                    subagentMechanism = "invoke_subagent (native)"
                    note = "pauseResume pending live confirmation (P3); subagent+evidence confirmed for T3 review"
                }
            }
        }
        "CURSOR" {
            if ($R -notin @("CLI", "APP")) { return $null }
            return @{
                capabilities = [ordered]@{
                    skillDiscovery = $true   # .cursor/skills / .agents/skills
                    subagent       = $true
                    blockingHook   = $true   # .cursor/hooks failClosed
                    workspace      = $true
                    pauseResume    = $true
                    evidence       = $true
                }
                evidence = [ordered]@{
                    skillPath = ".cursor/skills, .agents/skills"
                    hookConfig = ".cursor/hooks.json failClosed"
                    sessionMechanism = "conversation_id"
                    subagentMechanism = "native"
                    note = ""
                }
            }
        }
        "PI" {
            if ($R -ne "CLI") { return $null }
            return @{
                capabilities = [ordered]@{
                    skillDiscovery = $true   # .agents/skills, .pi/skills
                    subagent       = $false  # core has no subagent/plan
                    blockingHook   = $true   # tool_call can block
                    workspace      = $true
                    pauseResume    = $true   # session_start/session_before_switch
                    evidence       = $false  # no independent subagent -> no distinct-session review
                }
                evidence = [ordered]@{
                    skillPath = ".agents/skills, .pi/skills"
                    hookConfig = "tool_call extension block"
                    sessionMechanism = "session_start/session_before_switch"
                    subagentMechanism = "none (core)"
                    note = "No native subagent: independent review (T3) not available; T2 only"
                }
            }
        }
        default { return $null }
    }
}

function Test-AiSopHarnessCapability {
    # DC-004: decide STRICT/BLOCKED from capabilities.
    param([hashtable]$Capabilities)
    $missing = @()
    foreach ($c in $script:CriticalCapabilities) {
        if (-not [bool]$Capabilities[$c]) { $missing += $c }
    }
    if ($missing.Count -eq 0) {
        return [pscustomobject]@{ Decision = "STRICT"; Reason = "all critical capabilities satisfied" }
    }
    return [pscustomobject]@{ Decision = "BLOCKED"; Reason = ("missing critical: " + ($missing -join ", ")) }
}

function New-AiSopHarnessCapabilityRecord {
    param([string]$A, [string]$R, [string]$Ver, [string]$OsVal, [string]$Pwsh)
    $known = Get-AiSopKnownCapability -A $A -R $R
    $probedAt = [DateTimeOffset]::UtcNow.ToString("o")
    if ($null -eq $known) {
        return [ordered]@{
            agent = $A
            runtime = $R
            productVersion = $Ver
            os = $OsVal
            pwshVersion = $Pwsh
            capabilities = [ordered]@{
                skillDiscovery = $false; subagent = $false; blockingHook = $false
                workspace = $false; pauseResume = $false; evidence = $false
            }
            decision = "BLOCKED"
            decisionReason = "unknown agent/runtime combination"
            evidence = [ordered]@{ note = "no known capability record" }
            probedAt = $probedAt
        }
    }
    # Merge local override (gitignored, per-machine). The static table is a declared
    # default; real environments may differ (e.g. an internal-proxy Copilot without
    # subagent, a Cursor build with broken subagent dispatch). A local override lets the
    # user downgrade a capability so the SOP does not force T3 subagent dispatch and
    # crash/hang. Overrides are one-way: true → false only (cannot upgrade BLOCKED
    # to STRICT). Override file format:
    #   { "CLAUDE_CODE": { "subagent": false, "_reason": "this build's subagent broken" } }
    # Only capability booleans are merged; _reason is surfaced in evidence.note.
    $overridePath = Join-Path $ClaudeRoot ".harness-capability-override.json"
    $overrideNote = ""
    if (Test-Path -LiteralPath $overridePath -PathType Leaf) {
        try {
            $override = Get-Content -LiteralPath $overridePath -Raw | ConvertFrom-Json
            $agentOverride = $override.$A
            if ($null -ne $agentOverride) {
                $merged = [ordered]@{}
                foreach ($k in $known.capabilities.Keys) { $merged[$k] = $known.capabilities[$k] }
                $reason = [string]$agentOverride._reason
                $changed = @()
                foreach ($prop in $agentOverride.PSObject.Properties) {
                    $name = $prop.Name
                    if ($name -eq "_reason") { continue }
                    if ($merged.Contains($name)) {
                        $val = $prop.Value
                        if ($val -isnot [bool]) {
                            try { $val = [bool]::Parse([string]$val) } catch { continue }
                        }
                        # Downgrade only: true → false. BLOCKED tools cannot
                        # self-upgrade to STRICT via a local override file.
                        if ($merged[$name] -eq $true -and $val -eq $false) {
                            $merged[$name] = $false
                            $changed += "$name=False"
                        }
                    }
                }
                if ($changed.Count -gt 0) {
                    $overrideNote = "LOCAL OVERRIDE applied: " + ($changed -join ", ")
                    if ($reason) { $overrideNote += " — reason: $reason" }
                    $known.capabilities = $merged
                }
            }
        } catch {
            $overrideNote = "LOCAL OVERRIDE file unreadable ($($_.Exception.Message)); ignored, using static table"
        }
    }
    $dec = Test-AiSopHarnessCapability -Capabilities $known.capabilities
    $evidenceOut = [ordered]@{}
    foreach ($k in $known.evidence.Keys) { $evidenceOut[$k] = $known.evidence[$k] }
    if ($overrideNote) { $evidenceOut.note = ($known.evidence.note + $(if ($known.evidence.note) { " | " } else { "" }) + $overrideNote) }
    return [ordered]@{
        agent = $A
        runtime = $R
        productVersion = $Ver
        os = $OsVal
        pwshVersion = $Pwsh
        capabilities = $known.capabilities
        decision = $dec.Decision
        decisionReason = $dec.Reason
        evidence = $evidenceOut
        probedAt = $probedAt
    }
}

# Build the probe set.
$probeSet = @()
if ($All -or ($Agent -eq "" -and $Runtime -eq "")) {
    foreach ($a in @("CLAUDE_CODE","COPILOT","ANTIGRAVITY","CURSOR","PI")) {
        $probeSet += @{ agent = $a; runtime = "CLI" }
    }
} elseif ($Agent -ne "" -and $Runtime -ne "") {
    $probeSet += @{ agent = $Agent; runtime = $Runtime }
} elseif ($Agent -ne "") {
    $probeSet += @{ agent = $Agent; runtime = "CLI" }
} else {
    foreach ($a in @("CLAUDE_CODE","COPILOT","ANTIGRAVITY","CURSOR","PI")) {
        $probeSet += @{ agent = $a; runtime = "CLI" }
    }
}

$harnesses = @()
foreach ($p in $probeSet) {
    $harnesses += New-AiSopHarnessCapabilityRecord -A $p.agent -R $p.runtime -Ver $ProductVersion -OsVal $Os -Pwsh $PwshVersion
}

# Release decision: STRICT only if ALL harnesses STRICT; MIXED if any STRICT any BLOCKED; BLOCKED if all BLOCKED.
$strictCount = @($harnesses | Where-Object { $_.decision -eq "STRICT" }).Count
$blockedCount = @($harnesses | Where-Object { $_.decision -eq "BLOCKED" }).Count
$release = if ($strictCount -eq $harnesses.Count) { "STRICT" }
           elseif ($strictCount -eq 0) { "BLOCKED" }
           else { "MIXED" }

$result = [ordered]@{
    schemaVersion = "1.0"
    generatedAt = [DateTimeOffset]::UtcNow.ToString("o")
    releaseDecision = $release
    harnesses = $harnesses
}

# Validate against schema.
try {
    ($result | ConvertTo-Json -Depth 10) | Test-Json -SchemaFile $SchemaPath | Out-Null
} catch {
    throw "AI_SOP_CAPABILITY_SCHEMA_INVALID: $($_.Exception.Message)"
}

$result | ConvertTo-Json -Depth 10
