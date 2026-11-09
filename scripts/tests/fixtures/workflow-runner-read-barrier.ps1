param($Engine,$Result,[switch]$SharedDelete)
$ErrorActionPreference='Stop'
Remove-Item Env:AI_SOP_INVOCATION_SESSION_ID -ErrorAction SilentlyContinue
$root=Join-Path ([IO.Path]::GetTempPath()) ('runner-read-barrier-'+[guid]::NewGuid().ToString('N'))
$workspace=Join-Path $root workspace;$spec=Join-Path $workspace '.ai-workspace/specs/features/Example'
[IO.Directory]::CreateDirectory($spec)|Out-Null
foreach($kind in @('OWNER','SESSION','COMMAND_GRANT','TRANSACTION')){[Environment]::SetEnvironmentVariable("AI_SOP_${kind}_REGISTRY",(Join-Path $root $kind))}
$env:CODEX_SESSION_ID='barrier-native';$env:SERVER_NEW_WORKFLOW_OWNER_DEADLINE_MS='15000'
$scripts=Join-Path $Engine scripts
. (Join-Path $scripts task-context.ps1)
. (Join-Path $scripts hidden-process.ps1)
$sop=Join-Path $workspace .ai-sop;[IO.Directory]::CreateDirectory($sop)|Out-Null
Copy-Item $scripts $sop -Recurse;Copy-Item (Join-Path $Engine schemas) $sop -Recurse
$entry=Join-Path $scripts workflow-task.ps1
& $entry -Operation Start -WorkspacePath $workspace -Feature Example -TaskId barrier -Tier T2 -Objective 'Read versus initial RUNNING atomic write' -Agent CODEX|Out-Null
if($LASTEXITCODE){throw 'START_FAILED'}
$context=Join-Path $workspace .ai-workspace/context;[IO.Directory]::CreateDirectory($context)|Out-Null
@{schemaVersion='1.0';commands=@{slow=@{kind='test';batch='regression';executable='pwsh';arguments=@('-NoProfile','-Command',"[Console]::WriteLine('READY');[Console]::Out.Flush();Start-Sleep 1")}}}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $context verification-commands.json)
$path=Get-AiSopTaskPath $spec barrier
$share=if($SharedDelete){[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete}else{[IO.FileShare]::Read}
$hold=$null;$readerProcess=$null;$runner=$null
$release=Join-Path $root release;$readerReady=Join-Path $root reader-ready
try {
 if($SharedDelete){
  # Pause the actual production reader after opening its stream. Reverting its
  # sharing mode must break this test, even if the writer is unchanged.
  $body=(Get-Command Read-AiSopWorkflowText).ScriptBlock.ToString()
  if(-not $body.Contains('$reader=$null')){throw 'READER_INJECTION_ANCHOR_CHANGED'}
  $body=$body.Replace('$reader=$null','$reader=$null;[IO.File]::WriteAllText($Ready,"ready");$limit=[DateTimeOffset]::UtcNow.AddSeconds(35);while(-not [IO.File]::Exists($Release)){if([DateTimeOffset]::UtcNow -gt $limit){$stream.Dispose();throw "READER_RELEASE_TIMEOUT"};Start-Sleep -Milliseconds 20}')
  $readScript=Join-Path $root reader.ps1
  ('param($Path,$Ready,$Release)'+[Environment]::NewLine+'& {'+$body+'} $Path')|Set-Content $readScript
  $readerProcess=Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-File',$readScript,$path,$readerReady,$release) -RedirectStandardOutput (Join-Path $root reader.out) -RedirectStandardError (Join-Path $root reader.err) -TimeoutSeconds 40 -PassThru
  $limit=[DateTimeOffset]::UtcNow.AddSeconds(10)
  while(-not [IO.File]::Exists($readerReady)){[void]$readerProcess.Poll();if($readerProcess.HasExited -or [DateTimeOffset]::UtcNow -gt $limit){throw 'READER_NOT_READY'};Start-Sleep -Milliseconds 20}
 }else{$hold=[IO.File]::Open($path,[IO.FileMode]::Open,[IO.FileAccess]::Read,$share)}
 $runner=Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-File',$entry,'-Operation','Run','-WorkspacePath',$workspace,'-Feature','Example','-TaskId','barrier','-Agent','CODEX','-Profile','slow') -RedirectStandardOutput (Join-Path $root stdout.log) -RedirectStandardError (Join-Path $root stderr.log) -TimeoutSeconds 30 -PassThru
 $runner.WaitForExit()
 $stdout=[IO.File]::ReadAllText((Join-Path $root stdout.log));$stderr=[IO.File]::ReadAllText((Join-Path $root stderr.log))
 @{engine=$Engine;sharedDelete=[bool]$SharedDelete;exitCode=$runner.ExitCode;ready=$stdout.Contains('READY');stdout=$stdout;stderr=$stderr;fixture=$root}|ConvertTo-Json -Depth 5|Set-Content $Result
} finally {
 if($runner){$runner.Dispose()};if($hold){$hold.Dispose()}
 if($readerProcess){[IO.File]::WriteAllText($release,'release');try{$readerProcess.WaitForExit();if($readerProcess.ExitCode -ne 0){throw 'READER_FAILED'}}finally{$readerProcess.Dispose()}}
}
