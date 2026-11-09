#requires -Version 7.0
$ErrorActionPreference='Stop'
$scripts=Split-Path -Parent $PSScriptRoot;$engine=Split-Path -Parent $scripts
. (Join-Path $scripts workflow-transaction.ps1)
. (Join-Path $scripts hidden-process.ps1)
$root=Join-Path ([IO.Path]::GetTempPath()) ('workflow-boundaries-'+[guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
Remove-Item Env:AI_SOP_INVOCATION_SESSION_ID -ErrorAction SilentlyContinue
Remove-Item Env:AI_SOP_WORKFLOW_DEADLINE_MS,Env:SERVER_NEW_WORKFLOW_TRANSACTION_DEADLINE_MS -ErrorAction SilentlyContinue
foreach($kind in @('OWNER','SESSION','COMMAND_GRANT','TRANSACTION')){[Environment]::SetEnvironmentVariable("AI_SOP_${kind}_REGISTRY",(Join-Path $root $kind))}
function Assert($ok,$message){if(-not $ok){throw $message}}
function Run([string]$name,[string[]]$arguments){
 $p=Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList $arguments -RedirectStandardOutput (Join-Path $root "$name.out") -RedirectStandardError (Join-Path $root "$name.err") -TimeoutSeconds 45 -PassThru
 try{$p.WaitForExit();Assert ($p.ExitCode -eq 0) "$name failed: $([IO.File]::ReadAllText((Join-Path $root "$name.err")))"}finally{$p.Dispose()}
}
try {
 $lock=Join-Path $root gate.lock
 $held=Enter-AiSopWorkflowFileLock $lock
 try{$failed=$false;try{$other=Enter-AiSopWorkflowFileLock $lock ([DateTimeOffset]::UtcNow.AddMilliseconds(100));$other.Dispose()}catch{$failed=$_.Exception.Message -eq 'WORKFLOW_LOCK_TIMEOUT'};Assert $failed 'Held lock did not exclude contender'}finally{Exit-AiSopWorkflowLocks @(@{Path=$lock;Stream=$held})}
 Assert ([IO.File]::Exists($lock)) 'Default platform release deleted sentinel'
 $held=Enter-AiSopWorkflowFileLock $lock;$held.Dispose()
 $holderScript=Join-Path $root holder.ps1;$ready=Join-Path $root ready
 @'
param($Engine,$Lock,$Ready)
. (Join-Path $Engine scripts/workflow-transaction.ps1)
$held=Enter-AiSopWorkflowFileLock $Lock
[IO.File]::WriteAllText($Ready,'ready')
Start-Sleep 60
'@|Set-Content $holderScript
 $holder=Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-File',$holderScript,$engine,$lock,$ready) -TimeoutSeconds 20 -PassThru
 try{
  $limit=[DateTimeOffset]::UtcNow.AddSeconds(10)
  while(-not [IO.File]::Exists($ready) -and [DateTimeOffset]::UtcNow -lt $limit){[void]$holder.Poll();Start-Sleep -Milliseconds 20}
  Assert ([IO.File]::Exists($ready)) 'Holder did not acquire lock'
  $blocked=$false;try{$other=Enter-AiSopWorkflowFileLock $lock ([DateTimeOffset]::UtcNow.AddMilliseconds(100));$other.Dispose()}catch{$blocked=$_.Exception.Message -eq 'WORKFLOW_LOCK_TIMEOUT'};Assert $blocked 'Other process bypassed held sentinel'
  $holder.Inner.Kill($true);$holder.WaitForExit()
 }finally{$holder.Dispose()}
 $held=Enter-AiSopWorkflowFileLock $lock;$held.Dispose()
 Assert ([IO.File]::Exists($lock)) 'Crash recovery required deleting sentinel'
 if([OperatingSystem]::IsWindows()){
  [IO.File]::SetAttributes($lock,[IO.FileAttributes]::ReadOnly)
  try{$failed=$false;try{$other=Enter-AiSopWorkflowFileLock $lock;$other.Dispose()}catch{$failed=$_.Exception.Message -eq 'WORKFLOW_REGISTRY_IO_ERROR'};Assert $failed 'True permission rejection was hidden'}finally{[IO.File]::SetAttributes($lock,[IO.FileAttributes]::Normal)}
 }
 # 原子读者看到完整旧版，新读者看到完整新版。
 $state=Join-Path $root state.json;Write-AiSopWorkflowTextAtomic $state '{"version":1}'
 $reader=[IO.File]::Open($state,'Open','Read',([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
 try{Write-AiSopWorkflowTextAtomic $state '{"version":2}';Write-AiSopWorkflowTextAtomic $state '{"version":3}';$text=[IO.StreamReader]::new($reader);try{Assert ($text.ReadToEnd() -eq '{"version":1}') 'Old reader observed mixed state'}finally{$text.Dispose()};Assert ((Read-AiSopWorkflowText $state) -eq '{"version":3}') 'New reader did not see committed state'}finally{$reader.Dispose()}
 # 冷进程必须走到正常的NO_STATE分支，而非在首次依赖加载后耗尽操作预算。
 # A real rejected publication must preserve both the target and candidate.
 if([OperatingSystem]::IsWindows()){
  $deniedPath=Join-Path $root denied.json;[IO.File]::WriteAllText($deniedPath,'old')
  [IO.File]::SetAttributes($deniedPath,[IO.FileAttributes]::ReadOnly)
  try{$rejected=$false;try{Write-AiSopWorkflowTextAtomic $deniedPath 'new'}catch{$rejected=$_.Exception.Message -eq 'WORKFLOW_REGISTRY_IO_ERROR'};Assert $rejected 'Real readonly publication rejection was hidden'}finally{[IO.File]::SetAttributes($deniedPath,[IO.FileAttributes]::Normal)}
  Assert ([IO.File]::ReadAllText($deniedPath) -eq 'old') 'Rejected publication lost original'
  $temps=@(Get-ChildItem -LiteralPath $root -Filter 'denied.json.*.tmp')
  Assert ($temps.Count -eq 1 -and [IO.File]::ReadAllText($temps[0].FullName) -eq 'new') 'Rejected publication discarded candidate'
  Write-AiSopWorkflowTextAtomic $deniedPath 'new'
  Assert ((Read-AiSopWorkflowText $deniedPath) -eq 'new') 'Publication did not recover after attribute restoration'
 }
 Add-Type -Path (Join-Path $PSScriptRoot fixtures/workflow-publication-probe.cs)
 $publishRoot=Join-Path $root publication
 $publish=[Action[string,string]]{param($source,$target) Move-AiSopWorkflowFileAtomic -Source $source -Target $target}
 $probe=[WorkflowPublicationProbe]::Run($publishRoot,$publish)
 $probe|ConvertTo-Json -Depth 5|Set-Content (Join-Path $root publication.json)
 Assert ($probe.missing -eq 0 -and $probe.errors.Count -eq 0 -and $probe.writes -eq 1000 -and $probe.opens -gt 0) 'Publication exposed missing/corrupt state or failed'
 Assert ((Read-AiSopWorkflowText (Join-Path $publishRoot state.json)) -eq 'value-999') 'Publication did not update exact target'
 Assert (@(Get-ChildItem -LiteralPath $publishRoot -File).Count -eq 1) 'Publication left source or unexpected target names'
 $longRoot=Join-Path $root (('long-path-segment-'*8)+'/中文 路径/'+('deep-segment-'*8))
 [IO.Directory]::CreateDirectory($longRoot)|Out-Null
 $longTarget=Join-Path $longRoot '状态.json'
 Write-AiSopWorkflowTextAtomic $longTarget 'first'
 Write-AiSopWorkflowTextAtomic $longTarget 'second'
 Assert ((Read-AiSopWorkflowText $longTarget) -eq 'second') 'Long Unicode target was not published'
 Assert (@(Get-ChildItem -LiteralPath $longRoot -File).Count -eq 1) 'Long path published to an unexpected name'
 Run cold @('-NoProfile','-File',(Join-Path $scripts workflow-state.ps1),'-Operation','Status','-Path',(Join-Path $root missing.json))
 Assert ([IO.File]::ReadAllText((Join-Path $root cold.out)).Contains('NO_STATE')) 'Cold startup did not reach operation'
 # Enter the real state script with an already expired operation deadline. A
 # temporary copy changes only deadline construction, not the checks or branch.
 $deadlineEngine=Join-Path $root deadline-engine;[IO.Directory]::CreateDirectory($deadlineEngine)|Out-Null
 Copy-Item $scripts $deadlineEngine -Recurse;Copy-Item (Join-Path $engine schemas) $deadlineEngine -Recurse
 $deadlineEntry=Join-Path $deadlineEngine scripts/workflow-state.ps1
 $body=[IO.File]::ReadAllText($deadlineEntry)
 $anchor='$MutationDeadlineUtc = [DateTimeOffset]::UtcNow.AddMilliseconds($mutationDeadlineMs)'
 Assert ($body.Contains($anchor)) 'Deadline injection anchor changed'
 [IO.File]::WriteAllText($deadlineEntry,$body.Replace($anchor,'$MutationDeadlineUtc = [DateTimeOffset]::UtcNow.AddMilliseconds(-1)'))
 $p=Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-File',$deadlineEntry,'-Operation','Status','-Path',(Join-Path $root absent.json)) -RedirectStandardOutput (Join-Path $root expired.out) -RedirectStandardError (Join-Path $root expired.err) -TimeoutSeconds 20 -PassThru
 try{$p.WaitForExit();Assert ($p.ExitCode -ne 0 -and [IO.File]::ReadAllText((Join-Path $root expired.err)).Contains('WORKFLOW_DEADLINE_EXCEEDED')) 'Expired state entry stopped rejecting operations'}finally{$p.Dispose()}
 $expired=$false;try{Assert-AiSopWorkflowDeadline ([DateTimeOffset]::UtcNow.AddMilliseconds(-1))}catch{$expired=$_.Exception.Message -eq 'WORKFLOW_DEADLINE_EXCEEDED'};Assert $expired 'Expired mutation budget stopped failing'
 $jobs=@()
 try{
  foreach($i in 1..4){$jobs+=Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-File',(Join-Path $PSScriptRoot fixtures/workflow-lock-worker.ps1),'-Engine',$engine,'-Lock',$lock,'-Result',(Join-Path $root "worker-$i.json")) -RedirectStandardOutput (Join-Path $root "$i.out") -RedirectStandardError (Join-Path $root "$i.err") -TimeoutSeconds 40 -PassThru}
  do{$pending=$false;foreach($p in $jobs){if(-not $p.Poll()){$pending=$true}};if($pending){Start-Sleep -Milliseconds 20}}while($pending)
  foreach($p in $jobs){Assert ($p.ExitCode -eq 0) 'Lock worker failed'}
 }finally{foreach($p in $jobs){$p.Dispose()}}
 foreach($i in 1..4){$r=Get-Content (Join-Path $root "worker-$i.json") -Raw|ConvertFrom-Json -AsHashtable;Assert ($r.success -gt 0 -and $r.errors.Count -eq 0) 'Concurrent lock reuse produced IO failure'}
 $writerScript=Join-Path $root writer.ps1;$go=Join-Path $root go
 @'
param($Engine,$Root,$Id,$Go)
. (Join-Path $Engine scripts/workflow-transaction.ps1)
$limit=[DateTimeOffset]::UtcNow.AddSeconds(10)
while(-not [IO.File]::Exists($Go)){if([DateTimeOffset]::UtcNow -gt $limit){throw 'GO_TIMEOUT'};Start-Sleep -Milliseconds 10}
foreach($i in 1..100){Write-AiSopWorkflowTextAtomic (Join-Path $Root "shared-$i.json") '{"published":true}'}
'@|Set-Content $writerScript
 $writers=@()
 try{
  foreach($i in 1..3){$writers+=Start-AiSopHiddenProcess -FilePath (Get-Process -Id $PID).Path -ArgumentList @('-NoProfile','-File',$writerScript,$engine,$root,"$i",$go) -RedirectStandardError (Join-Path $root "writer-$i.err") -TimeoutSeconds 30 -PassThru}
  [IO.File]::WriteAllText($go,'go')
  do{$pending=$false;foreach($p in $writers){if(-not $p.Poll()){$pending=$true}};if($pending){Start-Sleep -Milliseconds 20}}while($pending)
  foreach($p in $writers){Assert ($p.ExitCode -eq 0) 'Concurrent first creation failed'}
 }finally{foreach($p in $writers){$p.Dispose()}}
 foreach($i in 1..100){$r=Read-AiSopWorkflowText (Join-Path $root "shared-$i.json")|ConvertFrom-Json;Assert ($r.published -eq $true) 'Concurrent immutable publication lost complete JSON'}
 $result=Join-Path $root runner.json
 Run runner @('-NoProfile','-File',(Join-Path $PSScriptRoot fixtures/workflow-runner-read-barrier.ps1),'-Engine',$engine,'-Result',$result,'-SharedDelete')
 $r=Get-Content $result -Raw|ConvertFrom-Json;Assert ($r.ready -and $r.exitCode -eq 0) 'Live task reader caused external runner to exit before READY'
 Write-Output "PASS: stable lock sentinel, exclusion, permission denial, atomic read/write, cold deadline, concurrent reuse, runner READY; evidence=$root"
}catch{Write-Output "RETAINED_FIXTURE:$root";throw}
