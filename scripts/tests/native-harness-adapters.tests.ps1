#requires -Version 7.0
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$claude=Get-Content -LiteralPath (Join-Path $root 'distribution/templates/hooks/claude-settings.json') -Raw | ConvertFrom-Json
if ($claude.hooks.PreToolUse[0].hooks[0].onFailure -ne 'block') { throw 'Claude 写前 Hook 异常必须阻断' }
foreach ($agent in @('ANTIGRAVITY','CURSOR','PI','CLAUDE_CODE','CODEX')) {
    $output=& pwsh -NoProfile -File (Join-Path $root 'scripts/verify-guard-live.ps1') -Agent $agent
    if ($LASTEXITCODE -ne 0) { throw "$agent adapter probe failed: $output" }
    $result=$output | ConvertFrom-Json
    if ($result.result -ne 'PASS' -or $result.agent -ne $agent -or $result.clientHookCertified) { throw "$agent invalid probe result" }
    Write-Output "$agent task lifecycle adapter passed"
}
& node (Join-Path $PSScriptRoot 'pi-extension.test.mjs')
if ($LASTEXITCODE -ne 0) { throw 'Pi extension bridge tests failed' }
& node (Join-Path $PSScriptRoot 'hook-process.test.mjs')
if ($LASTEXITCODE -ne 0) { throw '真实 Hook 子进程测试失败' }
