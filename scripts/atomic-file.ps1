#requires -Version 7.0
# Windows MoveFileEx cannot replace an open target; ReplaceFile can expose a
# missing name. Use a single POSIX rename on Windows and the native rename used
# by File.Move(overwrite) on Unix. Never fall back to delete-then-move.
if ([OperatingSystem]::IsWindows() -and -not ('AiSop.AtomicFile' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace AiSop {
    public static class AtomicFile {
        [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
        private static extern SafeFileHandle CreateFileW(string name, uint access,
            uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool SetFileInformationByHandle(SafeFileHandle handle,
            int informationClass, IntPtr buffer, uint size);

        private static string ExtendedPath(string path) {
            string full=Path.GetFullPath(path);
            if(full.StartsWith(@"\\?\",StringComparison.Ordinal)) return full;
            if(full.StartsWith(@"\\",StringComparison.Ordinal)) return @"\\?\UNC\"+full.Substring(2);
            return @"\\?\"+full;
        }

        public static void Publish(string source, string target) {
            // DELETE access; share existing readers. No ignore-readonly/ACL flags.
            using (var handle=CreateFileW(ExtendedPath(source),0x10000,7,IntPtr.Zero,3,0,IntPtr.Zero)) {
                if(handle.IsInvalid) {
                    int error=Marshal.GetLastWin32Error();
                    throw new Win32Exception(error,"ATOMIC_RENAME_OPEN_FAILED: native="+error);
                }
                byte[] name=Encoding.Unicode.GetBytes(ExtendedPath(target));
                int offset=IntPtr.Size==8 ? 20 : 12;
                // FILE_RENAME_INFO requires a terminating WCHAR, excluded from length.
                int size=Math.Max(24,checked(offset+name.Length+2));
                IntPtr buffer=Marshal.AllocHGlobal(size);
                try {
                    for(int i=0;i<size;i++) Marshal.WriteByte(buffer,i,0);
                    Marshal.WriteInt32(buffer,0,3); // REPLACE_IF_EXISTS | POSIX_SEMANTICS
                    Marshal.WriteInt32(buffer,offset-4,name.Length);
                    Marshal.Copy(name,0,IntPtr.Add(buffer,offset),name.Length);
                    if(!SetFileInformationByHandle(handle,22,buffer,(uint)size)) {
                        int error=Marshal.GetLastWin32Error();
                        throw new Win32Exception(error,"ATOMIC_RENAME_PUBLISH_FAILED: native="+error);
                    }
                } finally { Marshal.FreeHGlobal(buffer); }
            }
        }
    }
}
'@
}

function Move-AiSopWorkflowFileAtomic {
    param([string]$Source, [string]$Target)
    if ([OperatingSystem]::IsWindows()) { [AiSop.AtomicFile]::Publish($Source, $Target) }
    else { [IO.File]::Move($Source, $Target, $true) }
}
