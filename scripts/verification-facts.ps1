# 仅解释记录字段；不验证报告语义、输入现状或任务完成资格。
function Get-AiSopVerificationFacts($Record) {
    $outcomePassed=$Record.outcome -is [string] -and $Record.outcome -ceq 'PASSED'
    $exit=$Record.exitCode
    $exitZero=($exit -is [sbyte] -or $exit -is [byte] -or $exit -is [short] -or $exit -is [ushort] -or $exit -is [int] -or $exit -is [uint] -or $exit -is [long] -or $exit -is [ulong] -or $exit -is [bigint] -or $exit -is [single] -or $exit -is [double] -or $exit -is [decimal]) -and $exit -eq 0
    $stable=$Record.inputsStable -is [bool] -and $Record.inputsStable
    return @{outcomePassed=$outcomePassed;exitSucceeded=$exitZero;inputsStable=$stable;
        recordedPass=($outcomePassed -and $exitZero -and $stable)}
}
