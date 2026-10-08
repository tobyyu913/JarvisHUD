# JarvisHUD

A macOS menu bar app that replaces Siri with a J.A.R.V.I.S.-style HUD, backed by Gemini, plus a full-screen telemetry overlay with live sensors and fan control.

## Features

- **⌥ Space / F5** — summon the HUD in the top-right corner: a spinning Iron Man ring, a panel that expands leftward, and a text field. Ask anything; JARVIS answers in character (dry British wit, "sir", short status-readout replies).
- **⌃⌥ Space** — toggle the telemetry overlay around the screen edges: per-core CPU, memory, swap, disk, load, top processes, network throughput, battery, and SMC sensors (both fans in rpm, CPU/GPU/battery/SSD/ambient temperatures). Adapts to full-screen Spaces.
- **Fan control** — from the ◎ menu (Automatic / fixed rpm / Maximum) or just ask JARVIS ("spin the fans up to 4000"). Uses a small setuid helper installed once with an admin prompt. Fans revert to automatic on quit.
- Live Mac telemetry is attached to every Gemini request, so "how's the machine running?" gets real numbers.

## Build

```sh
./build.sh
open build/JarvisHUD.app
```

Requires Xcode command line tools. Edit the `SIGN` identity in `build.sh` to your own Apple Development certificate (ad-hoc signing works too, but macOS will re-ask for permissions after every rebuild).

## Setup

1. Grant **Accessibility** and **Input Monitoring** when prompted, then relaunch.
2. ◎ menu → *Set Gemini API Key…* (from aistudio.google.com/apikey). Default model: `gemini-2.5-flash`.
3. Optional: ◎ → Fans → *Install Fan Control Helper…*
4. If you use F5, set Siri's keyboard shortcut to Off in System Settings so they don't fight.

Tested on an M4 Max MacBook Pro, macOS 27. Temperature key names vary by chip; see `tempKeys` in `Sources/Stats.swift`.

## Layout

- `Sources/main.swift` — app, hotkeys, chat HUD, Gemini client, JARVIS persona prompt, fan control bridge
- `Sources/Overlay.swift` — edge telemetry overlay
- `Sources/Stats.swift` — SMC reader/writer and system metrics
- `Helper/main.swift` — `jarvisfan` setuid helper
