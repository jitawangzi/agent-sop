#requires -Version 7.0
$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot fixtures/retained-fixture.ps1)
function Assert($ok,$message){if(-not $ok){throw $message}}
function New-Fixture { $p=Join-Path ([IO.Path]::GetTempPath()) ('retained-fixture-'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($p)|Out-Null;[IO.File]::WriteAllText((Join-Path $p state.json),'original');return $p }
$root=New-Fixture
Complete-AiSopTestFixture -Root $root -Prefix retained-fixture- -Succeeded $true
Assert (-not [IO.Directory]::Exists($root)) 'Successful fixture was not cleaned'
$root=New-Fixture;$script:secondCleanup=$false
Complete-AiSopTestFixture -Root $root -Prefix retained-fixture- -Succeeded $false -Failure primary-failure -Cleanup @({throw 'cleanup-failure'},{ $script:secondCleanup=$true })
$r=Get-Content (Join-Path $root failure.json) -Raw|ConvertFrom-Json
Assert ($script:secondCleanup -and $r.failure -eq 'primary-failure' -and -not $r.cleanupConfirmed) 'Cleanup hid primary failure or skipped remaining cleanup'
Assert ((Get-Content (Join-Path $root state.json) -Raw) -eq 'original') 'Failure state deleted'
$root=New-Fixture;$failed=$false
try{Complete-AiSopTestFixture -Root $root -Prefix retained-fixture- -Succeeded $true -Cleanup @({throw 'cleanup-failure'})}catch{$failed=$_.Exception.Message -eq 'TEST_FIXTURE_CLEANUP_FAILED'}
Assert ($failed -and [IO.File]::Exists((Join-Path $root failure.json))) 'Cleanup failure falsely passed'
$root=New-Fixture
Complete-AiSopTestFixture -Root $root -Prefix retained-fixture- -Succeeded $false -Failure main -Capture {throw 'capture-failure'}
$r=Get-Content (Join-Path $root failure.json) -Raw|ConvertFrom-Json
Assert ($r.failure -eq 'main' -and $r.diagnostics[0] -like 'CAPTURE_FAILED:*') 'Capture failure hid primary error'
$unsafe=Join-Path ([IO.Path]::GetPathRoot([IO.Path]::GetTempPath())) ('outside-fixture-'+[guid]::NewGuid().ToString('N'))
$primary='';try{try{throw 'original-primary'}finally{Complete-AiSopTestFixture -Root $unsafe -Prefix retained-fixture- -Succeeded $false -Failure original-primary}}catch{$primary=$_.Exception.Message}
Assert ($primary -eq 'original-primary' -and -not (Test-Path -LiteralPath $unsafe)) 'Unsafe report path hid primary error or wrote outside fixture'
Write-Output 'PASS: failure preservation, independent cleanup, failed compensation, capture failure and success deletion'

# Exercise the real safety suite's catch/finally with its child already running.
# Inject only into an isolated copy; production tests have no failure bypass.
$copy=New-Fixture
$engine=Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
foreach($dir in @('scripts','schemas')){Copy-Item -LiteralPath (Join-Path $engine $dir) -Destination $copy -Recurse}
$testPath=Join-Path $copy 'scripts/tests/workflow-evidence-safety.tests.ps1'
$source=[IO.File]::ReadAllText($testPath)
foreach($failureMode in @('active','wrapper-exited')){
$needle='$boundOwner=Owner'
Assert ($source.Split($needle).Count -eq 2) 'Failure injection anchor changed'
$injection=@'
[IO.File]::WriteAllText((Join-Path $root 'injected-child-pid.txt'),[string](Read-AiSopTask $spec $scenario).verifications[-1].context.childPid)
        throw 'INJECTED_AFTER_CHILD_READY'
        $boundOwner=Owner
'@
if($failureMode -eq 'wrapper-exited'){
    $injection=$injection.Replace("throw 'INJECTED_AFTER_CHILD_READY'",'$runner.Inner.Kill(); if(-not $runner.Inner.WaitForExit(5000)){throw ''WRAPPER_DID_NOT_EXIT''}; throw ''INJECTED_AFTER_CHILD_READY''')
}
[IO.File]::WriteAllText($testPath,$source.Replace($needle,$injection))
. (Join-Path $engine 'scripts/hidden-process.ps1')
$out=Join-Path $copy "$failureMode.stdout.log";$err=Join-Path $copy "$failureMode.stderr.log"
$process=Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-File',$testPath) -RedirectStandardOutput $out -RedirectStandardError $err -TimeoutSeconds 120 -PassThru
try{
    $process.WaitForExit()
    Assert ($process.ExitCode -ne 0 -and $process.Cleanup.confirmed) 'Injected failure passed or outer cleanup unconfirmed'
    $output=[IO.File]::ReadAllText($out)
    Assert ($output -match 'RETAINED_FIXTURE:([^\r\n]+)') 'Real failed suite did not report its retained fixture'
    $retained=$Matches[1].Trim()
    $report=Get-Content -LiteralPath (Join-Path $retained failure.json) -Raw|ConvertFrom-Json
    Assert (-not $report.succeeded -and $report.failure -match 'INJECTED_AFTER_CHILD_READY' -and $report.cleanupConfirmed) 'Real suite lost original error or failed cleanup'
    foreach($file in @('lease.runner.stdout.log','lease.runner.stderr.log','runner-exit.txt')){
        Assert ([IO.File]::Exists((Join-Path $retained $file))) "Real failure lost $file"
    }
    $childId=[int][IO.File]::ReadAllText((Join-Path $retained injected-child-pid.txt))
    Assert (-not (Get-Process -Id $childId -ErrorAction SilentlyContinue)) 'Owned child survived failure cleanup'
    Write-Output "INJECTED_$($failureMode.ToUpperInvariant())_FIXTURE:$retained"
    Write-Output "INJECTION_CONTROLLER_FIXTURE:$copy"
    Write-Output 'PASS: real child-ready failure retained state and streamed output, terminated owned child and preserved primary error'
}finally{$process.Dispose()}
}

# Nonzero business exits must not hide completed runner cleanup/capture failure.
foreach($mode in @('cleanup','drain','pending')){
    $scenarioList="@('lease','contention','expired','revoked','retry','ended')"
    Assert ($source.Split($scenarioList).Count -eq 2) 'Scenario injection anchor changed'
    $completedNeedle='$exit=$runner.ExitCode; $runner.Dispose()'
    Assert ($source.Split($completedNeedle).Count -eq 2) 'Completed runner injection anchor changed'
    $fault=if($mode -eq 'cleanup'){'$runner.Cleanup.confirmed=$false; $runner.FailureCode=125; $runner.Diagnostic=''INJECTED_CLEANUP_UNKNOWN''; '}
        elseif($mode -eq 'pending'){'$runner.Cleanup.confirmed=$false; $runner.Cleanup.pending=[Threading.Tasks.TaskCompletionSource[object]]::new().Task; $runner.FailureCode=125; $runner.Diagnostic=''PROCESS_CLEANUP_TIMED_OUT: injected unfinished task''; '}
        else{'$runner.FailureCode=125; $runner.Diagnostic=''OUTPUT_DRAIN_TIMED_OUT: injected unknown descendant cleanup''; '}
    [IO.File]::WriteAllText($testPath,$source.Replace($scenarioList,"@('retry')").Replace($completedNeedle,$fault+$completedNeedle))
    $out=Join-Path $copy "$mode.stdout.log";$err=Join-Path $copy "$mode.stderr.log"
    $process=Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-File',$testPath) -RedirectStandardOutput $out -RedirectStandardError $err -TimeoutSeconds 120 -PassThru
    try{
        $process.WaitForExit()
        Assert ($process.ExitCode -ne 0 -and $process.Cleanup.confirmed) 'Completed runner fault falsely passed'
        $output=[IO.File]::ReadAllText($out)
        Assert ($output -match 'RETAINED_FIXTURE:([^\r\n]+)') 'Completed runner fault lost fixture'
        $retained=$Matches[1].Trim()
        $report=Get-Content -LiteralPath (Join-Path $retained failure.json) -Raw|ConvertFrom-Json
        $runnerReport=Get-Content -LiteralPath (Join-Path $retained retry.runner-result.json) -Raw|ConvertFrom-Json
        Assert (-not $report.cleanupConfirmed -and $report.failure -match 'RUNNER_CAPTURE_OR_CLEANUP_UNCONFIRMED' -and $runnerReport.failureCode -eq 125) 'Completed runner fault was erased or cleanup falsely confirmed'
        if($mode -eq 'pending'){Assert ($runnerReport.cleanup.pendingIncomplete -and $process.RawExitCode -ne $null -and $process.FailureCode -eq 0) 'Pending cleanup serialization blocked until outer timeout'}
        Write-Output "COMPLETED_$($mode.ToUpperInvariant())_FIXTURE:$retained"
    }finally{$process.Dispose()}
}
Write-Output 'PASS: expected nonzero business result cannot hide completed runner cleanup failure or output-drain uncertainty'

foreach($mode in @('identity-mismatch','survivor')){
    $foreign=Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-Command','Start-Sleep -Seconds 120') -RedirectStandardOutput (Join-Path $copy "$mode.foreign.stdout") -RedirectStandardError (Join-Path $copy "$mode.foreign.stderr") -TimeoutSeconds 120 -PassThru
    $process=$null;$scenarioSucceeded=$false
    try{
        $modified=$source.Replace($scenarioList,"@('retry')")
        if($mode -eq 'identity-mismatch'){
            $identityNeedle='$managedChildId=[int]$childContext.childPid'
            Assert ($source.Split($identityNeedle).Count -eq 2) 'Identity injection anchor changed'
            $modified=$modified.Replace($identityNeedle,('$childContext.childPid='+$foreign.Id+'; '+$identityNeedle))
        }else{
            $fault='$managedChild.Dispose(); $managedChild=[Diagnostics.Process]::GetProcessById('+$foreign.Id+'); [void]$managedChild.Handle; $managedChildId='+$foreign.Id+'; '
            $modified=$modified.Replace($completedNeedle,$fault+$completedNeedle)
        }
        [IO.File]::WriteAllText($testPath,$modified)
        $out=Join-Path $copy "$mode.stdout.log";$err=Join-Path $copy "$mode.stderr.log"
        $process=Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-File',$testPath) -RedirectStandardOutput $out -RedirectStandardError $err -TimeoutSeconds 120 -PassThru
        $process.WaitForExit()
        Assert ($process.ExitCode -ne 0 -and $process.FailureCode -eq 0) 'Identity/survivor regression passed or timed out'
        $output=[IO.File]::ReadAllText($out)
        Assert ($output -match 'RETAINED_FIXTURE:([^\r\n]+)') 'Identity/survivor failure lost fixture'
        $retained=$Matches[1].Trim()
        $report=Get-Content -LiteralPath (Join-Path $retained failure.json) -Raw|ConvertFrom-Json
        if($mode -eq 'identity-mismatch'){
            Assert ($report.failure -match 'CHILD_IDENTITY_UNAVAILABLE' -and -not $foreign.HasExited) 'Mismatched identity was accepted or unrelated process terminated'
        }else{
            Assert ($report.failure -match 'Child survived completed runner before test cleanup' -and $foreign.HasExited -and $report.cleanupConfirmed) 'Compensation hid live-child failure or did not clean it afterwards'
        }
        Write-Output "INJECTED_$($mode.ToUpperInvariant())_FIXTURE:$retained"
        $scenarioSucceeded=$true
    }finally{
        $cleanupErrors=[Collections.Generic.List[string]]::new()
        foreach($owned in @($process,$foreign)){
            if(-not $owned){continue}
            try{
                $owned.Dispose()
                if(-not $owned.Cleanup.confirmed -or -not $owned.Cleanup.exited){$cleanupErrors.Add('CONTROLLER_CLEANUP_UNCONFIRMED: '+$owned.Diagnostic)}
            }catch{$cleanupErrors.Add($_.ToString())}
        }
        try{@{confirmed=($cleanupErrors.Count -eq 0);diagnostics=@($cleanupErrors.ToArray())}|ConvertTo-Json|Set-Content -LiteralPath (Join-Path $copy "$mode.controller-cleanup.json")}
        catch{$cleanupErrors.Add('CONTROLLER_REPORT_UNAVAILABLE: '+$_.ToString())}
        if($cleanupErrors.Count){
            Write-Warning ($cleanupErrors -join '; ')
            if($scenarioSucceeded){throw 'CONTROLLER_CLEANUP_UNCONFIRMED'}
        }
    }
}
Write-Output 'PASS: mismatched child identity stays untouched; live child fails before compensation then is cleaned'
