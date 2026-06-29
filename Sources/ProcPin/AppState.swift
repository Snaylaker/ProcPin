import Foundation
import Combine

/// Single source of truth for the UI. Holds pinned processes, refreshes their
/// live status on a timer, and exposes actions (pin / unpin / kill / restart).
@MainActor
final class AppState: ObservableObject {
    /// All pins, in user order.
    @Published private(set) var pins: [PinnedProcess] = []
    /// Latest computed status keyed by pin id.
    @Published private(set) var statuses: [UUID: ProcessStatus] = [:]
    /// Live processes available to pin (refreshed when the picker opens).
    @Published private(set) var liveProcesses: [ProcessManager.LiveProcess] = []
    /// Detected AI agents and their process trees (only scanned when enabled).
    @Published private(set) var agents: [Agents.Agent] = []

    private var timer: Timer?
    private var scanAgentsEnabled = false
    private let work = DispatchQueue(label: "com.procpin.refresh", qos: .userInitiated)

    init() {
        pins = Store.shared.load()
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
    }

    func stopAutoRefresh() {
        timer?.invalidate()
        timer = nil
    }

    /// Recompute statuses off the main thread (ps calls are blocking).
    func refresh() {
        let snapshot = pins
        work.async {
            var newStatuses: [UUID: ProcessStatus] = [:]
            for pin in snapshot {
                newStatuses[pin.id] = ProcessManager.status(for: pin)
            }
            Task { @MainActor in self.statuses = newStatuses }
        }
        if scanAgentsEnabled { scanAgents() }
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

    /// Refresh the list of live processes for the picker.
    func refreshLiveProcesses() {
        work.async {
            let list = ProcessManager.listProcesses()
            Task { @MainActor in self.liveProcesses = list }
        }
    }

    // MARK: - Mutations

    func addPin(_ pin: PinnedProcess) {
        pins.append(pin)
        persist()
        refresh()
    }

    func pinLive(_ proc: ProcessManager.LiveProcess, project: String, role: String) {
        let pin = PinnedProcess(
            pid: proc.pid,
            name: proc.name,
            command: proc.command,
            workingDirectory: nil,
            observedStartEpoch: proc.startDate.timeIntervalSince1970,
            project: project,
            role: role
        )
        addPin(pin)
    }

    /// Launches a command, then pins it under the given project/role.
    @discardableResult
    func pinCommand(_ command: String, project: String, role: String) -> Bool {
        guard let pid = ProcessManager.launch(command: command, workingDirectory: nil) else {
            return false
        }
        usleep(200_000)
        let start = ProcessManager.startDate(forPID: pid)?.timeIntervalSince1970
        let exe = command.split(separator: " ").first.map(String.init) ?? command
        let pin = PinnedProcess(
            pid: pid,
            name: (exe as NSString).lastPathComponent,
            command: command,
            workingDirectory: nil,
            observedStartEpoch: start,
            project: project,
            role: role
        )
        addPin(pin)
        return true
    }

    func unpin(_ id: UUID) {
        pins.removeAll { $0.id == id }
        statuses[id] = nil
        persist()
    }

    /// Kills the process, closes its tmux pane (if it came from one), and
    /// removes the pin from the list. Returns true if a tmux pane was closed.
    @discardableResult
    func killAndRemove(_ id: UUID) -> Bool {
        guard let pin = pins.first(where: { $0.id == id }) else { return false }
        var closedPane = false
        if let paneId = pin.tmuxPaneId, !paneId.isEmpty {
            // Closing the pane also kills the process running inside it.
            closedPane = Tmux.killPane(paneId)
        }
        if !closedPane {
            // No tmux pane (or tmux unavailable): kill the process directly.
            ProcessManager.kill(pid: pin.pid, force: true)
        }
        unpin(id)
        return closedPane
    }

    // MARK: - Project-level actions

    /// Cheap, synchronous check (no tmux call): does the project contain pins
    /// that originated from tmux panes?
    func projectHasTmuxPanes(_ project: String) -> Bool {
        !project.isEmpty && pins.contains { $0.project == project && ($0.tmuxPaneId?.isEmpty == false) }
    }

    /// True if the project corresponds to a live tmux session (its pins came
    /// from tmux and a session with that name still exists).
    func projectIsTmuxSession(_ project: String) -> Bool {
        guard !project.isEmpty,
              pins.contains(where: { $0.project == project && ($0.tmuxPaneId?.isEmpty == false) })
        else { return false }
        return Tmux.sessionExists(project)
    }

    /// Kills the whole tmux session for a project and removes all its pins.
    func killTmuxSession(_ project: String) {
        Tmux.killSession(project)
        pins.removeAll { $0.project == project }
        persist()
        refresh()
    }

    /// Force-kills every process in a project (closing tmux panes where known)
    /// and removes all its pins.
    func killProjectAndRemove(_ project: String) {
        for pin in pins where pin.project == project {
            if let paneId = pin.tmuxPaneId, !paneId.isEmpty {
                Tmux.killPane(paneId)
            } else {
                ProcessManager.kill(pid: pin.pid, force: true)
            }
        }
        pins.removeAll { $0.project == project }
        persist()
        refresh()
    }

    /// Removes all of a project's pins without touching the processes.
    func unpinProject(_ project: String) {
        pins.removeAll { $0.project == project }
        persist()
    }

    /// Pins a set of tmux panes in one go. Each pane's session becomes the
    /// project and its window/command becomes the role. Returns count added.
    @discardableResult
    func pinTmuxPanes(_ panes: [Tmux.Pane]) -> Int {
        let existingPIDs = Set(pins.map { $0.pid })
        var added = 0
        for pane in panes {
            if existingPIDs.contains(pane.trackPID) { continue }
            let command = ProcessManager.commandLine(forPID: pane.trackPID) ?? pane.currentCommand
            let start = ProcessManager.startDate(forPID: pane.trackPID)?.timeIntervalSince1970
            let pin = PinnedProcess(
                pid: pane.trackPID,
                name: pane.name,
                command: command,
                workingDirectory: pane.currentPath.isEmpty ? nil : pane.currentPath,
                observedStartEpoch: start,
                project: pane.session,
                role: pane.suggestedRole,
                tmuxPaneId: pane.paneId
            )
            pins.append(pin)
            added += 1
        }
        if added > 0 { persist(); refresh() }
        return added
    }

    func updatePin(_ id: UUID, project: String, role: String) {
        guard let idx = pins.firstIndex(where: { $0.id == id }) else { return }
        pins[idx].project = project
        pins[idx].role = role
        persist()
    }

    func kill(_ id: UUID, force: Bool) {
        guard let pin = pins.first(where: { $0.id == id }) else { return }
        ProcessManager.kill(pid: pin.pid, force: force)
        // Reflect change quickly.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.refresh() }
    }

    func restart(_ id: UUID) {
        guard let idx = pins.firstIndex(where: { $0.id == id }) else { return }
        if let newPID = ProcessManager.restart(pins[idx]) {
            pins[idx].pid = newPID
            usleep(200_000)
            pins[idx].observedStartEpoch = ProcessManager.startDate(forPID: newPID)?.timeIntervalSince1970
            persist()
        }
        refresh()
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

    /// Pin a process by raw pid (e.g. an MCP server from an agent tree).
    func pinPID(_ pid: Int32, name: String, project: String, role: String) {
        guard !pins.contains(where: { $0.pid == pid }) else { return }
        let command = ProcessManager.commandLine(forPID: pid) ?? name
        let start = ProcessManager.startDate(forPID: pid)?.timeIntervalSince1970
        let pin = PinnedProcess(
            pid: pid,
            name: name,
            command: command,
            workingDirectory: nil,
            observedStartEpoch: start,
            project: project,
            role: role
        )
        addPin(pin)
    }

    private func persist() {
        Store.shared.save(pins)
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
