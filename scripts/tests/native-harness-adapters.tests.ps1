#requires -Version 7.0
$ErrorActionPreference='Stop'
$root=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
. (Join-Path $root 'scripts/hidden-process.ps1')
$workers=if ($env:AI_SOP_TEST_WORKERS) { [int]$env:AI_SOP_TEST_WORKERS } else { 1 }
if ($workers -lt 1 -or $workers -gt 4) { throw "Invalid AI_SOP_TEST_WORKERS: $workers" }
& node (Join-Path $PSScriptRoot 'hook-command.test.mjs')
if ($LASTEXITCODE -ne 0) { throw 'Real Hook process cleanup regression failed' }
& node (Join-Path $PSScriptRoot 'bounded-map.test.mjs')
if ($LASTEXITCODE -ne 0) { throw 'Bounded scheduling regression failed' }
& node (Join-Path $PSScriptRoot 'runtime-copy.test.mjs')
if ($LASTEXITCODE -ne 0) { throw 'Runtime preparation regression failed' }
$claude=Get-Content -LiteralPath (Join-Path $root 'distribution/templates/hooks/claude-settings.json') -Raw | ConvertFrom-Json
if ($claude.hooks.PreToolUse[0].hooks[0].onFailure -ne 'block') { throw 'Claude 写前 Hook 异常必须阻断' }
$probeTotalClock=[Diagnostics.Stopwatch]::StartNew()
$probeScript=Join-Path $root 'scripts/verify-guard-live.ps1'
$probeLogRoot=Join-Path ([IO.Path]::GetTempPath()) ('sop-live-probes-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($probeLogRoot) | Out-Null
$probeQueue=[Collections.Generic.Queue[string]]::new()
foreach ($agent in @('ANTIGRAVITY','CURSOR','PI','CLAUDE_CODE','CODEX')) { $probeQueue.Enqueue($agent) }
$probeActive=[Collections.Generic.List[object]]::new()
$probeFailure=$null
try {
    while (($probeQueue.Count -gt 0 -and -not $probeFailure) -or $probeActive.Count -gt 0) {
        while (-not $probeFailure -and $probeQueue.Count -gt 0 -and $probeActive.Count -lt $workers) {
            $agent=$probeQueue.Dequeue()
            $outPath=Join-Path $probeLogRoot "$agent.stdout.log"
            $errPath=Join-Path $probeLogRoot "$agent.stderr.log"
            $failPath=Join-Path $probeLogRoot "$agent.failure.json"
            $proc=Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path `
                -ArgumentList @('-NoProfile','-File',$probeScript,'-Agent',$agent) `
                -RedirectStandardOutput $outPath -RedirectStandardError $errPath -FailurePath $failPath `
                -TimeoutSeconds 120 -CloseStandardInput -PassThru
            $probeActive.Add([pscustomobject]@{agent=$agent;process=$proc;outPath=$outPath;errPath=$errPath})
        }
        foreach ($job in @($probeActive.ToArray())) {
            if ($job.process.Poll()) {
                $disposeError=''; try { $job.process.Dispose() } catch { $disposeError=$_.Exception.Message }
                $facts=Get-AiSopProcessFacts $job.process -DisposeError $disposeError
                $stdout=if (Test-Path -LiteralPath $job.outPath) { [IO.File]::ReadAllText($job.outPath) } else { '' }
                $stderr=if (Test-Path -LiteralPath $job.errPath) { [IO.File]::ReadAllText($job.errPath) } else { '' }
                [void]$probeActive.Remove($job)
                if (-not $facts.cleanupConfirmed -or $facts.resultError -or $facts.exitCode -ne 0) {
                    if (-not $probeFailure) {
                        $probeFailure="$($job.agent) adapter probe failed (exit=$($facts.exitCode); diag=$($facts.diagnostic); cleanup=$($facts.cleanupConfirmed)): $stdout $stderr"
                    }
                    continue
                }
                try {
                    $result=$stdout | ConvertFrom-Json
                    if ($result.result -ne 'PASS' -or $result.agent -ne $job.agent -or $result.clientHookCertified) {
                        if (-not $probeFailure) { $probeFailure="$($job.agent) invalid probe result: $stdout" }
                        continue
                    }
                } catch {
                    if (-not $probeFailure) { $probeFailure="$($job.agent) probe JSON parse failed: $($_.Exception.Message); out=$stdout" }
                    continue
                }
                Write-Output "$($job.agent) task lifecycle adapter passed"
                Write-Output "STAGE_MS $($job.agent) $($job.process.Clock.ElapsedMilliseconds)"
            }
        }
        if ($probeActive.Count -gt 0) { [Threading.Thread]::Sleep(50) }
    }
    if ($probeFailure) { throw $probeFailure }
} finally {
    foreach ($job in $probeActive) { if ($job.process) { try { $job.process.Dispose() } catch {} } }
    if (-not $probeFailure -and (Test-Path -LiteralPath $probeLogRoot)) {
        Remove-Item -LiteralPath $probeLogRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Write-Output "STAGE_MS verify-guard-live-total $($probeTotalClock.ElapsedMilliseconds)"
$stageClock=[Diagnostics.Stopwatch]::StartNew()
& node (Join-Path $PSScriptRoot 'pi-extension.test.mjs')
if ($LASTEXITCODE -ne 0) { throw 'Pi extension bridge tests failed' }
Write-Output "STAGE_MS pi-extension $($stageClock.ElapsedMilliseconds)"
$stageClock=[Diagnostics.Stopwatch]::StartNew()
& node (Join-Path $PSScriptRoot 'run-hook-process.mjs')
if ($LASTEXITCODE -ne 0) { throw '真实 Hook 子进程测试失败' }
Write-Output "STAGE_MS hook-process $($stageClock.ElapsedMilliseconds)"
