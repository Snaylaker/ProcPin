# ProcPin

A native macOS menu bar app to **pin processes**, group them by **project**, see **how long they've been running** plus their **CPU / memory capacity**, and **restart or kill** them in a couple of clicks.

No Dock icon, no window — just a pin icon in the top bar with a rich SwiftUI dropdown.

## Features

- 📌 Pin any running process, or run a shell command on the spot and track it
- 🗂️ **Projects**: group processes (e.g. *Project One* → Frontend / Backend) with a per-project capacity summary
- 🔎 **Search** across project, role, name, and command
- 🧩 **Auto-detect tmux**: one click imports your tmux sessions — each session becomes a project, each pane is tracked by its window/command (foreground process resolved automatically)
- 🤖 **Agents tab**: auto-detects running AI coding agents (Claude Code, OpenCode, Codex, Aider, Gemini, Goose, pi) and shows the **live process tree** each one spawned (MCP servers, running commands, sub-agents) — kill any node or pin it into a project
- 📝 **Current task**: for Claude Code, shows what each agent is *working on right now* (latest prompt from its active session transcript)
- ⏱️ Live uptime (`3d 4h`, `2h 13m`, `5m 02s`, …)
- 📊 **Capacity hint**: CPU meter + memory per process, aggregated per project
- 🟢 / 🔴 running indicator, refreshed live while open
- 🔁 Restart (graceful kill + relaunch) · ⛔ Kill (SIGTERM) · 💀 Force Kill (SIGKILL)
- 💾 Pins persist (`~/Library/Application Support/ProcPin/pins.json`)

## Requirements

- macOS 13+
- Swift toolchain (`swift --version`) — ships with Xcode / Command Line Tools
- tmux (optional) — only for the tmux auto-detect feature

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

The pin icon appears in the menu bar (top-right). Click it to open the panel.

## Usage

Click **Add** to open the assign screen, which has three modes:

- **Pick Running** — searchable list of live processes; assign a project + role.
- **Run Command** — type a shell command; ProcPin launches and tracks it.
- **tmux** — click *Detect tmux Sessions* to import panes. Sessions map to
  projects and window names to roles; multi-select and track them all at once.

In the list, each process shows uptime + a CPU/memory meter. Hover a row to
**Restart** or **Kill**; the **⋯** menu has Force Kill, *Edit Project / Role*,
**Kill & Remove**, and *Unpin (keep running)*.

For a process pinned from tmux, **Kill & Remove** becomes **Kill & Close tmux
Pane** — it runs `tmux kill-pane` to close the originating pane (which also
stops the process) and removes it from the list. For non-tmux processes it
force-kills the process and removes the pin. **Unpin (keep running)** only drops
it from ProcPin's list without touching the process.

## How tmux detection works

`Tmux.detect()` runs `tmux list-panes -a` and, for each pane, resolves the
**foreground process** on the pane's tty (skipping the shell) so you track the
actual dev server rather than the shell. It falls back to the pane's shell PID
when no foreground command is found. The tmux binary is located via a login
shell so Homebrew paths work even when launched from Finder.

## Notes / limitations

- Restart relaunches via `/bin/sh -lc "<command>"` in the captured working
  directory (tmux panes capture `pane_current_path`).
- PID reuse is guarded by comparing the recorded process start time.
- The app is ad-hoc signed. On first launch you may need to allow it in
  System Settings → Privacy & Security.

## Project layout

```
Sources/ProcPin/
  main.swift            # menu-bar-only app bootstrap (.accessory policy)
  AppDelegate.swift     # status item + NSPopover hosting SwiftUI
  RootView.swift        # main panel: search, project cards, rows, actions
  AssignView.swift      # add/edit screen: pick / command / tmux modes
  Components.swift      # reusable views (meters, badges, status dot)
  AppState.swift        # observable view model + refresh loop + formatting
  ProcessManager.swift  # ps/kill integration: list, uptime, CPU/mem, restart
  Tmux.swift            # tmux session/pane detection + foreground PID resolve
  Agents.swift          # AI agent detection + process-tree builder
  AgentsView.swift      # live agent process-tree UI
  AgentTask.swift       # current-task reader (Claude Code transcript adapter)
  PinnedProcess.swift   # data model + live status
  Store.swift           # JSON persistence
Scripts/build-app.sh    # packages build/ProcPin.app
Scripts/make-dmg.sh     # packages build/ProcPin-<version>.dmg
```

## Agents tab — how it works

Agent detection is **tool-agnostic**: an agent is just a process, and the
commands / MCP servers / sub-agents it runs are its OS **child processes**.
`Agents.scan()` lists every process with its parent pid, identifies roots by
command signature (`claude`, `opencode`, `codex`, `aider`, `gemini`, `goose`,
`pi`), then walks the parent→child map to build each tree. Nested sub-agents
appear inside their parent's tree (deduped by ancestor check).

Note: this shows what an agent is running **right now** — short-lived tool
commands that already exited won't appear (that history lives in each tool's
session transcript, e.g. `~/.claude/projects/*.jsonl`).

### Current task

For each agent ProcPin resolves the working directory via `lsof`, then (for
Claude Code) finds the most-recently-modified transcript under
`~/.claude/projects/<encoded-cwd>/` and **tail-reads** it to extract the latest
genuine user prompt (slash-command and tool-result noise is filtered out).
Other tools that store sessions differently (e.g. OpenCode's SQLite DB) are not
yet wired up for task text.

## Roadmap

- Cross-platform: a Windows (tray) and Linux (AppIndicator) version
- Auto-restart on crash, notifications, CPU/memory history sparklines
- Drag-to-reorder projects and processes
