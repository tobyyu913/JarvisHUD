# JarvisHUD for Windows

The same J.A.R.V.I.S. as the Mac app, as a tray app for Windows 10/11.

**Install:** download `JarvisHUD-win-x64.zip` (or `-arm64` for Snapdragon PCs) from the
[latest release](https://github.com/tobyyu913/JarvisHUD/releases), unzip anywhere, run `JarvisHUD.exe`.
Windows SmartScreen will warn once because the exe is not signed: *More info → Run anyway*.
Then right-click the ◎ tray icon → **AI Provider…** and paste an API key (Groq is free, Aliyun 百炼 works in China).

| Key | Does |
|---|---|
| **Alt+Space** | open / close JARVIS (falls back to **Win+J** if another app owns Alt+Space) |
| **Ctrl+Alt+Space** | telemetry overlay |
| Enter / Esc | confirm / cancel a risky action |

**What he can do on Windows**: run PowerShell, open apps and settings pages, read/write files, web search, live telemetry
(CPU, memory, disks, battery, GPU, temperature where the firmware exposes it), clipboard, remember notes, recall what
was said in the room (wake word on), diagnose a slow or broken PC (event logs, startup apps, disk health, network, updates,
Defender), deep-check one app, three-tier disk clean-up (Recycle Bin, temp, crash dumps, old installers, caches of
browsers / npm / pip / NuGet / Gradle / shader caches…, never your documents), find and install apps (Microsoft Store,
winget, GitHub; every installer is checked with Authenticode, Microsoft Defender and optionally VirusTotal before it runs),
a malware sweep (Run keys, Startup folders, scheduled tasks, services, running processes, hidden folders, disguised
documents, Defender exclusions, hosts file, Winlogon/IFEO hijacks) with a reversible quarantine folder, and automatic vetting
of every new download in Downloads/Desktop.

**Wake word**: uses Windows' built-in offline speech recognition. Tick languages under *Wake Word Languages*; a language
only works if Windows has its speech pack (Settings → Time & language → Speech). English is on every Windows; Chinese,
Japanese and others need the pack installed once.

**Where things live**: `%APPDATA%\JarvisHUD` — `settings.json`, `history.json` (chat memory), `notes.json`,
`heard\` (14 days of transcripts), `quarantine\`, `downloads\` (staged installers), `debug.log`.

**Build it yourself** (Windows, .NET 8 SDK): `cd windows; .\build.ps1`. The code also compiles on macOS/Linux with
`dotnet build -r win-x64` (EnableWindowsTargeting), which is how it is compile-checked; it only runs on Windows.

Not ported: fan control (no SMC on PCs; use the manufacturer's tool) and AppleScript (PowerShell covers it).
