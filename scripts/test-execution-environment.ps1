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
                    $process=$null
                    try{
                        $process=Start-AiSopHiddenProcess -FilePath $command.Source -ArgumentList $arguments -Environment @{PATH=$searchPath} -TimeoutSeconds 10 -RedirectStandardOutput $out -RedirectStandardError $err -CloseStandardInput -PassThru
                        $process.WaitForExit()
                        if($process.ExitCode -ne 0){throw 'VERSION_PROBE_FAILED'}
                        $version=[IO.File]::ReadAllText($out).Trim()
                        if(-not $version){throw 'VERSION_EMPTY'}
                        $record.version=($version -split '\r?\n')[0];$record.versionStatus='OBSERVED'
                    }catch{$record.versionStatus='UNAVAILABLE'}finally{if($process){$process.Dispose()}}
                }
            }
            $records.Add($record)
        }
    }finally{$env:PATH=$previous}
    return @{environment=@{PATH=$searchPath;AI_SOP_INVOCATION_SESSION_ID=$null};tools=$records.ToArray();
        limits=@('Resolution and version observations only; no installation, downloads or machine environment changes.','Missing tools are not successful tests; dependent suites retain their failures.','Custom test roots do not run version probes.')}
}

function Get-AiSopSuiteWorkers([string]$File,[string]$NativeSuite,[int]$Capacity) {
    $comparison=if([OperatingSystem]::IsWindows()){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    if([IO.Path]::GetFullPath($File).Equals([IO.Path]::GetFullPath($NativeSuite),$comparison)){return [Math]::Min(2,$Capacity)}
    return 1
}
