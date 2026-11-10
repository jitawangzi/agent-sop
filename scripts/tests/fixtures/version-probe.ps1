$ErrorActionPreference='Stop'
if($args -contains 'child'){Start-Sleep 60;exit 0}
$mode=[IO.File]::ReadAllText((Join-Path $PSScriptRoot mode.txt)).Trim()
if($mode -eq 'nonzero'){[Console]::Error.WriteLine('fixture-version-failure');exit 23}
if($mode -eq 'empty'){exit 0}
if($mode -eq 'orphan'){
    $info=[Diagnostics.ProcessStartInfo]::new((Get-Process -Id $PID).Path)
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    foreach($arg in @('-NoProfile','-File',$PSCommandPath,'child')){[void]$info.ArgumentList.Add($arg)}
    $child=[Diagnostics.Process]::Start($info)
    @{pid=$child.Id;startedTicks=$child.StartTime.ToUniversalTime().Ticks}|ConvertTo-Json|Set-Content (Join-Path $PSScriptRoot identity.json)
}
[Console]::WriteLine('fixture-1.0')
exit 0
