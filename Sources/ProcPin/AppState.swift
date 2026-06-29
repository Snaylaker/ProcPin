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

    /// Rebuilds the list directly from live tmux panes (no manual pinning), then
    /// computes status — sharing a single `ps` snapshot between the two.
    func refresh() {
        let existing = pins
        work.async {
            let rows = ProcessManager.listAllDetailed()
            let mirrored = Self.mirrorFromTmux(existing: existing, rows: rows)
            let newStatuses = ProcessManager.statuses(for: mirrored, rows: rows)
            Task { @MainActor in
                self.pins = mirrored
                self.statuses = newStatuses
            }
        }
        if scanAgentsEnabled { scanAgents() }
    }

    /// Builds the pin list from every live tmux pane. Reuses each existing pin's
    /// UUID (keyed by pane id) so SwiftUI identity and fold state stay stable.
    private static func mirrorFromTmux(existing: [PinnedProcess], rows: [ProcessManager.ProcRow]) -> [PinnedProcess] {
        let panes = Tmux.rawPanesByID()
        guard !panes.isEmpty else { return [] }

        var byPID: [Int32: ProcessManager.ProcRow] = [:]
        for r in rows { byPID[r.pid] = r }
        var idByPane: [String: UUID] = [:]
        for p in existing { if let pane = p.tmuxPaneId { idByPane[pane] = p.id } }

        var result: [PinnedProcess] = []
        for (paneId, pane) in panes {
            let fg = Tmux.resolveForegroundPID(tty: pane.tty, fallback: pane.panePID)
            let row = byPID[fg]
            let role = (!pane.windowName.isEmpty && pane.windowName != pane.currentCommand)
                ? pane.windowName : pane.currentCommand
            result.append(PinnedProcess(
                id: idByPane[paneId] ?? UUID(),
                pid: fg,
                name: pane.currentCommand,
                command: row?.command ?? pane.currentCommand,
                workingDirectory: pane.currentPath.isEmpty ? nil : pane.currentPath,
                observedStartEpoch: row?.startDate.timeIntervalSince1970,
                project: pane.session,
                role: role,
                tmuxPaneId: paneId
            ))
        }
        // Sort by session, then pane number for stable ordering.
        func paneNum(_ id: String?) -> Int { Int(id?.replacingOccurrences(of: "%", with: "") ?? "") ?? 0 }
        return result.sorted { a, b in
            if a.project != b.project {
                return a.project.localizedCaseInsensitiveCompare(b.project) == .orderedAscending
            }
            return paneNum(a.tmuxPaneId) < paneNum(b.tmuxPaneId)
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
            ProcessManager.kill(pid: pin.pid, force: true)
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

    /// Closes every pane in a project (which stops its processes).
    func killProjectAndRemove(_ project: String) {
        for pin in pins where pin.project == project {
            if let paneId = pin.tmuxPaneId, !paneId.isEmpty {
                Tmux.killPane(paneId)
            } else {
                ProcessManager.kill(pid: pin.pid, force: true)
            }
        }
        pins.removeAll { $0.project == project }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh() }
    }

    func kill(_ id: UUID, force: Bool) {
        guard let pin = pins.first(where: { $0.id == id }) else { return }
        if let paneId = pin.tmuxPaneId, !paneId.isEmpty, !force {
            // Graceful stop inside the pane (Ctrl-C) for tmux processes.
            Tmux.interruptPane(paneId)
        } else {
            ProcessManager.kill(pid: pin.pid, force: force)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh() }
    }

    /// Suspend (pause) or resume a single pinned process (whole subtree).
    func setPaused(_ id: UUID, paused: Bool) {
        guard let pin = pins.first(where: { $0.id == id }) else { return }
        if paused { ProcessManager.suspendTree(pin.pid) }
        else { ProcessManager.resumeTree(pin.pid) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.refresh() }
    }

    /// Suspend (pause) or resume every process in a project (each subtree).
    func setProjectPaused(_ project: String, paused: Bool) {
        for pin in pins where pin.project == project {
            if paused { ProcessManager.suspendTree(pin.pid) }
            else { ProcessManager.resumeTree(pin.pid) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.refresh() }
    }

    /// Number of running/paused processes in a project (for menu state).
    func projectPausedCount(_ project: String) -> (paused: Int, running: Int) {
        var paused = 0, running = 0
        for pin in pins where pin.project == project {
            guard let s = statuses[pin.id], s.isRunning else { continue }
            running += 1
            if s.isPaused { paused += 1 }
        }
        return (paused, running)
    }

    func restart(_ id: UUID) {
        guard let pin = pins.first(where: { $0.id == id }),
              let paneId = pin.tmuxPaneId, !paneId.isEmpty else { return }
        // Restart inside the tmux pane (Ctrl-C + re-run last command).
        Tmux.restartPane(paneId)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refresh() }
    }

    /// Focuses the tmux pane a process runs in and raises its terminal window.
    func jumpToPane(_ id: UUID) {
        guard let pin = pins.first(where: { $0.id == id }),
              let paneId = pin.tmuxPaneId, !paneId.isEmpty else { return }
        work.async {
            let tty = Tmux.focusPane(paneId)
            Task { @MainActor in Focus.raiseTerminal(tty: tty) }
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
