#requires -Version 7.0

# Cross-platform physical path normalization library (Agent-SOP).
# Resolves symlinks, junction points, and Windows 8.3/case variations to canonical identities.

. (Join-Path $PSScriptRoot 'native-types.ps1')
Initialize-AiSopNativeTypes

function Resolve-PhysicalPathIdentity {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)

    # 1. POSIX (Linux / macOS) execution path: native System.IO resolution
    # This function can be inherited by another script without dot-sourcing
    # this file again. Platform selection must not depend on that script's scope.
    if (-not [System.OperatingSystem]::IsWindows()) {
        $existingPath = $fullPath
        $missingSegments = [System.Collections.Generic.List[string]]::new()
        while (-not (Test-Path -LiteralPath $existingPath)) {
            $leaf = [System.IO.Path]::GetFileName($existingPath)
            if ([string]::IsNullOrWhiteSpace($leaf)) {
                throw "Cannot resolve a physical path identity for: $fullPath"
            }
            $missingSegments.Insert(0, $leaf)
            $parent = [System.IO.Path]::GetDirectoryName($existingPath)
            if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $existingPath) {
                throw "Cannot resolve a physical path identity for: $fullPath"
            }
            $existingPath = $parent
        }

        try {
            $fileInfo = [System.IO.FileInfo]::new($existingPath)
            if ($fileInfo.Exists -or [System.IO.Directory]::Exists($existingPath)) {
                $target = $fileInfo.ResolveLinkTarget($true)
                if ($null -ne $target) {
                    $existingPath = $target.FullName
                }
            }
        } catch { }

        $resolvedPath = $existingPath
        foreach ($segment in $missingSegments) {
            $resolvedPath = Join-Path $resolvedPath $segment
        }
        $identity = [System.IO.Path]::GetFullPath($resolvedPath)
        $root = [System.IO.Path]::GetPathRoot($identity)
        if ($identity.Equals($root, [System.StringComparison]::OrdinalIgnoreCase)) {
            return $identity
        }
        return $identity.TrimEnd(
            [System.IO.Path]::DirectorySeparatorChar,
            [System.IO.Path]::AltDirectorySeparatorChar
        )
    }

    # 2. Windows execution path: Win32 handle resolution
    $existingPath = $fullPath
    $missingSegments = [System.Collections.Generic.List[string]]::new()
    while (-not (Test-Path -LiteralPath $existingPath)) {
        $leaf = [System.IO.Path]::GetFileName($existingPath)
        if ([string]::IsNullOrWhiteSpace($leaf)) {
            throw "Cannot resolve a physical path identity for: $fullPath"
        }
        $missingSegments.Insert(0, $leaf)
        $parent = [System.IO.Path]::GetDirectoryName($existingPath)
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $existingPath) {
            throw "Cannot resolve a physical path identity for: $fullPath"
        }
        $existingPath = $parent
    }

    $resolvedPath = [AiSop.PhysicalPathV2]::Resolve($existingPath)
    foreach ($segment in $missingSegments) {
        $resolvedPath = Join-Path $resolvedPath $segment
    }
    $identity = [System.IO.Path]::GetFullPath($resolvedPath)
    $root = [System.IO.Path]::GetPathRoot($identity)
    if ($identity.Equals($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $identity
    }
    return $identity.TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar,
        [System.IO.Path]::AltDirectorySeparatorChar
    )
}
