# ProcPin

A native macOS menu bar app to **pin processes**, see **how long they've been running**, and **restart or kill** them in a couple of clicks.

No Dock icon, no window — just a pin icon in the top bar with a dropdown.

## Features

- 📌 Pin any running process from a picker, or pin a shell command you run on the spot
- ⏱️ Live uptime for each pinned process (`3d 4h`, `2h 13m`, `5m 02s`, …)
- 🟢 / 🔴 running / not-running indicator
- 🔁 Restart (graceful kill + relaunch from the original command line)
- ⛔ Kill (SIGTERM) and Force Kill (SIGKILL)
- 💾 Pins persist across restarts (`~/Library/Application Support/ProcPin/pins.json`)

## Requirements

- macOS 13+
- Swift toolchain (`swift --version`) — ships with Xcode / Command Line Tools

## Build & Run

Package a double-clickable app:

```bash
./Scripts/build-app.sh
open build/ProcPin.app
```

Or run directly during development:

```bash
swift run
```

The pin icon appears in the menu bar (top-right). Click it to open the dropdown.

## Usage

- **Pin a Process** → choose from the newest running processes.
- **Pin by Command…** (⌘N) → type a shell command; ProcPin runs it and tracks it.
- Hover a pinned process to **Restart**, **Kill**, **Force Kill**, or **Unpin**.

## Notes / limitations (v1)

- Restart relaunches via `/bin/sh -lc "<command>"`. Commands that depend on a
  specific working directory may need that directory set (captured working
  directories are supported in the model and will be wired into the picker next).
- PID reuse is guarded by comparing the recorded process start time.
- The app is ad-hoc signed. On first launch you may need to allow it in
  System Settings → Privacy & Security.

## Project layout

```
Sources/ProcPin/
  main.swift            # menu-bar-only app bootstrap (.accessory policy)
  AppDelegate.swift     # status item + dropdown menu + actions
  ProcessManager.swift  # ps/kill integration: list, uptime, kill, restart
  PinnedProcess.swift   # data model + live status
  Store.swift           # JSON persistence
Scripts/build-app.sh    # packages build/ProcPin.app
```

## Roadmap

- Cross-platform: a Windows (tray) and Linux (AppIndicator) version
- Working-directory capture in the picker
- Auto-restart on crash, CPU/memory display, notifications
