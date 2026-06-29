import AppKit

/// Best-effort raising of the GUI terminal that hosts a given tty, so that
/// "jump to pane" actually brings the right window forward.
///
/// We find a process on the tty, walk up the parent chain until we hit a known
/// terminal application, and activate it by pid.
enum Focus {

    /// Process names (argv0 basenames) of common macOS terminals.
    private static let terminalNames: Set<String> = [
        "iterm2", "iterm", "terminal", "ghostty", "wezterm-gui", "wezterm",
        "alacritty", "kitty", "hyper", "warp", "tabby", "rio", "wave", "termius"
    ]

    /// Activates the terminal app hosting `tty`. If the user picked a specific
    /// terminal in Settings, that app is activated directly; otherwise we walk
    /// the tty's process ancestry to find the hosting terminal.
    @MainActor
    static func raiseTerminal(tty: String?) {
        // 1. Honor an explicit terminal choice from Settings.
        if let bundleID = Terminals.bundleID(forID: Terminals.selectedID) {
            let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            if let app = running.first {
                app.activate(options: [.activateIgnoringOtherApps])
                return
            }
            // Chosen terminal isn't running; fall through to auto-detect.
        }

        // 2. Auto-detect by walking the tty's process ancestry.
        guard let tty, !tty.isEmpty else { return }
        let pids = ProcessManager.pids(onTTY: tty)
        guard !pids.isEmpty else { return }

        let rows = ProcessManager.listAllDetailed()
        let byPID = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0) })

        for start in pids {
            var cur: Int32 = start
            var hops = 0
            while cur > 1, hops < 64 {
                guard let row = byPID[cur] else { break }
                let name = row.name.lowercased()
                if terminalNames.contains(name)
                    || terminalNames.contains(where: { name.contains($0) }) {
                    NSRunningApplication(processIdentifier: cur)?
                        .activate(options: [.activateIgnoringOtherApps])
                    return
                }
                cur = row.ppid
                hops += 1
            }
        }
    }
}
