using System.Text.RegularExpressions;

namespace JarvisHUD;

/// Troubleshooting helpers: health snapshot, deep check of one app, event-log errors. Read-only.
static class Doctor {
    static string? osCache;
    public static string OsVersion {
        get {
            if (osCache != null) return osCache;
            try {
                var v = Sys.Ps("$o=Get-CimInstance Win32_OperatingSystem; $c=Get-CimInstance Win32_ComputerSystem; \"$($o.Caption) $($o.Version) (build $((Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion').DisplayVersion)), $($c.Manufacturer) $($c.Model), $env:PROCESSOR_ARCHITECTURE\"", 8);
                return osCache = (v.Length > 0 ? v : Environment.OSVersion.VersionString);
            } catch { return osCache = Environment.OSVersion.VersionString; }
        }
    }

    public static string Diagnose() {
        var parts = new string[8];
        Parallel.For(0, 8, i => {
            parts[i] = i switch {
                0 => "System: " + OsVersion + "\n" + Sys.Ps("$o=Get-CimInstance Win32_OperatingSystem; $up=(Get-Date)-$o.LastBootUpTime; \"Uptime: {0}d {1}h {2}m; last boot {3}\" -f $up.Days,$up.Hours,$up.Minutes,$o.LastBootUpTime; $pf=Get-CimInstance Win32_PageFileUsage; \"Page file: {0} MB used of {1} MB (peak {2} MB)\" -f $pf.CurrentUsage,$pf.AllocatedBaseSize,$pf.PeakUsage; \"Memory: {0:N1} GB free of {1:N1} GB\" -f ($o.FreePhysicalMemory/1MB),($o.TotalVisibleMemorySize/1MB)", 10),
                1 => "Top processes (CPU / memory):\n" + Stats.TopProcesses(8),
                2 => Sys.Ps("$hogs='SearchIndexer','MsMpEng','TiWorker','wuauclt','usocoreworker','OneDrive','DoSvc','CompatTelRunner','Antimalware Service Executable','svchost','MoUsoCoreWorker','dwm','SearchHost','WmiPrvSE','Memory Compression'; $p=Get-Process | Where-Object { $hogs -contains $_.ProcessName } | Sort-Object CPU -Descending | Select-Object -First 8 ProcessName,@{n='cpu_s';e={[int]$_.CPU}},@{n='mem_MB';e={[int]($_.WorkingSet64/1MB)}}; 'Known background workers (cumulative CPU seconds / memory):'; $p | Format-Table -HideTableHeaders | Out-String -Width 120; $s=Get-Service WSearch,wuauserv,DoSvc,WinDefend,SysMain -ErrorAction SilentlyContinue | ForEach-Object { \"$($_.Name)=$($_.Status)\" }; 'Services: ' + ($s -join ', '); try { $d=Get-MpComputerStatus; 'Defender scan running: ' + $d.QuickScanInProgress + '/' + $d.FullScanInProgress + ', last quick scan ' + $d.QuickScanEndTime } catch { 'Defender status unavailable' }", 20),
                3 => "Disks: " + Stats.Disks() + "\n" + Sys.Ps("try { Get-PhysicalDisk | ForEach-Object { \"{0} {1} {2} health={3} {4}GB\" -f $_.FriendlyName,$_.MediaType,$_.BusType,$_.HealthStatus,[int]($_.Size/1GB) } } catch { 'physical disk info unavailable' }; $c=Get-Counter '\\PhysicalDisk(_Total)\\% Disk Time','\\PhysicalDisk(_Total)\\Avg. Disk Queue Length' -ErrorAction SilentlyContinue; if ($c) { 'Disk busy: {0:N0}%, queue {1:N1}' -f $c.CounterSamples[0].CookedValue,$c.CounterSamples[1].CookedValue }", 15),
                4 => "Application errors / crashes in the last 24 h:\n" + Sys.Ps("$e=Get-WinEvent -FilterHashtable @{LogName='Application'; Level=1,2; StartTime=(Get-Date).AddDays(-1)} -MaxEvents 40 -ErrorAction SilentlyContinue | Where-Object { $_.ProviderName -match 'Application Error|Application Hang|Windows Error Reporting|.NET Runtime' -or $_.Id -in 1000,1001,1002 } | Select-Object -First 12 | ForEach-Object { $m=($_.Message -split \"`n\")[0..2] -join ' '; \"  {0:HH:mm} {1} {2}\" -f $_.TimeCreated,$_.ProviderName,$m.Substring(0,[Math]::Min(160,$m.Length)) }; if ($e) { $e } else { '  none' }; $k=Get-WinEvent -FilterHashtable @{LogName='System'; Id=41,1001,6008} -MaxEvents 3 -ErrorAction SilentlyContinue | ForEach-Object { \"  unexpected shutdown/BSOD: {0:yyyy-MM-dd HH:mm} id {1}\" -f $_.TimeCreated,$_.Id }; if ($k) { $k }", 25),
                5 => Sys.Ps("'Startup apps:'; Get-CimInstance Win32_StartupCommand | Select-Object -First 25 | ForEach-Object { \"  $($_.Name) [$($_.Location)]\" }; $t=Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Running' -and $_.TaskPath -notlike '\\Microsoft\\*' } | Select-Object -First 8 -ExpandProperty TaskName; if ($t) { 'Running non-Microsoft scheduled tasks: ' + ($t -join ', ') }", 20),
                6 => Sys.Ps("$ping = Test-Connection 1.1.1.1 -Count 1 -Quiet -ErrorAction SilentlyContinue; if ($ping) { 'Network: internet reachable' } else { 'Network: NO internet (ping 1.1.1.1 failed)' }; try { $null = Resolve-DnsName apple.com -ErrorAction Stop -QuickTimeout; 'DNS ok' } catch { 'DNS FAILING' }; $w = netsh wlan show interfaces 2>$null | Select-String 'SSID|Signal|Receive rate|State' | ForEach-Object { $_.ToString().Trim() }; if ($w) { 'Wi-Fi: ' + ($w -join '; ') }; $a=Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object Status -eq 'Up' | ForEach-Object { \"$($_.Name) $($_.LinkSpeed)\" }; 'Adapters up: ' + ($a -join ', ')", 20),
                _ => "Power: " + Stats.Battery() + "\n" + Sys.Ps("try { $u=(New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher().Search('IsInstalled=0 and IsHidden=0').Updates; 'Pending Windows updates: ' + $u.Count + ' (' + (($u | Select-Object -First 3 -ExpandProperty Title) -join '; ') + ')' } catch { 'Pending updates: unknown' }; $r=Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\WindowsUpdate\\Auto Update\\RebootRequired' -ErrorAction SilentlyContinue; if ($r) { 'A RESTART IS PENDING to finish updates' }; try { $d=Get-MpComputerStatus; 'Defender: realtime=' + $d.RealTimeProtectionEnabled + ', signatures ' + $d.AntivirusSignatureLastUpdated.ToString('yyyy-MM-dd') } catch {}; 'Thermal: ' + '" + Stats.Temperature().Replace("'", "") + "'", 40),
            };
        });
        return string.Join("\n\n", parts.Where(p => !string.IsNullOrWhiteSpace(p)));
    }

    public static string AppCheck(string name) {
        var q = name.Replace("'", "''").Trim();
        if (q.Length == 0) return "Which app, sir?";
        var info = Sys.Ps($@"
$q='{q}'
$apps=@()
foreach ($k in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*') {{
  $apps += Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object {{ $_.DisplayName -like ""*$q*"" }} | Select-Object DisplayName,DisplayVersion,Publisher,InstallLocation,InstallDate,DisplayIcon,UninstallString
}}
$store = Get-AppxPackage -ErrorAction SilentlyContinue | Where-Object {{ $_.Name -like ""*$q*"" }} | Select-Object -First 3 Name,Version,Publisher,InstallLocation,Architecture
if ($apps) {{ 'Installed (classic):'; $apps | Select-Object -First 3 | Format-List | Out-String -Width 160 }}
if ($store) {{ 'Installed (Microsoft Store / packaged):'; $store | Format-List | Out-String -Width 160 }}
if (-not $apps -and -not $store) {{ 'Not found in installed programs.' }}
$exe = $null
if ($apps -and $apps[0].DisplayIcon) {{ $exe = ($apps[0].DisplayIcon -split ',')[0].Trim('""') }}
if (-not $exe -and $apps -and $apps[0].InstallLocation) {{ $exe = Get-ChildItem $apps[0].InstallLocation -Filter *.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }}
if (-not $exe) {{ $p = Get-Process -ErrorAction SilentlyContinue | Where-Object {{ $_.ProcessName -like ""*$q*"" }} | Select-Object -First 1; if ($p) {{ $exe = $p.Path }} }}
if ($exe -and (Test-Path $exe)) {{
  'Executable: ' + $exe
  $s = Get-AuthenticodeSignature $exe
  'Signature: ' + $s.Status + ' ' + $(if ($s.SignerCertificate) {{ $s.SignerCertificate.Subject -replace '^CN=([^,]+).*','$1' }} else {{ '(unsigned)' }})
  $z = Get-Content -Path $exe -Stream Zone.Identifier -ErrorAction SilentlyContinue; if ($z) {{ 'Mark of the Web: downloaded from the internet (SmartScreen will check it)' }}
  $fi = Get-Item $exe; 'Version: ' + $fi.VersionInfo.FileVersion + '  size ' + [int]($fi.Length/1KB) + ' KB  modified ' + $fi.LastWriteTime
  $bytes = [IO.File]::ReadAllBytes($exe); $pe = [BitConverter]::ToInt32($bytes,60); $m=[BitConverter]::ToUInt16($bytes,$pe+4)
  'Architecture: ' + $(switch ($m) {{ 0x8664 {{'x64'}} 0x14c {{'x86 (32-bit)'}} 0xAA64 {{'ARM64'}} default {{'0x{{0:X}}' -f $m}} }}) + ' (this PC: ' + $env:PROCESSOR_ARCHITECTURE + ')'
  $r = Get-Process -ErrorAction SilentlyContinue | Where-Object {{ $_.Path -eq $exe }}; 'Running now: ' + $(if ($r) {{ ""yes, pid $($r.Id -join ','), $([int]($r[0].WorkingSet64/1MB)) MB, responding=$($r[0].Responding)"" }} else {{ 'no' }})
}}
'Recent crash / error events for it (7 days):'
$ev = Get-WinEvent -FilterHashtable @{{LogName='Application'; Level=1,2,3; StartTime=(Get-Date).AddDays(-7)}} -MaxEvents 400 -ErrorAction SilentlyContinue | Where-Object {{ $_.Message -like ""*$q*"" }} | Select-Object -First 6
if ($ev) {{ $ev | ForEach-Object {{ $m=($_.Message -split ""`n"")[0..3] -join ' '; '  {{0:yyyy-MM-dd HH:mm}} {{1}}: {{2}}' -f $_.TimeCreated,$_.ProviderName,$m.Substring(0,[Math]::Min(220,$m.Length)) }} }} else {{ '  none' }}
$wer = Get-ChildItem ""$env:LOCALAPPDATA\CrashDumps"" -ErrorAction SilentlyContinue | Where-Object {{ $_.Name -like ""*$q*"" }} | Sort-Object LastWriteTime -Descending | Select-Object -First 3
if ($wer) {{ 'Crash dumps: ' + (($wer | ForEach-Object {{ ""$($_.Name) $($_.LastWriteTime)"" }}) -join '; ') }}
", 40);
        return info;
    }

    public static string Logs(string process, int minutes, string filter) {
        var p = process.Replace("'", "''"); var f = filter.Replace("'", "''");
        return Sys.Ps($@"
$ev = Get-WinEvent -FilterHashtable @{{LogName='Application','System'; Level=1,2,3; StartTime=(Get-Date).AddMinutes(-{Math.Clamp(minutes, 1, 1440)})}} -MaxEvents 300 -ErrorAction SilentlyContinue
if ('{p}') {{ $ev = $ev | Where-Object {{ $_.ProviderName -like '*{p}*' -or $_.Message -like '*{p}*' }} }}
if ('{f}') {{ $ev = $ev | Where-Object {{ $_.Message -like '*{f}*' }} }}
$ev = $ev | Select-Object -First 30
if ($ev) {{ $ev | ForEach-Object {{ $m=($_.Message -split ""`n"")[0..2] -join ' '; '{{0:HH:mm:ss}} [{{1}}] {{2}} ({{3}}): {{4}}' -f $_.TimeCreated,$_.LevelDisplayName,$_.ProviderName,$_.Id,$m.Substring(0,[Math]::Min(200,$m.Length)) }} }} else {{ 'nothing logged' }}
", 40);
    }
}
