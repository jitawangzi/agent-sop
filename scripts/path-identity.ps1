if (-not ("ServerNew.PhysicalPath" -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace ServerNew
{
    public static class PhysicalPath
    {
        private const uint FileReadAttributes = 0x80;
        private const uint FileShareRead = 0x1;
        private const uint FileShareWrite = 0x2;
        private const uint FileShareDelete = 0x4;
        private const uint OpenExisting = 3;
        private const uint FileFlagBackupSemantics = 0x02000000;

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern SafeFileHandle CreateFileW(
            string fileName,
            uint desiredAccess,
            uint shareMode,
            IntPtr securityAttributes,
            uint creationDisposition,
            uint flagsAndAttributes,
            IntPtr templateFile
        );

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        private static extern uint GetFinalPathNameByHandleW(
            SafeFileHandle file,
            StringBuilder filePath,
            uint filePathSize,
            uint flags
        );

        public static string Resolve(string path)
        {
            using (SafeFileHandle handle = CreateFileW(
                path,
                FileReadAttributes,
                FileShareRead | FileShareWrite | FileShareDelete,
                IntPtr.Zero,
                OpenExisting,
                FileFlagBackupSemantics,
                IntPtr.Zero
            ))
            {
                if (handle.IsInvalid)
                {
                    throw new Win32Exception(Marshal.GetLastWin32Error());
                }

                uint capacity = 512;
                while (true)
                {
                    StringBuilder result = new StringBuilder((int)capacity);
                    uint length = GetFinalPathNameByHandleW(handle, result, capacity, 0);
                    if (length == 0)
                    {
                        throw new Win32Exception(Marshal.GetLastWin32Error());
                    }
                    if (length < capacity)
                    {
                        string resolved = result.ToString();
                        if (resolved.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase))
                        {
                            return @"\\" + resolved.Substring(8);
                        }
                        if (resolved.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase))
                        {
                            return resolved.Substring(4);
                        }
                        return resolved;
                    }
                    capacity = length + 1;
                }
            }
        }
    }
}
'@
}

function Resolve-PhysicalPathIdentity {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
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

    $resolvedPath = [ServerNew.PhysicalPath]::Resolve($existingPath)
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
