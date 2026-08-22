function Test-ExactCommandLineArgument {
    param(
        [Parameter(Mandatory)]
        [string]$CommandLine,

        [Parameter(Mandatory)]
        [string]$Argument
    )

    $escapedArgument = [System.Text.RegularExpressions.Regex]::Escape($Argument)
    $pattern = '(?:^|\s)(?:"{0}"|{0})(?=$|\s)' -f $escapedArgument
    return [System.Text.RegularExpressions.Regex]::IsMatch(
        $CommandLine,
        $pattern,
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor
            [System.Text.RegularExpressions.RegexOptions]::CultureInvariant
    )
}

function Get-CommandLineArgumentValue {
    param(
        [Parameter(Mandatory)]
        [string]$CommandLine,

        [Parameter(Mandatory)]
        [string]$Name
    )

    $escapedName = [System.Text.RegularExpressions.Regex]::Escape($Name)
    $pattern = '(?i)(?:^|\s)(?:"{0}=(?<wholeQuoted>[^"]+)"|{0}="(?<valueQuoted>[^"]+)"|{0}=(?<plain>[^\s"]+))' -f $escapedName
    $match = [System.Text.RegularExpressions.Regex]::Match($CommandLine, $pattern)
    if (-not $match.Success) {
        return $null
    }
    foreach ($groupName in @("wholeQuoted", "valueQuoted", "plain")) {
        $value = $match.Groups[$groupName].Value
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }
    return $null
}

function Get-TomcatCatalinaBase {
    param([string]$CommandLine)

    if ([string]::IsNullOrWhiteSpace($CommandLine)) {
        return $null
    }
    $value = Get-CommandLineArgumentValue -CommandLine $CommandLine `
        -Name "-Dcatalina.base"
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }
    return [System.IO.Path]::GetFullPath($value)
}

function Test-TomcatProcessForBase {
    param(
        [object]$ProcessInfo,
        [string]$CatalinaBase
    )

    if (
        $null -eq $ProcessInfo -or
        $ProcessInfo.Name -notmatch "^java(w)?\.exe$"
    ) {
        return $false
    }
    $actualBase = Get-TomcatCatalinaBase -CommandLine $ProcessInfo.CommandLine
    return (
        $null -ne $actualBase -and
        $actualBase.Equals(
            [System.IO.Path]::GetFullPath($CatalinaBase),
            [System.StringComparison]::OrdinalIgnoreCase
        )
    )
}

function Test-ProcessStartTime {
    param(
        [object]$ProcessInfo,
        [string]$ExpectedStartedAt
    )

    if (
        $null -eq $ProcessInfo -or
        [string]::IsNullOrWhiteSpace($ExpectedStartedAt)
    ) {
        return $false
    }
    $actualStartedAt = ([DateTimeOffset]$ProcessInfo.CreationDate).ToUniversalTime()
    $parsedExpectedStartedAt = (
        [DateTimeOffset]::Parse($ExpectedStartedAt)
    ).ToUniversalTime()
    return [Math]::Abs(
        ($actualStartedAt - $parsedExpectedStartedAt).TotalSeconds
    ) -le 1
}
