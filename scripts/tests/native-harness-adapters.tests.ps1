#requires -Version 7.0
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
& node (Join-Path $PSScriptRoot 'hook-command.test.mjs')
if ($LASTEXITCODE -ne 0) { throw 'Real Hook process cleanup regression failed' }
& node (Join-Path $PSScriptRoot 'bounded-map.test.mjs')
if ($LASTEXITCODE -ne 0) { throw 'Bounded scheduling regression failed' }
& node (Join-Path $PSScriptRoot 'runtime-copy.test.mjs')
if ($LASTEXITCODE -ne 0) { throw 'Runtime preparation regression failed' }
$claude=Get-Content -LiteralPath (Join-Path $root 'distribution/templates/hooks/claude-settings.json') -Raw | ConvertFrom-Json
if ($claude.hooks.PreToolUse[0].hooks[0].onFailure -ne 'block') { throw 'Claude 写前 Hook 异常必须阻断' }
foreach ($agent in @('ANTIGRAVITY','CURSOR','PI','CLAUDE_CODE','CODEX')) {
    $stageClock=[Diagnostics.Stopwatch]::StartNew()
    $output=& pwsh -NoProfile -File (Join-Path $root 'scripts/verify-guard-live.ps1') -Agent $agent
    if ($LASTEXITCODE -ne 0) { throw "$agent adapter probe failed: $output" }
    $result=$output | ConvertFrom-Json
    if ($result.result -ne 'PASS' -or $result.agent -ne $agent -or $result.clientHookCertified) { throw "$agent invalid probe result" }
    Write-Output "$agent task lifecycle adapter passed"
    Write-Output "STAGE_MS $agent $($stageClock.ElapsedMilliseconds)"
}
$stageClock=[Diagnostics.Stopwatch]::StartNew()
& node (Join-Path $PSScriptRoot 'pi-extension.test.mjs')
if ($LASTEXITCODE -ne 0) { throw 'Pi extension bridge tests failed' }
Write-Output "STAGE_MS pi-extension $($stageClock.ElapsedMilliseconds)"
$stageClock=[Diagnostics.Stopwatch]::StartNew()
& node (Join-Path $PSScriptRoot 'run-hook-process.mjs')
if ($LASTEXITCODE -ne 0) { throw '真实 Hook 子进程测试失败' }
Write-Output "STAGE_MS hook-process $($stageClock.ElapsedMilliseconds)"
