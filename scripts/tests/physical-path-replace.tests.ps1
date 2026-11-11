#requires -Version 7.0
$ErrorActionPreference='Stop'
if(-not [OperatingSystem]::IsWindows()){Write-Output 'Windows handle-replacement regression not applicable on this platform';return}
$scripts=Split-Path $PSScriptRoot
# Old types survive upgrades; a new import must use the corrected version.
Add-Type 'namespace AiSop { public static class PhysicalPath { public static string Resolve(string path) { throw new System.Exception("old-type-selected"); } } }'
. (Join-Path $scripts path-identity.ps1)
. (Join-Path $scripts task-execution.ps1)
$source=[IO.File]::ReadAllText((Join-Path $scripts native/PhysicalPath.cs)).Replace('namespace AiSop','namespace PathRaceFixture').Replace('public static string Resolve(string path)','public static Action OnOpened; public static string Resolve(string path)').Replace('uint capacity = 512;','if (OnOpened != null) OnOpened(); uint capacity = 512;')
Add-Type -TypeDefinition $source
$root=Join-Path ([IO.Path]::GetTempPath()) ('physical-race-'+[guid]::NewGuid().ToString('N'));[IO.Directory]::CreateDirectory($root)|Out-Null
$target=Join-Path $root task.json;$replacement=Join-Path $root next.json
$passed=$false
try{
    [IO.File]::WriteAllText($target,'old');$script:opens=0
    [PathRaceFixture.PhysicalPathV2]::OnOpened=[Action]{
        $script:opens++
        if($script:opens -eq 1){[IO.File]::WriteAllText($replacement,'new');[AiSop.AtomicFile]::Publish($replacement,$target)}
    }
    $result=[PathRaceFixture.PhysicalPathV2]::Resolve($target)
    if($script:opens -ne 2 -or $result -ne $target -or [IO.File]::ReadAllText($target) -ne 'new'){throw 'Replacement was not retried using current file identity'}
    $script:opens=0
    [PathRaceFixture.PhysicalPathV2]::OnOpened=[Action]{$script:opens++;[IO.File]::WriteAllText($replacement,[string]$script:opens);[AiSop.AtomicFile]::Publish($replacement,$target)}
    $failure='';try{[void][PathRaceFixture.PhysicalPathV2]::Resolve($target)}catch{$failure=$_.Exception.Message}
    if($script:opens -ne 3 -or $failure -notmatch 'PHYSICAL_PATH_CHANGED'){throw 'Continuous replacement did not fail within three observations'}
    [PathRaceFixture.PhysicalPathV2]::OnOpened=$null
    if((Resolve-PhysicalPathIdentity $target) -ne $target){throw 'Old loaded type affected upgraded path entry'}
    $spec=Join-Path $root spec;$outside=Join-Path $root outside
    [IO.Directory]::CreateDirectory((Join-Path $spec tasks))|Out-Null;[IO.Directory]::CreateDirectory($outside)|Out-Null
    [IO.File]::WriteAllText((Join-Path $outside task.json),'{}')
    $link=Join-Path $spec tasks/change
    New-Item -ItemType Junction -Path $link -Value $outside|Out-Null
    try{$failure='';try{Get-AiSopTaskPath $spec change|Out-Null}catch{$failure=$_.Exception.Message};if($failure -notmatch 'TASK_PATH_ESCAPE'){throw 'Real linked task escape was accepted'}}finally{Remove-Item -LiteralPath $link -Force}
    $passed=$true
    Write-Output 'PASS: atomic replacement retries by file identity; repeated changes bounded; old type upgrade and real linked escape refusal'
}finally{
    [PathRaceFixture.PhysicalPathV2]::OnOpened=$null
    if($passed){[IO.Directory]::Delete($root,$true)}else{Write-Output "RETAINED_FIXTURE:$root"}
}
