import Foundation

/// Detects tmux sessions / windows / panes and the process running in each
/// pane, so the user can quickly pin a whole project's processes.
///
/// A tmux *session* maps naturally to a "project", and each *window* (or the
/// pane's current command) maps to a "role" such as Frontend / Backend.
enum Tmux {

    struct Pane: Identifiable {
        var id: String { paneId }
        let session: String
        let windowIndex: String
        let windowName: String
        let paneIndex: String
        let paneId: String        // tmux pane id, e.g. "%3"
        let panePID: Int32        // shell pid of the pane
        let tty: String           // e.g. /dev/ttys003
        let currentCommand: String
        let currentPath: String
        /// PID we should actually track (foreground process if resolvable,
        /// otherwise the pane's shell pid).
        let trackPID: Int32

        /// Best display name for the running process.
        var name: String { currentCommand }
        /// Suggested role: window name if meaningful, else the command.
        var suggestedRole: String {
            if !windowName.isEmpty && windowName != currentCommand { return windowName }
            return currentCommand
        }
    }

    enum DetectError: Error, CustomStringConvertible {
        case notInstalled
        case noServer
        case failed(String)

        var description: String {
            switch self {
            case .notInstalled: return "tmux is not installed (or not on PATH)."
            case .noServer: return "No tmux server is running."
            case .failed(let m): return m
            }
        }
    }

    /// Resolves the tmux binary path using a login shell so Homebrew paths
    /// (e.g. /opt/homebrew/bin) are found even when launched from Finder.
    private static func tmuxPath() -> String? {
        guard let out = run("/bin/sh", ["-lc", "command -v tmux"]),
              case let path = out.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        return path
    }

    /// Returns true if tmux is installed.
    static var isInstalled: Bool { tmuxPath() != nil }

    /// Closes a tmux pane (which also kills whatever runs inside it). If the
    /// pane is the last in its window/session, tmux closes those too.
    @discardableResult
    static func killPane(_ paneId: String) -> Bool {
        guard let tmux = tmuxPath() else { return false }
        return runFull(tmux, ["kill-pane", "-t", paneId]).status == 0
    }

    /// Kills an entire tmux session by name (closes all its windows/panes and
    /// the processes inside them).
    @discardableResult
    static func killSession(_ name: String) -> Bool {
        guard let tmux = tmuxPath(), !name.isEmpty else { return false }
        return runFull(tmux, ["kill-session", "-t", name]).status == 0
    }

    /// Whether a tmux session with the given name currently exists.
    static func sessionExists(_ name: String) -> Bool {
        guard let tmux = tmuxPath(), !name.isEmpty else { return false }
        // Exact-name match: list sessions and compare (has-session matches prefixes).
        let r = runFull(tmux, ["list-sessions", "-F", "#{session_name}"])
        guard r.status == 0 else { return false }
        return r.stdout.split(separator: "\n").contains { $0 == Substring(name) }
    }

    /// Focuses a pane: selects its window + pane and switches the attached
    /// client to its session. Returns the client tty that now shows it (if any),
    /// so the caller can raise the hosting terminal window.
    @discardableResult
    static func focusPane(_ paneId: String) -> String? {
        guard let tmux = tmuxPath(), !paneId.isEmpty else { return nil }
        _ = runFull(tmux, ["select-window", "-t", paneId])
        _ = runFull(tmux, ["select-pane", "-t", paneId])
        _ = runFull(tmux, ["switch-client", "-t", paneId])
        return clientTTY(forPane: paneId)
    }

    /// The tty of an attached client viewing the pane's session, if any.
    static func clientTTY(forPane paneId: String) -> String? {
        guard let tmux = tmuxPath(), !paneId.isEmpty else { return nil }
        let sess = runFull(tmux, ["display-message", "-p", "-t", paneId, "#{session_name}"])
            .stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sess.isEmpty else { return nil }
        let clients = runFull(tmux, ["list-clients", "-F", "#{client_session}\t#{client_tty}"])
        guard clients.status == 0 else { return nil }
        for line in clients.stdout.split(separator: "\n") {
            let f = line.components(separatedBy: "\t")
            if f.count == 2, f[0] == sess, !f[1].isEmpty {
                return f[1]
            }
        }
        return nil
    }

    /// Lists all panes across all sessions, with the tracked process resolved.
    static func detect() -> Result<[Pane], DetectError> {
        guard let tmux = tmuxPath() else { return .failure(.notInstalled) }

        // Use a tab-delimited format that's easy to split.
        let fmt = [
            "#{session_name}",
            "#{window_index}",
            "#{window_name}",
            "#{pane_index}",
            "#{pane_id}",
            "#{pane_pid}",
            "#{pane_tty}",
            "#{pane_current_command}",
            "#{pane_current_path}"
        ].joined(separator: "\t")

        let result = runFull(tmux, ["list-panes", "-a", "-F", fmt])
        if result.status != 0 {
            let err = result.stderr.lowercased()
            if err.contains("no server running") || err.contains("no current") {
                return .failure(.noServer)
            }
            return .failure(.failed(result.stderr.isEmpty ? "tmux returned status \(result.status)" : result.stderr))
        }

        var panes: [Pane] = []
        for line in result.stdout.split(separator: "\n") {
            let f = line.components(separatedBy: "\t")
            guard f.count >= 9, let panePID = Int32(f[5]) else { continue }
            let tty = f[6]
            let trackPID = foregroundPID(tty: tty, fallback: panePID)
            panes.append(Pane(
                session: f[0],
                windowIndex: f[1],
                windowName: f[2],
                paneIndex: f[3],
                paneId: f[4],
                panePID: panePID,
                tty: tty,
                currentCommand: f[7],
                currentPath: f[8],
                trackPID: trackPID
            ))
        }
        return .success(panes)
    }

    /// Lightweight pane snapshot (no foreground resolution), for live syncing.
    struct RawPane {
        let session: String
        let windowName: String
        let paneId: String
        let panePID: Int32
        let tty: String
        let currentCommand: String
        let currentPath: String
    }

    /// Lists all panes with one tmux call (no per-pane ps), keyed by pane id.
    static func rawPanesByID() -> [String: RawPane] {
        guard let tmux = tmuxPath() else { return [:] }
        let fmt = ["#{session_name}", "#{window_name}", "#{pane_id}", "#{pane_pid}",
                   "#{pane_tty}", "#{pane_current_command}", "#{pane_current_path}"]
            .joined(separator: "\t")
        let r = runFull(tmux, ["list-panes", "-a", "-F", fmt])
        guard r.status == 0 else { return [:] }
        var map: [String: RawPane] = [:]
        for line in r.stdout.split(separator: "\n") {
            let f = line.components(separatedBy: "\t")
            guard f.count >= 7, let pid = Int32(f[3]) else { continue }
            map[f[2]] = RawPane(session: f[0], windowName: f[1], paneId: f[2],
                                panePID: pid, tty: f[4], currentCommand: f[5], currentPath: f[6])
        }
        return map
    }

    /// Resolves the foreground (tracked) pid for a pane tty.
    static func resolveForegroundPID(tty: String, fallback: Int32) -> Int32 {
        foregroundPID(tty: tty, fallback: fallback)
    }

    /// Captures recent output from a pane (the last `lines` rows of scrollback
    /// plus the visible screen). Returns nil if tmux/pane is unavailable.
    static func capturePane(_ paneId: String, lines: Int = 50) -> String? {
        guard let tmux = tmuxPath(), !paneId.isEmpty else { return nil }
        let r = runFull(tmux, ["capture-pane", "-p", "-t", paneId, "-S", "-\(lines)"])
        return r.status == 0 ? r.stdout : nil
    }

    /// Restarts whatever runs in a pane: interrupts the current process (C-c),
    /// then re-runs the previous command from shell history (Up, Enter).
    @discardableResult
    static func restartPane(_ paneId: String) -> Bool {
        guard let tmux = tmuxPath(), !paneId.isEmpty else { return false }
        _ = runFull(tmux, ["send-keys", "-t", paneId, "C-c"])
        usleep(350_000)
        return runFull(tmux, ["send-keys", "-t", paneId, "Up", "Enter"]).status == 0
    }

    /// Sends Ctrl-C to a pane (graceful interrupt of the foreground process).
    @discardableResult
    static func interruptPane(_ paneId: String) -> Bool {
        guard let tmux = tmuxPath(), !paneId.isEmpty else { return false }
        return runFull(tmux, ["send-keys", "-t", paneId, "C-c"]).status == 0
    }

    /// Finds the foreground process on a tty (the one running in the pane),
    /// falling back to the pane's shell pid. Shells are skipped so we track the
    /// actual dev server / command when present.
    private static func foregroundPID(tty: String, fallback: Int32) -> Int32 {
        // ps wants the tty name without the /dev/ prefix.
        let dev = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
        guard let out = run("/bin/ps", ["-t", dev, "-o", "pid=,stat=,comm="]) else {
            return fallback
        }
        let shells: Set<String> = ["sh", "-sh", "bash", "-bash", "zsh", "-zsh",
                                    "fish", "-fish", "login", "tmux"]
        var best: Int32?
        for line in out.split(separator: "\n") {
            let parts = line.trimmingCharacters(in: .whitespaces)
                .split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard parts.count >= 3, let pid = Int32(parts[0]) else { continue }
            let stat = parts[1]
            let comm = (parts[2...].joined(separator: " ") as NSString).lastPathComponent
            // '+' in stat means the process is in the foreground process group.
            guard stat.contains("+") else { continue }
            if shells.contains(comm.lowercased()) { continue }
            // Prefer the most recently started (highest pid) non-shell foreground proc.
            if let b = best { if pid > b { best = pid } } else { best = pid }
        }
        return best ?? fallback
    }

    // MARK: - Process runners

    private static func run(_ path: String, _ args: [String]) -> String? {
        let r = runFull(path, args)
        return r.status == 0 ? r.stdout : (r.stdout.isEmpty ? nil : r.stdout)
    }

    private static func runFull(_ path: String, _ args: [String]) -> (status: Int32, stdout: String, stderr: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        task.standardOutput = outPipe
        task.standardError = errPipe
        do {
            try task.run()
        } catch {
            return (-1, "", "\(error.localizedDescription)")
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return (
            task.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? ""
        )
    }
}
