using System.Diagnostics;
using System.Management;

namespace JarvisHUD;

/// Live telemetry: CPU, memory, disk, battery, temperature where Windows exposes it, top processes.
static class Stats {
    static readonly object lock_ = new();
    static PerformanceCounter? cpu;
    static string cached = ""; static DateTime cachedAt = DateTime.MinValue;

    public static double CpuPercent() {
        try {
            lock (lock_) {
                if (cpu == null) { cpu = new PerformanceCounter("Processor", "% Processor Time", "_Total", true); cpu.NextValue(); Thread.Sleep(250); }
                return Math.Round(cpu.NextValue(), 0);
            }
        } catch { return -1; }
    }
    public static (long total, long avail) MemoryBytes() {
        try {
            using var s = new ManagementObjectSearcher("SELECT TotalVisibleMemorySize, FreePhysicalMemory FROM Win32_OperatingSystem");
            foreach (ManagementObject o in s.Get()) return (Convert.ToInt64(o["TotalVisibleMemorySize"]) * 1024, Convert.ToInt64(o["FreePhysicalMemory"]) * 1024);
        } catch { }
        return (0, 0);
    }
    public static string Temperature() {
        // Needs admin on most PCs; try anyway and fall back to "not exposed".
        try {
            using var s = new ManagementObjectSearcher(@"root\WMI", "SELECT CurrentTemperature FROM MSAcpi_ThermalZoneTemperature");
            var temps = new List<double>();
            foreach (ManagementObject o in s.Get()) temps.Add(Convert.ToDouble(o["CurrentTemperature"]) / 10.0 - 273.15);
            if (temps.Count > 0) return string.Join(", ", temps.Select(t => $"{t:0}°C"));
        } catch { }
        return "not exposed by this PC's firmware (use the manufacturer's tool or HWiNFO)";
    }
    public static string Battery() {
        try {
            var ps = System.Windows.Forms.SystemInformation.PowerStatus;
            if (ps.BatteryChargeStatus == System.Windows.Forms.BatteryChargeStatus.NoSystemBattery) return "no battery (desktop / mains)";
            var pct = (int)(ps.BatteryLifePercent * 100);
            var state = ps.PowerLineStatus == System.Windows.Forms.PowerLineStatus.Online ? "charging / plugged in" : "on battery";
            var rem = ps.BatteryLifeRemaining > 0 ? $", {ps.BatteryLifeRemaining / 60} min remaining" : "";
            return $"{pct}% ({state}{rem})";
        } catch { return "unknown"; }
    }
    public static string Disks() {
        try { return string.Join("; ", DriveInfo.GetDrives().Where(d => d.IsReady && d.DriveType == DriveType.Fixed).Select(d => $"{d.Name} {Sys.Human(d.AvailableFreeSpace)} free of {Sys.Human(d.TotalSize)}")); } catch { return "?"; }
    }
    public static string TopProcesses(int n = 6) {
        try {
            var me = Process.GetCurrentProcess().Id;
            var procs = Process.GetProcesses().Where(p => p.Id != me && p.Id != 0).ToList();
            var t0 = procs.ToDictionary(p => p.Id, p => { try { return p.TotalProcessorTime; } catch { return TimeSpan.Zero; } });
            Thread.Sleep(600);
            var rows = new List<(string name, double cpu, long mem)>();
            foreach (var p in procs) {
                try { var dt = (p.TotalProcessorTime - t0[p.Id]).TotalMilliseconds / 600.0 / Environment.ProcessorCount * 100; rows.Add((p.ProcessName, Math.Round(dt, 1), p.WorkingSet64)); } catch { }
            }
            var byCpu = rows.OrderByDescending(x => x.cpu).Take(n).Select(x => $"{x.name} {x.cpu}% {Sys.Human(x.mem)}");
            var byMem = rows.OrderByDescending(x => x.mem).Take(n).Select(x => $"{x.name} {Sys.Human(x.mem)}");
            return "top CPU: " + string.Join(", ", byCpu) + "\ntop memory: " + string.Join(", ", byMem);
        } catch (Exception e) { return "process list unavailable: " + e.Message; }
    }
    public static string Gpu() {
        try {
            using var s = new ManagementObjectSearcher("SELECT Name, AdapterRAM FROM Win32_VideoController");
            return string.Join("; ", s.Get().Cast<ManagementObject>().Select(o => o["Name"]?.ToString() ?? "?"));
        } catch { return "?"; }
    }
    public static string Summary(bool fresh = false) {
        lock (lock_) if (!fresh && (DateTime.Now - cachedAt).TotalSeconds < 20 && cached.Length > 0) return cached;
        var (tot, avail) = MemoryBytes();
        var up = TimeSpan.FromMilliseconds(Environment.TickCount64);
        var s = $"CPU {CpuPercent()}% ({Environment.ProcessorCount} logical cores); memory {Sys.Human(tot - avail)} used of {Sys.Human(tot)} ({(tot > 0 ? 100 * (tot - avail) / tot : 0)}%); disks {Disks()}; battery {Battery()}; temperature {Temperature()}; GPU {Gpu()}; uptime {up.Days}d {up.Hours}h {up.Minutes}m\n{TopProcesses()}";
        lock (lock_) { cached = s; cachedAt = DateTime.Now; }
        return s;
    }
}
