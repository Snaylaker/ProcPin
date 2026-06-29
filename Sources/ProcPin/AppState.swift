import Foundation
import Combine
import AppKit

/// Single source of truth for the UI. Holds pinned processes, refreshes their
/// live status on a timer, and exposes actions (pin / unpin / kill / restart).
@MainActor
final class AppState: ObservableObject {
    /// All pins, in user order.
    @Published private(set) var pins: [PinnedProcess] = []
    /// Latest computed status keyed by pin id.
    @Published private(set) var statuses: [UUID: ProcessStatus] = [:]
    /// Detected AI agents and their process trees (only scanned when enabled).
    @Published private(set) var agents: [Agents.Agent] = []

    // Update checking.
    enum UpdateState: Equatable { case unknown, checking, upToDate, available(Updater.Release), downloading, failed(String) }
    @Published var updateState: UpdateState = .unknown
    private var didAutoCheckUpdates = false

    private var timer: Timer?
    private var scanAgentsEnabled = false
    private let work = DispatchQueue(label: "com.procpin.refresh", qos: .userInitiated)

    init() {
        // The list is mirrored live from tmux; nothing is persisted.
        refresh()
    }

    // MARK: - Derived data

    /// Distinct project names currently in use, sorted, with "" (ungrouped) last.
    var projectNames: [String] {
        let set = Set(pins.map { $0.project })
        return set.sorted { a, b in
            if a.isEmpty != b.isEmpty { return !a.isEmpty } // non-empty first
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }

    /// Pins grouped by project, honoring an optional search filter.
    func groupedPins(filter: String) -> [(project: String, pins: [PinnedProcess])] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        let filtered = pins.filter { pin in
            guard !q.isEmpty else { return true }
            return pin.name.lowercased().contains(q)
                || pin.role.lowercased().contains(q)
                || pin.project.lowercased().contains(q)
                || pin.command.lowercased().contains(q)
        }
        var groups: [String: [PinnedProcess]] = [:]
        for pin in filtered { groups[pin.project, default: []].append(pin) }
        return groups
            .map { (project: $0.key, pins: $0.value) }
            .sorted { a, b in
                if a.project.isEmpty != b.project.isEmpty { return !a.project.isEmpty }
                return a.project.localizedCaseInsensitiveCompare(b.project) == .orderedAscending
            }
    }

    /// Aggregate capacity for a project (sum of running members' CPU and memory).
    func capacity(forProject project: String) -> (cpu: Double, memory: UInt64, running: Int, total: Int) {
        let members = pins.filter { $0.project == project }
        var cpu = 0.0, mem: UInt64 = 0, running = 0
        for m in members {
            guard let s = statuses[m.id], s.isRunning else { continue }
            running += 1
            cpu += s.cpuPercent ?? 0
            mem += s.memoryBytes ?? 0
        }
        return (cpu, mem, running, members.count)
    }

    // MARK: - Lifecycle of refresh loop

    func startAutoRefresh() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        refresh()
        // Check for updates once per launch when the panel is first opened.
        if !didAutoCheckUpdates {
            didAutoCheckUpdates = true
            checkForUpdates()
        }
    }

    /// Queries GitHub Releases for a newer version (non-blocking).
    func checkForUpdates() {
        updateState = .checking
        Task { @MainActor in
            if let release = await Updater.checkForUpdate() {
                self.updateState = .available(release)
            } else {
                self.updateState = .upToDate
            }
        }
    }

    /// Downloads and installs the available update, then relaunches.
    func installUpdate() {
        guard case .available(let release) = updateState else { return }
        updateState = .downloading
        Task { @MainActor in
            let result = await Updater.installUpdate(release)
            switch result {
            case .success:
                break // app will quit and relaunch
            case .failure(let err):
                self.updateState = .failed(err.description)
                // Fall back to opening the release page after a moment.
                NSWorkspace.shared.open(release.htmlURL)
            }
        }
    }

    func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
    }

    /// Rebuilds the list directly from the selected terminal source (tmux or
    /// Ghostty), then computes status — sharing one `ps` snapshot.
    func refresh() {
        let existing = pins
        let backend = TerminalBackend.selected
        work.async {
            let rows = ProcessManager.listAllDetailed()
            let mirrored = Self.mirror(existing: existing, rows: rows, backend: backend)
            let newStatuses = ProcessManager.statuses(for: mirrored, rows: rows)
            Task { @MainActor in
                self.pins = mirrored
                self.statuses = newStatuses
            }
        }
        if scanAgentsEnabled { scanAgents() }
    }

    /// Builds the list from live terminal surfaces. Reuses each existing pin's
    /// UUID (keyed by source key) so SwiftUI identity and fold state stay stable.
    private static func mirror(existing: [PinnedProcess], rows: [ProcessManager.ProcRow],
                               backend: TerminalBackend) -> [PinnedProcess] {
        let units = TerminalSource.units(backend: backend, rows: rows)
        guard !units.isEmpty else { return [] }

        var byPID: [Int32: ProcessManager.ProcRow] = [:]
        for r in rows { byPID[r.pid] = r }
        var idByKey: [String: UUID] = [:]
        for p in existing { if let k = p.sourceKey { idByKey[k] = p.id } }

        let result = units.map { u in
            PinnedProcess(
                id: idByKey[u.id] ?? UUID(),
                pid: u.foregroundPID,
                name: u.command,
                command: u.fullCommand,
                workingDirectory: u.cwd,
                observedStartEpoch: byPID[u.foregroundPID]?.startDate.timeIntervalSince1970,
                project: u.project,
                role: u.role,
                tmuxPaneId: u.tmuxPaneId,
                sourceKey: u.id
            )
        }
        return result.sorted { a, b in
            if a.project != b.project {
                return a.project.localizedCaseInsensitiveCompare(b.project) == .orderedAscending
            }
            return (a.sourceKey ?? "") < (b.sourceKey ?? "")
        }
    }

    /// Enable/disable agent tree scanning (driven by the Agents tab).
    func setAgentScanning(_ on: Bool) {
        scanAgentsEnabled = on
        if on { scanAgents() } else { agents = [] }
    }

    /// Scan running AI agents and their process trees off the main thread.
    func scanAgents() {
        work.async {
            let found = Agents.scan()
            Task { @MainActor in self.agents = found }
        }
    }

    // MARK: - Process actions

    /// Closes the tmux pane (which stops whatever runs inside it). The list
    /// updates on the next refresh.
    func killAndRemove(_ id: UUID) {
        guard let pin = pins.first(where: { $0.id == id }) else { return }
        if let paneId = pin.tmuxPaneId, !paneId.isEmpty {
            Tmux.killPane(paneId)
        } else {
            ProcessManager.killTree(pin.pid)
        }
        pins.removeAll { $0.id == id }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh() }
    }

    // MARK: - Project-level actions

    /// Cheap, synchronous check: does the project contain tmux panes?
    func projectHasTmuxPanes(_ project: String) -> Bool {
        !project.isEmpty && pins.contains { $0.project == project && ($0.tmuxPaneId?.isEmpty == false) }
    }

    /// Kills the whole tmux session for a project.
    func killTmuxSession(_ project: String) {
        Tmux.killSession(project)
        pins.removeAll { $0.project == project }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh() }
    }

    /// Closes/stops every surface in a project.
    func killProjectAndRemove(_ project: String) {
        for pin in pins where pin.project == project {
            if let paneId = pin.tmuxPaneId, !paneId.isEmpty {
                Tmux.killPane(paneId)
            } else {
                ProcessManager.killTree(pin.pid)
            }
        }
        pins.removeAll { $0.project == project }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh() }
    }

    /// Graceful stop (force = SIGKILL). tmux uses Ctrl-C in the pane; Ghostty
    /// sends SIGINT to the foreground process group.
    func kill(_ id: UUID, force: Bool) {
        guard let pin = pins.first(where: { $0.id == id }) else { return }
        if force {
            ProcessManager.killTree(pin.pid)
        } else if let paneId = pin.tmuxPaneId, !paneId.isEmpty {
            Tmux.interruptPane(paneId)
        } else {
            ProcessManager.interrupt(pid: pin.pid)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh() }
    }

    /// Restart (tmux only): Ctrl-C + re-run the last command in the pane.
    func restart(_ id: UUID) {
        guard let pin = pins.first(where: { $0.id == id }),
              let paneId = pin.tmuxPaneId, !paneId.isEmpty else { return }
        Tmux.restartPane(paneId)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refresh() }
    }

    /// Focuses the surface: tmux switches the client + raises the terminal;
    /// Ghostty just activates the app.
    func jumpToPane(_ id: UUID) {
        guard let pin = pins.first(where: { $0.id == id }) else { return }
        if let paneId = pin.tmuxPaneId, !paneId.isEmpty {
            work.async {
                let tty = Tmux.focusPane(paneId)
                Task { @MainActor in Focus.raiseTerminal(tty: tty) }
            }
        } else {
            Focus.activateGhostty()
        }
    }

    // MARK: - Collapsed (folded) projects

    private let collapsedKey = "ProcPin.collapsedProjects"
    @Published private(set) var collapsedProjects: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: "ProcPin.collapsedProjects") ?? [])
    }()

    func isCollapsed(_ project: String) -> Bool { collapsedProjects.contains(project) }

    func toggleCollapsed(_ project: String) {
        if collapsedProjects.contains(project) {
            collapsedProjects.remove(project)
        } else {
            collapsedProjects.insert(project)
        }
        UserDefaults.standard.set(Array(collapsedProjects), forKey: collapsedKey)
    }

    // MARK: - Agent tree actions

    /// Kill any pid by number (used by the agent tree). Re-scans afterwards.
    func killPID(_ pid: Int32, force: Bool) {
        ProcessManager.kill(pid: pid, force: force)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.scanAgents()
            self?.refresh()
        }
    }
}

// MARK: - Formatting helpers

enum Format {
    /// "3d 4h", "2h 13m", "5m 02s", or "12s".
    static func uptime(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        let d = total / 86_400
        let h = (total % 86_400) / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return "\(s)s"
    }

    /// Human-readable memory: "340 MB", "1.2 GB".
    static func memory(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 {
            return String(format: "%.1f GB", mb / 1024)
        }
        return String(format: "%.0f MB", mb)
    }

    static func cpu(_ percent: Double) -> String {
        String(format: "%.0f%%", percent)
    }
}
