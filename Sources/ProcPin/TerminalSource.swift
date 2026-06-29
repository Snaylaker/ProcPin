import Foundation

/// A live tmux pane surfaced in the UI.
struct TermUnit {
    let id: String            // tmux pane id, e.g. %7
    let project: String       // tmux session
    let role: String          // window name / command
    let command: String       // foreground command name
    let fullCommand: String   // full argv of the foreground process
    let foregroundPID: Int32
    let cwd: String?
    let tmuxPaneId: String?
}

enum TerminalSource {
    static func units(rows: [ProcessManager.ProcRow]) -> [TermUnit] {
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
}
