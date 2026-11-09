function Complete-AiSopTestFixture {
    param([string]$Root,[string]$Prefix,[bool]$Succeeded,[string]$Failure,[scriptblock[]]$Cleanup=@(),[scriptblock]$Capture)
    $errors=[Collections.Generic.List[string]]::new()
    foreach($action in $Cleanup){try{& $action | Out-Null}catch{$errors.Add($_.ToString())}}
    try{if($Capture){& $Capture | Out-Null}}catch{$errors.Add('CAPTURE_FAILED: '+$_.ToString())}
    try{
        $resolved=[IO.Path]::GetFullPath($Root)
        $temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        $comparison=if([OperatingSystem]::IsWindows()){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
        if(-not $resolved.StartsWith($temp,$comparison) -or -not [IO.Path]::GetFileName($resolved).StartsWith($Prefix,[StringComparison]::Ordinal)){throw 'Unsafe test cleanup path'}
    }catch{
        Write-Warning ('FIXTURE_PATH_UNAVAILABLE: '+$_.ToString())
        if($Succeeded){throw 'TEST_FIXTURE_CLEANUP_FAILED'}
        return # Refuse both deletion and report writes; preserve the primary error.
    }
    if($Succeeded -and $errors.Count -eq 0){
        try{Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop;return}
        catch{$errors.Add('FIXTURE_DELETE_FAILED: '+$_.ToString())}
    }
    try{
        [IO.Directory]::CreateDirectory($resolved)|Out-Null
        @{succeeded=$Succeeded;failure=$Failure;cleanupConfirmed=($errors.Count -eq 0);diagnostics=@($errors.ToArray())}|
            ConvertTo-Json -Depth 5|Set-Content -LiteralPath (Join-Path $resolved failure.json)
    }catch{Write-Warning ('FAILURE_REPORT_UNAVAILABLE: '+$_.ToString())}
    Write-Output "RETAINED_FIXTURE:$resolved"
    if($Succeeded){throw 'TEST_FIXTURE_CLEANUP_FAILED'}
}
