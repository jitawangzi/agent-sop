#requires -Version 7.0

# AI SOP environment self-check ("doctor").
# Run after install-ai-sop.ps1 to verify the local environment is ready:
#   pwsh -NoProfile -File ./.ai-sop/scripts/doctor.ps1
# Checks: PowerShell version, Git, SVN, JDK 8, Gradle wrapper, hook injection,
# submodule init, current harness capability. Exits 0 if all pass, 1 if any fail.

[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$SopRoot = Split-Path -Parent $PSScriptRoot
$WorkspaceRoot = Split-Path -Parent $SopRoot

$results = [System.Collections.Generic.List[pscustomobject]]::new()
function Add-Check {
    param([string]$Name, [bool]$Pass, [string]$Detail)
    $results.Add([pscustomobject]@{ Name = $Name; Pass = $Pass; Detail = $Detail })
}

# 1. PowerShell version (requires 7.0+)
$psVer = $PSVersionTable.PSVersion.ToString()
Add-Check "PowerShell 7+" ($PSVersionTable.PSVersion.Major -ge 7) $psVer

# 2. Git available
try {
    $gitVer = (git --version 2>&1) | Out-String
    Add-Check "Git CLI" $true $gitVer.Trim()
} catch {
    Add-Check "Git CLI" $false "not found"
}

# 3. Version Control CLI (Git / SVN)
$hasSvnWorkingCopy = Test-Path -LiteralPath (Join-Path $WorkspaceRoot ".svn")
if ($hasSvnWorkingCopy) {
    try {
        $svnVer = (svn --version --quiet 2>&1) | Out-String
        Add-Check "SVN CLI" (-not [string]::IsNullOrWhiteSpace($svnVer)) $svnVer.Trim()
    } catch {
        Add-Check "SVN CLI" $false "not found (required for .svn working copy)"
    }
} else {
    try {
        $svnVer = (svn --version --quiet 2>&1) | Out-String
        if (-not [string]::IsNullOrWhiteSpace($svnVer)) {
            Add-Check "SVN CLI" $true "$($svnVer.Trim()) (optional)"
        }
    } catch { }
}

# 4. Project Toolchain Detection (dynamic & polyglot)
$detectedToolchain = $false

$isJavaProject = (Test-Path -LiteralPath (Join-Path $WorkspaceRoot "pom.xml")) -or 
                 (Test-Path -LiteralPath (Join-Path $WorkspaceRoot "build.gradle")) -or 
                 (Test-Path -LiteralPath (Join-Path $WorkspaceRoot "build.gradle.kts")) -or
                 (Test-Path -LiteralPath (Join-Path $WorkspaceRoot "gradlew.bat")) -or
                 (Test-Path -LiteralPath (Join-Path $WorkspaceRoot "gradlew"))
if ($isJavaProject) {
    $detectedToolchain = $true
    $javaHome = [string]$env:JAVA_HOME
    $javaOk = $false
    $javaDetail = "JAVA_HOME not set"
    if (-not [string]::IsNullOrWhiteSpace($javaHome) -and (Test-Path -LiteralPath $javaHome)) {
        try {
            $javaBin = Join-Path (Join-Path $javaHome "bin") "java"
            if (-not (Test-Path -LiteralPath $javaBin)) { $javaBin = Join-Path (Join-Path $javaHome "bin") "java.exe" }
            $javaOut = (& $javaBin -version 2>&1) | Out-String
            $javaOk = $true
            $javaDetail = "Java runtime at $javaHome"
        } catch {
            $javaDetail = "JAVA_HOME set but java not runnable: $_"
        }
    }
    Add-Check "JDK Toolchain" $javaOk $javaDetail
    
    $gradlew = Join-Path $WorkspaceRoot "gradlew.bat"
    if (-not (Test-Path -LiteralPath $gradlew)) { $gradlew = Join-Path $WorkspaceRoot "gradlew" }
    if (Test-Path -LiteralPath $gradlew) { Add-Check "Gradle wrapper" $true $gradlew }
}

$isGoProject = Test-Path -LiteralPath (Join-Path $WorkspaceRoot "go.mod")
if ($isGoProject) {
    $detectedToolchain = $true
    try {
        $goVer = (go version 2>&1) | Out-String
        Add-Check "Go Toolchain" (-not [string]::IsNullOrWhiteSpace($goVer)) $goVer.Trim()
    } catch {
        Add-Check "Go Toolchain" $false "go CLI not found"
    }
}

$isNodeProject = Test-Path -LiteralPath (Join-Path $WorkspaceRoot "package.json")
if ($isNodeProject) {
    $detectedToolchain = $true
    try {
        $nodeVer = (node -v 2>&1) | Out-String
        Add-Check "Node.js" (-not [string]::IsNullOrWhiteSpace($nodeVer)) $nodeVer.Trim()
    } catch {
        Add-Check "Node.js" $false "node not found"
    }
}

$isPythonProject = (Test-Path -LiteralPath (Join-Path $WorkspaceRoot "pyproject.toml")) -or 
                   (Test-Path -LiteralPath (Join-Path $WorkspaceRoot "requirements.txt"))
if ($isPythonProject) {
    $detectedToolchain = $true
    try {
        $pyVer = (python --version 2>&1) | Out-String
        Add-Check "Python" (-not [string]::IsNullOrWhiteSpace($pyVer)) $pyVer.Trim()
    } catch {
        Add-Check "Python" $false "python not found"
    }
}

$isRustProject = Test-Path -LiteralPath (Join-Path $WorkspaceRoot "Cargo.toml")
if ($isRustProject) {
    $detectedToolchain = $true
    try {
        $cargoVer = (cargo --version 2>&1) | Out-String
        Add-Check "Rust/Cargo" (-not [string]::IsNullOrWhiteSpace($cargoVer)) $cargoVer.Trim()
    } catch {
        Add-Check "Rust/Cargo" $false "cargo not found"
    }
}

if (-not $detectedToolchain) {
    Add-Check "Project Toolchain" $true "Generic Codebase"
}

# 6. .ai-sop submodule initialized (hook-dispatcher.ps1 exists)
$dispatcher = Join-Path $SopRoot "scripts/hook-dispatcher.ps1"
Add-Check "Submodule init" (Test-Path -LiteralPath $dispatcher -PathType Leaf) $dispatcher

# 7. Hook injection status (check generated projection files exist)
$agentsHooks = Join-Path $WorkspaceRoot ".agents/hooks.json"
$claudeSettings = Join-Path $WorkspaceRoot ".claude/settings.json"
$hookInjected = (Test-Path -LiteralPath $agentsHooks) -or (Test-Path -LiteralPath $claudeSettings)
Add-Check "Hook injected" $hookInjected ".agents/hooks.json or .claude/settings.json"

# 8. Superpowers skill suite presence (enables full T3)
$superpowersFound = $false
$userProfile = [System.Environment]::GetFolderPath([System.Environment+SpecialFolder]::UserProfile)
$spLocations = @(
    (Join-Path $userProfile ".gemini/config/plugins/superpowers"),
    (Join-Path $userProfile ".claude/plugins/superpowers"),
    (Join-Path $userProfile ".cursor/plugins/superpowers")
)
foreach ($loc in $spLocations) {
    if (Test-Path -LiteralPath $loc -PathType Container) {
        $superpowersFound = $true
        break
    }
}
if ($superpowersFound) {
    Add-Check "Superpowers Suite" $true "Found (T3 enabled)"
} else {
    Add-Check "Superpowers Suite" $true "WARN: Not detected (T2/FastTrack works; T3 needs install per VERIFICATION.md)"
}

# 9. Lock file present
$lockPath = Join-Path $WorkspaceRoot "tools/ai-sop/ai-sop.lock.json"
Add-Check "Lock file" (Test-Path -LiteralPath $lockPath) $lockPath

# 10. Harness capability (if script available)
$capScript = Join-Path $SopRoot "scripts/harness-capability.ps1"
$overridePath = Join-Path $SopRoot ".harness-capability-override.json"
$hasOverride = Test-Path -LiteralPath $overridePath -PathType Leaf
if (Test-Path -LiteralPath $capScript) {
    try {
        $cap = & $capScript -All 2>&1 | Out-String
        $summary = $cap.Trim().Substring(0, [Math]::Min(120, $cap.Trim().Length))
        if ($hasOverride) {
            $summary += " | LOCAL OVERRIDE in .harness-capability-override.json — decisions reflect per-machine downgrade(s), not the static table default"
        }
        Add-Check "Harness capability" $true $summary
    } catch {
        Add-Check "Harness capability" $false "probe failed: $_"
    }
} else {
    Add-Check "Harness capability" $false "harness-capability.ps1 not found"
}
if ($hasOverride) {
    Add-Check "Capability override" $true "local override file present — a STRICT harness may be downgraded on this machine; verify the override is intentional (gitignored, not shared)"
}

# 11. .ai-workspace/context/ exists + freshness check
$contextDir = Join-Path $WorkspaceRoot ".ai-workspace/context"
$contextExists = Test-Path -LiteralPath $contextDir
Add-Check "Context dir" $contextExists $contextDir
if ($contextExists) {
    # Check required context files for freshness (context-meta header)
    $required = @("project-summary.md", "coding-style.md", "business-logic-pattern.md", "project-tooling.md")
    $stale = @()
    foreach ($cf in $required) {
        $cfPath = Join-Path $contextDir $cf
        if (Test-Path -LiteralPath $cfPath -PathType Leaf) {
            $firstLine = Get-Content -LiteralPath $cfPath -TotalCount 1 -ErrorAction SilentlyContinue
            if ($firstLine -match "expiresAt:\s*(\d{4}-\d{2})") {
                try {
                    $expiresStr = $Matches[1] + "-01"
                    $expires = [datetime]::ParseExact($expiresStr, "yyyy-MM-dd", $null)
                    $expiresEnd = $expires.AddMonths(1)
                    if ([datetime]::UtcNow -gt $expiresEnd) {
                        $stale += "$cf (expired $($Matches[1]) — WARN, not fatal)"
                    }
                } catch {
                    $stale += "$cf (bad date format — WARN, not fatal)"
                }
            }
        }
    }
    # Freshness is advisory — stale/bad-date context is WARN not FAIL (never blocks install).
    # Only MISSING required files fail; stale files still pass with WARN detail.
    Add-Check "Context freshness" $true $(if ($stale.Count -eq 0) { "all fresh" } else { "WARN: " + ($stale -join "; ") })
}

# 12. Root AGENTS.md projection freshness
$rootAgents = Join-Path $WorkspaceRoot "AGENTS.md"
$templateAgents = Join-Path $SopRoot "distribution/templates/root/AGENTS.md"
if ((Test-Path -LiteralPath $rootAgents -PathType Leaf) -and (Test-Path -LiteralPath $templateAgents -PathType Leaf)) {
    $rootHash = (Get-FileHash -LiteralPath $rootAgents -Algorithm SHA256).Hash
    $templateHash = (Get-FileHash -LiteralPath $templateAgents -Algorithm SHA256).Hash
    if ($rootHash -ne $templateHash) {
        Add-Check "AGENTS.md Projection" $true "WARN: 根目录 AGENTS.md 与真源模板不一致 (请运行 'ai-sop.ps1 Update' 刷新)"
    } else {
        Add-Check "AGENTS.md Projection" $true "up to date"
    }
}

# 13. Root ai-sop.ps1 projection freshness
$rootAiSop = Join-Path $WorkspaceRoot "ai-sop.ps1"
$templateAiSop = Join-Path $SopRoot "distribution/templates/root/ai-sop.ps1"
if ((Test-Path -LiteralPath $rootAiSop -PathType Leaf) -and (Test-Path -LiteralPath $templateAiSop -PathType Leaf)) {
    $rootHash = (Get-FileHash -LiteralPath $rootAiSop -Algorithm SHA256).Hash
    $templateHash = (Get-FileHash -LiteralPath $templateAiSop -Algorithm SHA256).Hash
    if ($rootHash -ne $templateHash) {
        Add-Check "ai-sop.ps1 Projection" $true "WARN: 根目录 ai-sop.ps1 与真源模板不一致 (请运行 'ai-sop.ps1 Update' 刷新)"
    } else {
        Add-Check "ai-sop.ps1 Projection" $true "up to date"
    }
}

# Report
$warnCount = @($results | Where-Object { $_.Pass -and $_.Detail -match "^WARN" }).Count
$failCount = @($results | Where-Object { -not $_.Pass }).Count
$cleanPassCount = @($results | Where-Object { $_.Pass -and -not ($_.Detail -match "^WARN") }).Count
foreach ($r in $results) {
    $mark = if ($r.Pass -and $r.Detail -match "^WARN") { "⚠️" } elseif ($r.Pass) { "✅" } else { "❌" }
    Write-Host ("{0} {1,-22} {2}" -f $mark, $r.Name, $r.Detail)
}
Write-Host ""
if ($failCount -gt 0) {
    Write-Host ("{0}/{1} checks passed ({2} failed, {3} warnings)" -f ($cleanPassCount + $warnCount), $results.Count, $failCount, $warnCount) -ForegroundColor Red
    exit 1
} elseif ($warnCount -gt 0) {
    Write-Host ("{0}/{1} checks passed ({2} passed, {3} warnings)" -f ($cleanPassCount + $warnCount), $results.Count, $cleanPassCount, $warnCount) -ForegroundColor Yellow
    exit 0
} else {
    Write-Host ("{0}/{1} checks passed (all clean)" -f $cleanPassCount, $results.Count) -ForegroundColor Green
    exit 0
}
