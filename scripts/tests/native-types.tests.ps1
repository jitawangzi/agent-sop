#requires -Version 7.0
param([string]$Probe='', [string]$Fixture='', [string]$NativeScriptsRoot='')
$ErrorActionPreference='Stop'
$scripts=Split-Path $PSScriptRoot
if($Probe){
    if($NativeScriptsRoot){$scripts=$NativeScriptsRoot}
    if([OperatingSystem]::IsWindows() -and $Probe -ne 'cold'){Add-Type -LiteralPath (Join-Path $scripts ('native/'+$Probe+'.cs'))}
    $script:compilations=0
    function Add-Type {
        [CmdletBinding()]
        param([string[]]$LiteralPath)
        $script:compilations++
        Microsoft.PowerShell.Utility\Add-Type @PSBoundParameters
    }
    . (Join-Path $scripts path-identity.ps1)
    . (Join-Path $scripts atomic-file.ps1)
    . (Join-Path $scripts path-identity.ps1)
    if($script:compilations -ne $(if([OperatingSystem]::IsWindows()){1}else{0})){throw 'Native helpers compiled repeatedly'}
    if([OperatingSystem]::IsWindows() -and $Probe -eq 'cold' -and [AiSop.PhysicalPath].Assembly -ne [AiSop.AtomicFile].Assembly){throw 'Cold helpers were not compiled together'}
    $source=Join-Path $Fixture source.txt;$target=Join-Path $Fixture target.txt
    [IO.File]::WriteAllText($source,'new');[IO.File]::WriteAllText($target,'old')
    Move-AiSopWorkflowFileAtomic $source $target
    if([IO.File]::ReadAllText($target) -ne 'new' -or [IO.File]::Exists($source)){throw 'Atomic publication changed'}
    if((Resolve-PhysicalPathIdentity $target) -ne (Resolve-PhysicalPathIdentity (Join-Path $Fixture './target.txt'))){throw 'Physical identity changed'}
    Write-Output "PASS: native $Probe compilations=$script:compilations"
    exit 0
}
. (Join-Path $scripts hidden-process.ps1)
. (Join-Path $PSScriptRoot fixtures/retained-fixture.ps1)
$root=Join-Path ([IO.Path]::GetTempPath()) ('native-types-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
$ok=$false;$failure=''
try{
    # Brackets must remain literal even when native source paths contain spaces.
    $nativeRoot=Join-Path $root '[native] source'
    [IO.Directory]::CreateDirectory($nativeRoot)|Out-Null
    foreach($name in @('path-identity.ps1','atomic-file.ps1','native-types.ps1','native')){
        Copy-Item -LiteralPath (Join-Path $scripts $name) -Destination $nativeRoot -Recurse
    }
    $modes=if([OperatingSystem]::IsWindows()){@('cold','PhysicalPath','AtomicFile')}else{@('cold')}
    foreach($mode in $modes){
        $child=Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-File',$PSCommandPath,'-Probe',$mode,'-Fixture',$root,'-NativeScriptsRoot',$nativeRoot) -RedirectStandardOutput (Join-Path $root "$mode.out.log") -RedirectStandardError (Join-Path $root "$mode.err.log") -FailurePath (Join-Path $root "$mode.failure.json") -TimeoutSeconds 30 -CloseStandardInput -PassThru
        try{$child.WaitForExit();if($child.ExitCode -ne 0){throw "Native probe failed: $mode"}}finally{$child.Dispose()}
    }
    $ok=$true
}catch{$failure=$_.ToString();throw}finally{Complete-AiSopTestFixture -Root $root -Prefix native-types- -Succeeded $ok -Failure $failure}
Write-Output 'PASS: literal bracket/space source paths, one cold compilation, partial preloading, repeat imports and physical/atomic behavior'
