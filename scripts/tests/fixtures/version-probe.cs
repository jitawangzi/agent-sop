using System;
using System.Diagnostics;
using System.IO;
using System.Threading;

// 仅供隔离测试：父进程正常退出，后代保留继承的输出句柄。
class VersionProbeFixture {
    static int Main(string[] args) {
        if (args.Length > 0 && args[0] == "child") { Thread.Sleep(60000); return 0; }
        string root = AppDomain.CurrentDomain.BaseDirectory;
        string mode = File.ReadAllText(Path.Combine(root, "mode.txt")).Trim();
        if (mode == "nonzero") { Console.Error.WriteLine("fixture-version-failure"); return 23; }
        if (mode == "empty") return 0;
        if (mode == "orphan") {
            var info = new ProcessStartInfo(Process.GetCurrentProcess().MainModule.FileName, "child");
            info.UseShellExecute = false; info.CreateNoWindow = true;
            var child = Process.Start(info);
            File.WriteAllText(Path.Combine(root, "identity.json"), "{\"pid\":" + child.Id + ",\"startedTicks\":" + child.StartTime.ToUniversalTime().Ticks + "}");
        }
        Console.WriteLine("fixture-1.0"); return 0;
    }
}
