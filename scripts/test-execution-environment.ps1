# 测试进程专用环境；只记录已知工具，不导出调用者的其他环境变量。
function Get-AiSopTestEnvironment {
    param([string[]]$ToolDirectory=@(),[string]$ReportDirectory,[switch]$ReadVersions)
    $directories=@(foreach($entry in $ToolDirectory){
        $path=$ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($entry)
        if(-not [IO.Directory]::Exists($path)){throw "TEST_TOOL_DIRECTORY_MISSING:$entry"}
        $path
    })
    # pwsh 固定为当前运行器，避免 PATH 中的另一个版本改变子进程解释器。
    $pwsh=(Get-Process -Id $PID).Path
    $searchPath=(@((Split-Path $pwsh))+$directories+@($env:PATH)) -join [IO.Path]::PathSeparator
    $previous=$env:PATH
    $records=[Collections.Generic.List[object]]::new()
    try {
        $env:PATH=$searchPath
        foreach($name in @('pwsh','git','node','rg','svn','svnadmin')){
            $command=Get-Command $name -CommandType Application -ErrorAction SilentlyContinue|Select-Object -First 1
            $record=@{name=$name;path=$null;status='MISSING';version=$null;versionStatus='NOT_OBSERVED'}
            if($command){
                $record.path=$command.Source;$record.status='RESOLVED'
                if($ReadVersions){
                    $out=Join-Path $ReportDirectory ($name+'.version.stdout.log')
                    $err=Join-Path $ReportDirectory ($name+'.version.stderr.log')
                    $arguments=if($name -in @('svn','svnadmin')){@('--version','--quiet')}else{@('--version')}
                    $failure=Join-Path $ReportDirectory ($name+'.version.failure.json')
                    $probeFile=Join-Path $ReportDirectory ($name+'.version.probe.json')
                    $process=$null;$candidate=$null;$disposeError=''
                    $probe=@{pid=$null;startedAt=$null;identityStatus='UNAVAILABLE';executable=$command.Source;
                        exitCode=$null;rawExitCode=$null;diagnostic='';error='';cleanupStatus='UNCONFIRMED';
                        cleanupDiagnostic='';stdout=$out;stderr=$err;failureFile=$failure;recordFile=$probeFile}
                    try{
                        $process=Start-AiSopHiddenProcess -FilePath $command.Source -ArgumentList $arguments -Environment @{PATH=$searchPath} -TimeoutSeconds 10 -RedirectStandardOutput $out -RedirectStandardError $err -FailurePath $failure -CloseStandardInput -PassThru
                        $probe.pid=$process.Id;$probe.identityStatus='PID_ONLY'
                        try{$probe.startedAt=$process.Inner.StartTime.ToUniversalTime().ToString('o');$probe.identityStatus='PID_AND_START_TIME'}catch{}
                        $process.WaitForExit()
                        if($process.ExitCode -ne 0 -or $process.Diagnostic){throw 'VERSION_PROBE_FAILED'}
                        $candidate=[IO.File]::ReadAllText($out).Trim()
                        if(-not $candidate){throw 'VERSION_EMPTY'}
                    }catch{
                        $probe.error=$_.Exception.Message
                        $failureException=$_.Exception;$startObservation=$null
                        while($failureException){
                            if($failureException.Data.Contains('AiSop.ProcessStartObservation')){$startObservation=$failureException.Data['AiSop.ProcessStartObservation'];break}
                            $failureException=$failureException.InnerException
                        }
                        if(-not $process -and $startObservation){
                            $probe.pid=$startObservation.pid;$probe.startedAt=$startObservation.startedAt
                            $probe.identityStatus=if($probe.startedAt){'PID_AND_START_TIME'}elseif($probe.pid){'PID_ONLY'}elseif(-not $startObservation.started){'NOT_STARTED'}else{'UNAVAILABLE'}
                            $probe.exitCode=125;$probe.rawExitCode=$startObservation.rawExitCode
                            $probe.diagnostic=$startObservation.diagnostic;$probe.cleanupDiagnostic=$startObservation.cleanupDiagnostic
                            if($startObservation.cleanupConfirmed -eq $true){$probe.cleanupStatus='CONFIRMED'}
                        }
                    }
                    finally{
                        if($process){try{$process.Dispose()}catch{$disposeError=$_.Exception.Message}}
                    }
                    # 只在最终收尾后采集结果；父进程退出不等于持管道的后代已经退出。
                    if($process){
                        try{$probe.exitCode=$process.ExitCode}catch{$probe.error=(@($probe.error,('RESULT_UNAVAILABLE: '+$_.Exception.Message))|Where-Object {$_}) -join '; '}
                        $probe.rawExitCode=$process.RawExitCode
                        $probe.diagnostic=$process.Diagnostic;$probe.cleanupDiagnostic=$process.Cleanup.diagnostic
                        if($process.Completed -and $process.Disposed -and $process.Cleanup.confirmed -eq $true -and
                            $process.Diagnostic -notmatch 'OUTPUT_DRAIN_TIMED_OUT|PROCESS_CLEANUP_' -and -not $disposeError){$probe.cleanupStatus='CONFIRMED'}
                    }
                    if($disposeError){$probe.cleanupDiagnostic=(@($probe.cleanupDiagnostic,$disposeError)|Where-Object {$_}) -join '; '}
                    $record.versionStatus='UNAVAILABLE'
                    if($candidate -and -not $probe.error -and $probe.exitCode -eq 0 -and -not $probe.diagnostic -and $probe.cleanupStatus -eq 'CONFIRMED'){
                        $record.version=($candidate -split '\r?\n')[0];$record.versionStatus='OBSERVED'
                    }
                    $probe.failureRecorded=[IO.File]::Exists($failure)
                    $record.probe=$probe
                    # 原生失败记录保留原貌；另存带身份的最终观察，普通非零/空输出也可追溯。
                    [IO.File]::WriteAllText($probeFile,(@{tool=$name;versionStatus=$record.versionStatus;version=$record.version;probe=$probe}|ConvertTo-Json -Depth 8))
                }
            }
            $records.Add($record)
        }
    }finally{$env:PATH=$previous}
    return @{environment=@{PATH=$searchPath;AI_SOP_INVOCATION_SESSION_ID=$null};tools=$records.ToArray();
        cleanupUnconfirmed=@($records|Where-Object {$_.probe -and $_.probe.cleanupStatus -ne 'CONFIRMED'}).Count;
        limits=@('Resolution and version observations only; no installation, downloads or machine environment changes.','Missing tools are not successful tests; dependent suites retain their failures.','Custom test roots do not run version probes.')}
}

function Get-AiSopSuiteWorkers([string]$File,[string]$NativeSuite,[int]$Capacity) {
    $comparison=if([OperatingSystem]::IsWindows()){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    if([IO.Path]::GetFullPath($File).Equals([IO.Path]::GetFullPath($NativeSuite),$comparison)){return [Math]::Min(2,$Capacity)}
    return 1
}
