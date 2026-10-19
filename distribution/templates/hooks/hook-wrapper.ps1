# 宿主级 Hook 入口：独立于 .ai-sop，缺少运行时则拒绝写入事件。
param(
    [string]$EventHint = "",
    [ValidateSet('', 'CODEX', 'PI', 'CURSOR', 'ANTIGRAVITY')][string]$AgentHint = ''
)

$ErrorActionPreference = "Stop"

# 管道协议固定 UTF-8，不能继承 Windows 控制台的本地代码页。
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
if (-not $AgentHint) {
    switch (Split-Path -Leaf $PSScriptRoot) {
        '.cursor' { $AgentHint='CURSOR' }
        '.agents' { $AgentHint='ANTIGRAVITY' }
    }
}

if ($PSVersionTable.PSVersion.Major -lt 7) {
    [Console]::Error.WriteLine('AI SOP Hook 需要 PowerShell 7，请使用 pwsh。')
    exit 2
}

$dispatcher = Join-Path $PSScriptRoot '..' '.ai-sop' 'scripts' 'hook-dispatcher.ps1'

if (-not (Test-Path -LiteralPath $dispatcher -PathType Leaf)) {
    $writeish = $EventHint -in @("", "PRE_TOOL_USE", "PRE_INVOCATION")
    if ($writeish) {
        Write-Output '{"decision":"deny","permission":"deny","permissionDecision":"deny","reasonCode":"SOP_DEGRADED_MISSING_DEPS"}'
        exit 2
    }
    Write-Output '{"decision":"ALLOW","reasonCode":"SOP_DEGRADED_MISSING_DEPS"}'
    exit 0
}

& $dispatcher -EventHint $EventHint -AgentHint $AgentHint @args
exit $LASTEXITCODE
