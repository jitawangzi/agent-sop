using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace AiSop
{
    public static class PhysicalPathV2
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

        [StructLayout(LayoutKind.Sequential)]
        private struct FileIdentity {
            public uint Attributes;
            public System.Runtime.InteropServices.ComTypes.FILETIME Creation, Access, Write;
            public uint Volume, SizeHigh, SizeLow, Links, IndexHigh, IndexLow;
        }
        [DllImport("kernel32.dll", SetLastError=true)]
        private static extern bool GetFileInformationByHandle(SafeFileHandle handle, out FileIdentity identity);
        private static bool SameFile(SafeFileHandle first, SafeFileHandle second) {
            FileIdentity a, b;
            if (!GetFileInformationByHandle(first, out a) || !GetFileInformationByHandle(second, out b))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            return a.Volume == b.Volume && a.IndexHigh == b.IndexHigh && a.IndexLow == b.IndexLow;
        }
        public static string Resolve(string path)
        {
            for (int attempt = 0; attempt < 3; attempt++) {
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
                        // An atomic replacement can retire this handle into $Extend/$Deleted.
                        // Retry only when a fresh handle proves a different file identity.
                        using (SafeFileHandle current = CreateFileW(path, FileReadAttributes,
                            FileShareRead | FileShareWrite | FileShareDelete, IntPtr.Zero,
                            OpenExisting, FileFlagBackupSemantics, IntPtr.Zero)) {
                            if (current.IsInvalid) throw new Win32Exception(Marshal.GetLastWin32Error());
                            if (!SameFile(handle, current)) break;
                        }
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
            throw new System.IO.IOException("PHYSICAL_PATH_CHANGED: file identity changed during all three observations");
        }
    }
}
