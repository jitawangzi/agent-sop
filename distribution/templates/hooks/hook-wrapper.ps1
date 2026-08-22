# .agents/hook-wrapper.ps1 — Anti-self-lock wrapper for AI SOP hooks.
#
# This file lives in the ROOT Git repo (NOT in the .ai-sop submodule), so it
# is always present on disk after a fresh clone, even before `git submodule
# update --init`. It breaks the self-lock deadlock where a missing
# hook-dispatcher.ps1 (uninitialized submodule) blocks all tool calls —
# including the very command needed to initialize the submodule.
#
# hooks.json / settings.json point here via `pwsh -NoProfile -File <this>`.
# This wrapper checks whether the real dispatcher exists; if not, it outputs
# a permissive ALLOW result and exits 0 with empty stderr (so harnesses that
# treat stderr as failure still pass). If the dispatcher exists, it forwards.
param(
    [string]$EventHint = ""
)

$ErrorActionPreference = "Stop"

# The dispatcher requires PowerShell 7+ (#requires -Version 7.0). Windows PowerShell
# 5.1 (the `powershell` binary) cannot run it, and 5.1's Join-Path does not accept
# 4 path arguments. If we are not on 7+, degrade gracefully to ALLOW (empty stderr,
# exit 0) so the harness keeps working rather than erroring every tool call. The
# real dispatcher runs under pwsh 7 (hooks.json / settings.json invoke `pwsh`).
if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Output '{"decision":"ALLOW","reasonCode":"SOP_DEGRADED_LEGACY_POWERSHELL"}'
    exit 0
}

# PS 7+: Join-Path accepts multiple path segments here.
$dispatcher = Join-Path $PSScriptRoot '..' '.ai-sop' 'scripts' 'hook-dispatcher.ps1'

# Resolve to absolute for Test-Path (relative paths can be cwd-sensitive).
if (-not (Test-Path -LiteralPath $dispatcher -PathType Leaf)) {
    # Submodule not initialized or dispatcher missing — graceful degradation.
    # Output a permissive ALLOW result (some harnesses parse stdout as JSON).
    # stderr is intentionally empty so harnesses don't misinterpret it as failure.
    Write-Output '{"decision":"ALLOW","reasonCode":"SOP_DEGRADED_MISSING_DEPS"}'
    exit 0
}

# Dispatcher exists — forward all args. stdin is inherited so the dispatcher
# can read the hook payload via [Console]::In.ReadToEnd(). Do not capture
# stdout here: the dispatcher writes with [Console]::Out.WriteLine, which
# bypasses PowerShell pipeline capture. Capturing then writing a fallback
# would emit two JSON objects and crash Antigravity.
& $dispatcher -EventHint $EventHint @args
exit $LASTEXITCODE
