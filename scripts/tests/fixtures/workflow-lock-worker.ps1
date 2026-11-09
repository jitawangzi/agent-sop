param($Engine,$Lock,$Result,[switch]$Retain)
$ErrorActionPreference='Stop'
. (Join-Path $Engine scripts/workflow-transaction.ps1)
if($Retain){$script:AiSopForceUnixLockSemantics=$true}
$clock=[Diagnostics.Stopwatch]::StartNew();$success=0;$errors=@{}
while($clock.Elapsed.TotalSeconds -lt 10){
 $s=$null
 try{$s=Enter-AiSopWorkflowFileLock -LockPath $Lock -DeadlineUtc ([DateTimeOffset]::UtcNow.AddSeconds(3));$success++}
 catch{$message=$_.Exception.Message;if(-not $errors.ContainsKey($message)){$errors[$message]=0};$errors[$message]++}
 finally{if($s){$s.Dispose();Remove-AiSopWorkflowLockFile $Lock}}
}
@{success=$success;errors=$errors;retain=[bool]$Retain}|ConvertTo-Json -Depth 5|Set-Content $Result
