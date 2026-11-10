#requires -Version 7.0
$ErrorActionPreference='Stop'
$scripts=Split-Path $PSScriptRoot
. (Join-Path $scripts hidden-process.ps1)
. (Join-Path $scripts test-execution-environment.ps1)
function Assert($condition,$message){if(-not $condition){throw $message}}
$root=Join-Path ([IO.Path]::GetTempPath()) ('execution-environment-'+[guid]::NewGuid().ToString('N'))
$passed=$false
[IO.Directory]::CreateDirectory($root)|Out-Null
try{
    $originalPath=$env:PATH
    $toolDir=Join-Path $root 'tools here';[IO.Directory]::CreateDirectory($toolDir)|Out-Null
    # 真正的应用文件位于显式目录；不用函数/别名冒充可继承的子进程依赖。
    $node=Get-Command node -CommandType Application|Select-Object -First 1
    $tool=Join-Path $toolDir ([IO.Path]::GetFileName($node.Source))
    Copy-Item -LiteralPath $node.Source -Destination $tool
    Push-Location $root
    try{$resolved=Get-AiSopTestEnvironment -ToolDirectory 'tools here' -ReportDirectory $root -ReadVersions}
    finally{Pop-Location}
    $observed=@($resolved.tools|Where-Object name -eq node)[0]
    Assert ($observed.path -eq $tool -and $observed.versionStatus -eq 'OBSERVED' -and $observed.version -match '^v\d+') 'Explicit executable/version not captured'
    Assert ($env:PATH -ceq $originalPath) 'Parent PATH mutated'
    # 空搜索路径的缺失仍可观察，不把解析结果当成执行成功。
    try{$env:PATH=$toolDir;$missing=Get-AiSopTestEnvironment -ReportDirectory $root}
    finally{$env:PATH=$originalPath}
    Assert (@($missing.tools|Where-Object { $_.name -eq 'svn' -and $_.status -eq 'MISSING' }).Count -eq 1) 'Missing tool hidden'
    $fakeScripts=Join-Path $root scripts;$tests=Join-Path $fakeScripts tests
    [IO.Directory]::CreateDirectory($tests)|Out-Null
    foreach($name in @('run-all-tests.ps1','hidden-process.ps1','test-execution-environment.ps1')){Copy-Item (Join-Path $scripts $name) $fakeScripts}
    $native=Join-Path $tests native-harness-adapters.tests.ps1
    $peer=Join-Path $tests zzz-peer.tests.ps1
    $body=@'
Write-Output ("START_AT="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
Write-Output ("WORKERS="+$env:AI_SOP_TEST_WORKERS)
Write-Output ("NODE="+(Get-Command node -CommandType Application|Select-Object -First 1).Source)
Start-Sleep -Milliseconds 250
Write-Output ("END_AT="+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
'@
    [IO.File]::WriteAllText($native,$body+';exit 19')
    [IO.File]::WriteAllText($peer,$body)
    foreach($capacity in @(1,2)){
        $out=Join-Path $root "runner-$capacity.out";$err=Join-Path $root "runner-$capacity.err"
        $child=Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-File',(Join-Path $fakeScripts run-all-tests.ps1),'-TestsRoot',$tests,'-Parallel','-MaxParallel',[string]$capacity,'-ToolDirectory',$toolDir,'-SuiteTimeoutSeconds','10') -RedirectStandardOutput $out -RedirectStandardError $err -TimeoutSeconds 30 -PassThru
        try{$child.WaitForExit();Assert ($child.ExitCode -eq 1) 'Native failure became runner success'}finally{$child.Dispose()}
        $text=[IO.File]::ReadAllText($out)
        Assert ($text -match 'results: ([^\r\n]+results.json)') 'Runner report missing'
        $report=$Matches[1]
        $records=@(Get-Content $report -Raw|ConvertFrom-Json)
        Assert ($records.Count -eq 2 -and $records[0].ExitCode -eq 19 -and $records[1].Passed) 'Failure hid later suite or exit code'
        Assert ($records[0].Workers -eq $capacity -and $records[1].Workers -eq 1 -and @($records|Where-Object TimeoutSeconds -ne 10).Count -eq 0) 'Reservation or timeout changed'
        $first=[IO.File]::ReadAllText($records[0].OutFile);$second=[IO.File]::ReadAllText($records[1].OutFile)
        Assert ($first.Contains("NODE=$tool") -and $second.Contains("NODE=$tool")) 'Child did not inherit resolved executable'
        Assert ($first -match 'END_AT=(\d+)') 'Native end missing';$end=[long]$Matches[1]
        Assert ($second -match 'START_AT=(\d+)') 'Peer start missing'
        Assert ([long]$Matches[1] -ge $end) 'Nested workers exceeded shared capacity'
        $inventory=Get-Content (Join-Path (Split-Path $report) environment.json) -Raw|ConvertFrom-Json
        Assert (@($inventory.tools|Where-Object { $_.name -eq 'node' -and $_.path -eq $tool }).Count -eq 1) 'Environment report lost chosen tool'
    }
    # 默认入口真实探测：父工具退出，后代占用输出，运行器不能把测试通过当成整体成功。
    $versionScripts=Join-Path $root 'version/scripts';$versionTests=Join-Path $versionScripts tests
    $versionTools=Join-Path $root 'version/tools'
    [IO.Directory]::CreateDirectory($versionTests)|Out-Null;[IO.Directory]::CreateDirectory($versionTools)|Out-Null
    foreach($name in @('run-all-tests.ps1','hidden-process.ps1','test-execution-environment.ps1')){Copy-Item (Join-Path $scripts $name) $versionScripts}
    [IO.File]::WriteAllText((Join-Path $versionTests 'probe-consumer.tests.ps1'),'if(7*6 -ne 42){throw "fixture failed"};Write-Output "fixture suite executed"')
    if([OperatingSystem]::IsWindows()){
        $compiler=Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
        if(-not [IO.File]::Exists($compiler)){throw 'FIXTURE_COMPILER_MISSING: .NET Framework csc'}
        & $compiler /nologo /target:exe ("/out:"+(Join-Path $versionTools svn.exe)) (Join-Path $PSScriptRoot fixtures/version-probe.cs)
        if($LASTEXITCODE -ne 0){throw 'FIXTURE_COMPILE_FAILED'}
    }else{
        Copy-Item (Join-Path $PSScriptRoot fixtures/version-probe.ps1) (Join-Path $versionTools svn.ps1)
        [IO.File]::WriteAllText((Join-Path $versionTools svn),"#!/bin/sh`nexec pwsh -NoProfile -File `"`$0.ps1`" `"`$@`"`n")
        & chmod +x (Join-Path $versionTools svn)
        if($LASTEXITCODE -ne 0){throw 'FIXTURE_EXECUTABLE_FAILED'}
    }
    foreach($mode in @('normal','empty','nonzero','orphan')){
        [IO.File]::WriteAllText((Join-Path $versionTools mode.txt),$mode)
        $identity=$null;$versionRunner=$null
        try{
            $out=Join-Path $root "version-$mode.out";$err=Join-Path $root "version-$mode.err"
            $arguments=@('-NoProfile','-File',(Join-Path $versionScripts run-all-tests.ps1),'-ToolDirectory',$versionTools)
            if($mode -eq 'orphan'){$arguments+='-Quiet'}
            $versionRunner=Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList $arguments -RedirectStandardOutput $out -RedirectStandardError $err -TimeoutSeconds 40 -PassThru
            $versionRunner.WaitForExit();$versionRunner.Dispose()
            if($mode -ne 'orphan'){Assert (-not $versionRunner.Diagnostic) 'Fixture runner itself did not exit cleanly'}
            elseif($versionRunner.Diagnostic){Assert ($versionRunner.Diagnostic -match 'OUTPUT_DRAIN_TIMED_OUT' -and $versionRunner.ExitKnown) 'Unexpected outer runner failure'}
            $text=[IO.File]::ReadAllText($out)+[IO.File]::ReadAllText($err)
            Assert ($text -match 'results: ([^\r\n]+results.json)') 'Version runner did not expose its exact report'
            $reportRoot=Split-Path $Matches[1]
            $inventory=Get-Content (Join-Path $reportRoot environment.json) -Raw|ConvertFrom-Json
            $summary=Get-Content (Join-Path $reportRoot summary.json) -Raw|ConvertFrom-Json
            $results=@(Get-Content (Join-Path $reportRoot results.json) -Raw|ConvertFrom-Json)
            $probe=($inventory.tools|Where-Object name -eq svn).probe
            $svn=$inventory.tools|Where-Object name -eq svn
            Assert ($results.Count -eq 1 -and $results[0].Passed -and $summary.passed -eq 1 -and $summary.failed -eq 0) 'Preparation changed actual test outcomes or skipped suite'
            Assert ($probe.pid -gt 0 -and $probe.startedAt -and $probe.executable -eq $svn.path) 'Probe identity was not retained'
            Assert ([IO.File]::Exists($probe.recordFile)) 'Final probe record missing'
            if($mode -eq 'orphan'){
                $identity=Get-Content (Join-Path $versionTools identity.json) -Raw|ConvertFrom-Json
                $live=Get-Process -Id $identity.pid
                try{Assert (-not $live.HasExited -and $live.StartTime.ToUniversalTime().Ticks -eq $identity.startedTicks) 'Orphan fixture did not retain a live descendant'}finally{$live.Dispose()}
                Assert ($versionRunner.RawExitCode -eq 1 -and $summary.outcome -eq 'FAILED' -and $summary.environmentCleanupUnconfirmed -eq 1) 'Unknown cleanup became overall success'
                Assert ($text -match 'ENVIRONMENT_CLEANUP_UNCONFIRMED' -and $probe.cleanupStatus -eq 'UNCONFIRMED' -and $probe.diagnostic -match 'OUTPUT_DRAIN_TIMED_OUT') 'Quiet mode or inventory hid cleanup uncertainty'
                Assert ($probe.exitCode -eq 125 -and $probe.rawExitCode -eq 0 -and $probe.failureRecorded) 'Effective failure collapsed to raw exit zero'
                $nativeFailure=Get-Content $probe.failureFile -Raw|ConvertFrom-Json
                Assert ($nativeFailure.pid -eq $probe.pid -and $nativeFailure.diagnostic -match 'OUTPUT_DRAIN_TIMED_OUT') 'Original native failure record lost'
            }else{
                Assert ($versionRunner.ExitCode -eq 0 -and $summary.outcome -eq 'PASSED' -and $summary.environmentCleanupUnconfirmed -eq 0 -and $probe.cleanupStatus -eq 'CONFIRMED') 'Ordinary version unavailability became a new blocking condition'
                if($mode -eq 'normal'){Assert ($svn.version -eq 'fixture-1.0' -and $svn.versionStatus -eq 'OBSERVED') 'Normal version not observed'}
                else{Assert ($svn.versionStatus -eq 'UNAVAILABLE' -and $probe.error) 'Ordinary unavailable version lacks reason'}
                if($mode -eq 'nonzero'){Assert ($probe.exitCode -eq 23) 'Version native exit code lost'}
            }
            Write-Output "VERSION_CASE mode=$mode rawRunnerExit=$($versionRunner.RawExitCode) probeCleanup=$($probe.cleanupStatus) outerDiagnostic=$($versionRunner.Diagnostic)"
        }finally{
            if($versionRunner){$versionRunner.Dispose()}
            $identityPath=Join-Path $versionTools identity.json
            if(-not $identity -and [IO.File]::Exists($identityPath)){$identity=Get-Content $identityPath -Raw|ConvertFrom-Json}
            if($identity){
                $owned=Get-Process -Id $identity.pid -ErrorAction SilentlyContinue
                if($owned){try{if($owned.StartTime.ToUniversalTime().Ticks -ne $identity.startedTicks){throw 'FIXTURE_PROCESS_IDENTITY_CHANGED'};$owned.Kill($true);Assert ($owned.WaitForExit(5000)) 'Fixture orphan cleanup failed'}finally{$owned.Dispose()}}
            }
            if($versionRunner -and $versionRunner.Cleanup.pending){Assert ($versionRunner.Cleanup.pending.Wait(5000)) 'Outer fixture cleanup still pending after independent recovery'}
        }
    }
    Write-Output 'PASS: real version success/empty/nonzero and inherited-pipe descendant, overall failure, retained identity/diagnosis and independent cleanup'
    # 真实启动失败：路径已解析但启动前丢失，不应把已确认清理误计为未知。
    $originalStart=(Get-Item Function:\Start-AiSopHiddenProcess).ScriptBlock
    try{
        function Start-AiSopHiddenProcess {
            param($FilePath,$ArgumentList,$Environment,$TimeoutSeconds,$RedirectStandardOutput,$RedirectStandardError,$FailurePath,[switch]$CloseStandardInput,[switch]$PassThru)
            & $originalStart -FilePath (Join-Path $root 'missing-executable') -RedirectStandardOutput $RedirectStandardOutput -RedirectStandardError $RedirectStandardError -FailurePath $FailurePath -PassThru
        }
        $startDir=Join-Path $root 'start-missing';[IO.Directory]::CreateDirectory($startDir)|Out-Null
        $missingStart=Get-AiSopTestEnvironment -ReportDirectory $startDir -ReadVersions
        $tested=@($missingStart.tools|Where-Object probe)
        Assert ($tested.Count -gt 0 -and $missingStart.cleanupUnconfirmed -eq 0) 'Confirmed failed launch became cleanup unknown'
        foreach($record in $tested){
            Assert ($record.versionStatus -eq 'UNAVAILABLE' -and $record.probe.identityStatus -eq 'NOT_STARTED' -and $record.probe.cleanupStatus -eq 'CONFIRMED' -and $record.probe.failureRecorded) 'Real launch failure facts not retained'
            Assert ($record.probe.error -match 'missing-executable' -and $record.probe.diagnostic -match 'PROCESS_START_FAILED') 'Original launch error lost'
        }
        # 原函数组合故障：启动失败、清理失败/抛错、WarningAction Stop不能替换原错。
        $originalCleanup=(Get-Item Function:\Invoke-AiSopProcessCleanup).ScriptBlock
        try{
            function Invoke-AiSopProcessCleanup {
                param($Process,$Started,$Cancellation,$Copies,$Resources,$BudgetMilliseconds)
                $real=& $originalCleanup -Process $Process -Started $Started -Cancellation $Cancellation -Copies $Copies -Resources $Resources -BudgetMilliseconds $BudgetMilliseconds
                if(-not $real.confirmed){throw 'Fixture resource cleanup failed'}
                if($script:cleanupProbeFault -eq 'throws'){throw 'injected cleanup exception'}
                $real.confirmed=$false;$real.diagnostic='PROCESS_CLEANUP_FAILED: injected cleanup diagnosis'
                return $real
            }
            foreach($script:cleanupProbeFault in @('diagnostic','throws')){
                $caught=$null;$failure=Join-Path $root ('start-cleanup-'+$script:cleanupProbeFault+'.json')
                try{& $originalStart -FilePath (Join-Path $root 'missing-executable') -RedirectStandardOutput (Join-Path $root 'start-cleanup.out') -FailurePath $failure -WarningAction Stop -PassThru|Out-Null}
                catch{$caught=$_}
                Assert ($caught -and $caught.Exception.Message -match 'missing-executable') 'Cleanup warning replaced original launch error'
                $facts=$caught.Exception.Data['AiSop.ProcessStartObservation']
                Assert ($facts -and -not $facts.started -and -not $facts.cleanupConfirmed -and $facts.cleanupDiagnostic -match 'injected cleanup') 'Compound launch failure lost cleanup facts'
                $saved=Get-Content $failure -Raw|ConvertFrom-Json
                Assert ($saved.diagnostic -match 'PROCESS_START_FAILED' -and $saved.diagnostic -match 'injected cleanup') 'Compound launch failure not persisted'
            }
        }finally{Set-Item Function:\Invoke-AiSopProcessCleanup -Value $originalCleanup}
        # 精确异常载荷补充启动后未返回句柄的分支；缺少事实也不能假定安全。
        function Start-AiSopHiddenProcess {
            param($FilePath,$ArgumentList,$Environment,$TimeoutSeconds,$RedirectStandardOutput,$RedirectStandardError,$FailurePath,[switch]$CloseStandardInput,[switch]$PassThru)
            $error=[InvalidOperationException]::new('injected launch setup failure')
            if($script:launchFault -ne 'absent'){
                $error.Data['AiSop.ProcessStartObservation']=@{started=$true;pid=123;startedAt='2026-01-01T00:00:00Z';cleanupConfirmed=($script:launchFault -eq 'confirmed');diagnostic='PROCESS_START_FAILED: injected';cleanupDiagnostic='fixture cleanup observation';rawExitCode=$null}
            }
            throw $error
        }
        foreach($script:launchFault in @('confirmed','unknown','absent')){
            $dir=Join-Path $root ('start-'+$script:launchFault);[IO.Directory]::CreateDirectory($dir)|Out-Null
            $observedStart=Get-AiSopTestEnvironment -ReportDirectory $dir -ReadVersions
            $tested=@($observedStart.tools|Where-Object probe)
            $unknown=if($script:launchFault -eq 'confirmed'){0}else{$tested.Count}
            Assert ($tested.Count -gt 0 -and $observedStart.cleanupUnconfirmed -eq $unknown) 'Start failure cleanup observation collapsed'
            foreach($record in $tested){
                Assert ($record.versionStatus -eq 'UNAVAILABLE' -and $record.probe.error -match 'injected launch setup failure') 'Failed start became version success'
                if($script:launchFault -ne 'absent'){Assert ($record.probe.pid -eq 123 -and $record.probe.startedAt -and $record.probe.diagnostic -match 'PROCESS_START_FAILED') 'Failed start lost captured identity'}
            }
        }
    }finally{Set-Item Function:\Start-AiSopHiddenProcess -Value $originalStart}
    Write-Output 'PASS: real failed launch confirmed clean; post-start confirmed/unknown and absent facts remain distinct'
    # 精确替身补充Dispose后才发生的失败；不能在Dispose前读取成功状态。
    $originalStart=(Get-Item Function:\Start-AiSopHiddenProcess).ScriptBlock
    try{
        function Start-AiSopHiddenProcess {
            param($FilePath,$ArgumentList,$Environment,$TimeoutSeconds,$RedirectStandardOutput,$RedirectStandardError,$FailurePath,[switch]$CloseStandardInput,[switch]$PassThru)
            [IO.File]::WriteAllText($RedirectStandardOutput,'fixture-1.0')
            [IO.File]::WriteAllText($RedirectStandardError,'')
            $fake=[pscustomobject]@{Id=123;Inner=@{StartTime=[DateTime]::UtcNow};ExitCode=0;RawExitCode=0;Completed=$true;Disposed=$false;Diagnostic='';Cleanup=@{confirmed=$true;diagnostic=''}}
            Add-Member -InputObject $fake -MemberType ScriptMethod -Name WaitForExit -Value {}
            Add-Member -InputObject $fake -MemberType ScriptMethod -Name Dispose -Value {
                if($script:versionProbeFault -eq 'throws'){throw 'injected disposal failure'}
                $this.Disposed=$true;$this.ExitCode=125;$this.Diagnostic='PROCESS_CLEANUP_TIMED_OUT: injected late failure'
                $this.Cleanup=@{confirmed=$false;diagnostic='injected late cleanup'}
            }
            return $fake
        }
        foreach($script:versionProbeFault in @('late','throws')){
            $lateDir=Join-Path $root ('dispose-'+$script:versionProbeFault);[IO.Directory]::CreateDirectory($lateDir)|Out-Null
            $late=Get-AiSopTestEnvironment -ReportDirectory $lateDir -ReadVersions
            $tested=@($late.tools|Where-Object probe)
            Assert ($tested.Count -gt 0 -and $late.cleanupUnconfirmed -eq $tested.Count) 'Late cleanup failure not aggregated'
            foreach($record in $tested){
                Assert ($record.versionStatus -eq 'UNAVAILABLE' -and -not $record.version -and $record.probe.cleanupStatus -eq 'UNCONFIRMED') 'Pre-disposal success escaped final probe state'
                $saved=Get-Content $record.probe.recordFile -Raw|ConvertFrom-Json
                Assert ($saved.probe.cleanupStatus -eq 'UNCONFIRMED' -and $saved.probe.pid -eq 123) 'Late failure snapshot lost identity'
                if($script:versionProbeFault -eq 'throws'){Assert ($saved.probe.cleanupDiagnostic -match 'injected disposal failure') 'Dispose exception replaced or lost'}
                else{Assert ($saved.probe.exitCode -eq 125 -and $saved.probe.diagnostic -match 'PROCESS_CLEANUP_TIMED_OUT') 'Post-disposal effective result lost'}
            }
        }
    }finally{Set-Item Function:\Start-AiSopHiddenProcess -Value $originalStart}
    Write-Output 'PASS: post-disposal failure and cleanup exception remain unavailable and unconfirmed'
    Assert ($env:PATH -ceq $originalPath) 'Runner changed caller PATH'
    $passed=$true
    Write-Output 'PASS: explicit relative tools, observed versions, missing dependencies, child PATH and shared worker reservation'
}finally{
    if($passed){[IO.Directory]::Delete($root,$true)}else{Write-Output "RETAINED_FIXTURE: $root"}
}
