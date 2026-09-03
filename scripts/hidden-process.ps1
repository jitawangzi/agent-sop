#requires -Version 7.0
# Hidden child-process launcher for Windows console hosts.
#
# Start-Process -WindowStyle Hidden is ignored when stdout/stderr are redirected
# (UseShellExecute becomes false). The child then allocates a visible console.
# CreateNoWindow + UseShellExecute=false is the flag that actually suppresses it.

function Start-AiSopHiddenProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,

        [string[]]$ArgumentList = @(),

        [string]$RedirectStandardOutput,

        [string]$RedirectStandardError,

        [switch]$PassThru
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $FilePath
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    foreach ($arg in @($ArgumentList)) {
        if ($null -eq $arg) { continue }
        [void]$psi.ArgumentList.Add([string]$arg)
    }

    $outStream = $null
    $errStream = $null
    if (-not [string]::IsNullOrWhiteSpace($RedirectStandardOutput)) {
        $psi.RedirectStandardOutput = $true
        $outDir = Split-Path -Parent $RedirectStandardOutput
        if (-not [string]::IsNullOrWhiteSpace($outDir) -and -not (Test-Path -LiteralPath $outDir)) {
            [void][System.IO.Directory]::CreateDirectory($outDir)
        }
        $outStream = [System.IO.File]::Open(
            $RedirectStandardOutput,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::Read
        )
    }
    if (-not [string]::IsNullOrWhiteSpace($RedirectStandardError)) {
        $psi.RedirectStandardError = $true
        $errDir = Split-Path -Parent $RedirectStandardError
        if (-not [string]::IsNullOrWhiteSpace($errDir) -and -not (Test-Path -LiteralPath $errDir)) {
            [void][System.IO.Directory]::CreateDirectory($errDir)
        }
        $errStream = [System.IO.File]::Open(
            $RedirectStandardError,
            [System.IO.FileMode]::Create,
            [System.IO.FileAccess]::Write,
            [System.IO.FileShare]::Read
        )
    }

    $proc = [System.Diagnostics.Process]::new()
    $proc.StartInfo = $psi
    if (-not $proc.Start()) {
        if ($outStream) { $outStream.Dispose() }
        if ($errStream) { $errStream.Dispose() }
        throw "Failed to start hidden process: $FilePath"
    }

    $copyTasks = [System.Collections.Generic.List[System.Threading.Tasks.Task]]::new()
    $streams = [System.Collections.Generic.List[System.IO.Stream]]::new()
    if ($null -ne $outStream) {
        $copyTasks.Add($proc.StandardOutput.BaseStream.CopyToAsync($outStream))
        $streams.Add($outStream)
    }
    if ($null -ne $errStream) {
        $copyTasks.Add($proc.StandardError.BaseStream.CopyToAsync($errStream))
        $streams.Add($errStream)
    }

    $handle = [pscustomobject]@{
        PSTypeName = "AiSopHiddenProcess"
        Inner      = $proc
        CopyTasks  = $copyTasks
        Streams    = $streams
    }
    Add-Member -InputObject $handle -MemberType ScriptProperty -Name Id -Value { $this.Inner.Id }
    Add-Member -InputObject $handle -MemberType ScriptProperty -Name ExitCode -Value { $this.Inner.ExitCode }
    Add-Member -InputObject $handle -MemberType ScriptProperty -Name HasExited -Value { $this.Inner.HasExited }
    Add-Member -InputObject $handle -MemberType ScriptProperty -Name StartInfo -Value { $this.Inner.StartInfo }
    Add-Member -InputObject $handle -MemberType ScriptMethod -Name Refresh -Value { $this.Inner.Refresh() } | Out-Null
    Add-Member -InputObject $handle -MemberType ScriptMethod -Name WaitForExit -Value {
        $this.Inner.WaitForExit()
        if ($this.CopyTasks.Count -gt 0) {
            [void][System.Threading.Tasks.Task]::WaitAll(@($this.CopyTasks))
        }
        foreach ($stream in @($this.Streams)) {
            if ($null -ne $stream) { $stream.Dispose() }
        }
        $this.Streams.Clear()
    } | Out-Null
    Add-Member -InputObject $handle -MemberType ScriptMethod -Name Dispose -Value {
        try { $this.WaitForExit() } catch { }
        $this.Inner.Dispose()
    } | Out-Null

    if ($PassThru) { return $handle }
    $handle.WaitForExit()
    $code = $handle.ExitCode
    $handle.Dispose()
    return $code
}
