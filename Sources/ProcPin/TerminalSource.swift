import Foundation

/// Which terminal backend the list mirrors.
enum TerminalBackend: String, CaseIterable {
    case tmux
    case ghostty

    var displayName: String {
        switch self {
        case .tmux: return "tmux"
        case .ghostty: return "Ghostty"
        }
    }

    static let settingsKey = "ProcPin.source"
    static var selected: TerminalBackend {
        TerminalBackend(rawValue: UserDefaults.standard.string(forKey: settingsKey) ?? "tmux") ?? .tmux
    }
}

/// A generic "terminal surface" running a process — a tmux pane or a Ghostty
/// tab/split. The mirror turns these into the rows you see.
struct TermUnit {
    let id: String            // stable key (tmux pane id, or tty for Ghostty)
    let project: String       // group: tmux session, or Ghostty project folder
    let role: String          // window name / command
    let command: String       // current foreground command name
    let fullCommand: String   // full argv of the foreground process
    let foregroundPID: Int32
    let cwd: String?
    let tmuxPaneId: String?   // set only for tmux
}

enum TerminalSource {

    static func units(backend: TerminalBackend, rows: [ProcessManager.ProcRow]) -> [TermUnit] {
        switch backend {
        case .tmux: return tmuxUnits(rows: rows)
        case .ghostty: return ghosttyUnits(rows: rows)
        }
    }

    // MARK: - tmux

    private static func tmuxUnits(rows: [ProcessManager.ProcRow]) -> [TermUnit] {
        let panes = Tmux.rawPanesByID()
        guard !panes.isEmpty else { return [] }
        var byPID: [Int32: ProcessManager.ProcRow] = [:]
        for r in rows { byPID[r.pid] = r }

        return panes.map { (paneId, pane) in
            let fg = Tmux.resolveForegroundPID(tty: pane.tty, fallback: pane.panePID)
            let role = (!pane.windowName.isEmpty && pane.windowName != pane.currentCommand)
                ? pane.windowName : pane.currentCommand
            return TermUnit(
                id: paneId,
                project: pane.session,
                role: role,
                command: pane.currentCommand,
                fullCommand: byPID[fg]?.command ?? pane.currentCommand,
                foregroundPID: fg,
                cwd: pane.currentPath.isEmpty ? nil : pane.currentPath,
                tmuxPaneId: paneId
            )
        }
    }

    // MARK: - Ghostty

    /// Ghostty has no CLI, so we infer its surfaces from the process tree: each
    /// shell with a controlling tty whose ancestor is the Ghostty app is a
    /// tab/split. We track the foreground process on that tty.
    private static func ghosttyUnits(rows: [ProcessManager.ProcRow]) -> [TermUnit] {
        var byPID: [Int32: ProcessManager.ProcRow] = [:]
        for r in rows { byPID[r.pid] = r }

        let ghosttyPIDs = Set(rows.filter { $0.name.lowercased() == "ghostty" }.map { $0.pid })
        guard !ghosttyPIDs.isEmpty else { return [] }

        func hasGhosttyAncestor(_ pid: Int32) -> Bool {
            var cur = byPID[pid]?.ppid ?? 0
            var hops = 0
            while cur > 1, hops < 64 {
                if ghosttyPIDs.contains(cur) { return true }
                cur = byPID[cur]?.ppid ?? 0
                hops += 1
            }
            return false
        }

        let shells: Set<String> = ["login", "fish", "-fish", "zsh", "-zsh", "bash", "-bash",
                                    "sh", "-sh", "dash", "-dash", "nu", "-nu"]
        var seenTTY = Set<String>()
        var units: [TermUnit] = []
        for r in rows where r.tty != "??" && !r.tty.isEmpty {
            guard shells.contains(r.name.lowercased()), hasGhosttyAncestor(r.pid) else { continue }
            let ttyNorm = normalizeTTY(r.tty)
            guard seenTTY.insert(ttyNorm).inserted else { continue }
            let fg = Tmux.resolveForegroundPID(tty: "/dev/\(ttyNorm)", fallback: r.pid)
            let fgRow = byPID[fg]
            let cmd = fgRow?.name ?? r.name
            let cwd = Agents.resolveCwd(ofPID: fg)
            let project = cwd.map { ($0 as NSString).lastPathComponent } ?? "Ghostty"
            units.append(TermUnit(
                id: ttyNorm,
                project: project,
                role: cmd,
                command: cmd,
                fullCommand: fgRow?.command ?? cmd,
                foregroundPID: fg,
                cwd: cwd,
                tmuxPaneId: nil
            ))
        }
        return units
    }

    /// ps prints the tty as e.g. "s004"; normalize to "ttys004".
    private static func normalizeTTY(_ tty: String) -> String {
        tty.hasPrefix("tty") ? tty : "tty\(tty)"
    }
}
