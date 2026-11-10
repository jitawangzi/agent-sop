# 测试专用独立句柄登记与补救，不依赖被测清理实现，也不根据裸 PID 终止进程。
function New-AiSopTestProcesses { return @{entries=[Collections.Generic.List[object]]::new()} }
function Register-AiSopTestProcess {
    param($Handle,$Owned)
    $candidate=$null
    try {
        if(@($Owned.entries|Where-Object {[object]::ReferenceEquals($_.handle,$Handle)}).Count){return}
        if($Handle.Inner.HasExited){$Owned.entries.Add(@{process=$Handle.Inner;handle=$Handle;exited=$true});return}
        try {$candidate=[Diagnostics.Process]::GetProcessById($Handle.Id);[void]$candidate.Handle}
        catch {if($Handle.Inner.HasExited){$Owned.entries.Add(@{process=$Handle.Inner;handle=$Handle;exited=$true});return};throw}
        if($candidate.StartTime.ToUniversalTime().Ticks -ne $Handle.Inner.StartTime.ToUniversalTime().Ticks){throw 'TEST_PROCESS_IDENTITY_MISMATCH'}
        $Owned.entries.Add(@{process=$candidate;handle=$Handle});$candidate=$null
    } catch {
        $primary=$_
        # 原始启动对象保留到统一收尾，即使登记及第一次补救均失败也不会丢失。
        $Owned.entries.Add(@{process=$Handle.Inner;handle=$Handle})
        throw $primary
    } finally {if($candidate){try{$candidate.Dispose()}catch{Write-Warning $_}}}
}
function Close-AiSopTestProcesses {
    param($Owned)
    $errors=[Collections.Generic.List[string]]::new()
    foreach($entry in @($Owned.entries.ToArray())){
        try {
            if($entry.uncertainty){throw $entry.uncertainty}
            $process=$entry.process
            if(-not $entry.exited -and -not $process.HasExited){$process.Kill($true);if(-not $process.WaitForExit(3000)){throw 'TEST_RESCUE_TIMEOUT'}}
            # 让运行器完成有界输出排空判定，不能用 Dispose 的取消掩盖继承管道。
            if(-not $entry.handle.Completed){$entry.handle.WaitForExit()}
            $entry.handle.Dispose()
            if($entry.handle.Diagnostic -match 'OUTPUT_DRAIN_TIMED_OUT'){
                # 本地句柄释放成功不能证明已被重新托管的后代退出，保留诊断和登记。
                $entry.uncertainty=[string]$entry.handle.Diagnostic
                throw $entry.uncertainty
            }
            if(-not $entry.handle.Cleanup.confirmed){throw 'TEST_HANDLE_CLEANUP_UNCONFIRMED'}
            $process.Dispose();[void]$Owned.entries.Remove($entry)
        }catch{$errors.Add($_.ToString())}
    }
    return @{confirmed=($errors.Count -eq 0);diagnostics=@($errors.ToArray())}
}
