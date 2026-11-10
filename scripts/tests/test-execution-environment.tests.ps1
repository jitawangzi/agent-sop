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
    Assert ($env:PATH -ceq $originalPath) 'Runner changed caller PATH'
    $passed=$true
    Write-Output 'PASS: explicit relative tools, observed versions, missing dependencies, child PATH and shared worker reservation'
}finally{
    if($passed){[IO.Directory]::Delete($root,$true)}else{Write-Output "RETAINED_FIXTURE: $root"}
}
