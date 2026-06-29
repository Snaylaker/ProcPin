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

    /// Recompute statuses off the main thread (single `ps` call for all pins).
    func refresh() {
        let snapshot = pins
        work.async {
            // Keep tmux-origin pins pointing at whatever currently runs in their
            // pane (the foreground process / pid can change over time).
            let updates = self.computeTmuxSync(snapshot)
            var synced = snapshot
            if !updates.isEmpty {
                for i in synced.indices {
                    if let u = updates[synced[i].id] {
                        synced[i].pid = u.pid
                        synced[i].observedStartEpoch = u.epoch
                        synced[i].name = u.name
                        synced[i].command = u.command
                        synced[i].workingDirectory = u.cwd
                    }
                }
            }
            let newStatuses = ProcessManager.statuses(for: synced)
            Task { @MainActor in
                self.applyTmuxUpdates(updates)
                self.statuses = newStatuses
            }
        }
        if scanAgentsEnabled { scanAgents() }
    }

    private struct TmuxPinUpdate {
        let pid: Int32
        let epoch: Double?
        let name: String
        let command: String
        let cwd: String?
    }

    /// For each tmux-origin pin, re-resolve its live pane (pid/command/cwd).
    private func computeTmuxSync(_ snapshot: [PinnedProcess]) -> [UUID: TmuxPinUpdate] {
        let tmuxPins = snapshot.filter { ($0.tmuxPaneId?.isEmpty == false) }
        guard !tmuxPins.isEmpty else { return [:] }
        let panes = Tmux.rawPanesByID()
        guard !panes.isEmpty else { return [:] }

        var updates: [UUID: TmuxPinUpdate] = [:]
        for pin in tmuxPins {
            guard let paneId = pin.tmuxPaneId, let pane = panes[paneId] else { continue }
            let fg = Tmux.resolveForegroundPID(tty: pane.tty, fallback: pane.panePID)
            let epoch = ProcessManager.startDate(forPID: fg)?.timeIntervalSince1970
            let command = ProcessManager.commandLine(forPID: fg) ?? pane.currentCommand
            updates[pin.id] = TmuxPinUpdate(
                pid: fg,
                epoch: epoch,
                name: pane.currentCommand,
                command: command,
                cwd: pane.currentPath.isEmpty ? pin.workingDirectory : pane.currentPath
            )
        }
        return updates
    }

    /// Applies tmux updates to the stored pins, persisting only on real change.
    private func applyTmuxUpdates(_ updates: [UUID: TmuxPinUpdate]) {
        guard !updates.isEmpty else { return }
        var changed = false
        for i in pins.indices {
            guard let u = updates[pins[i].id] else { continue }
            if pins[i].pid != u.pid || pins[i].name != u.name
                || pins[i].command != u.command || pins[i].workingDirectory != u.cwd {
                pins[i].pid = u.pid
                pins[i].observedStartEpoch = u.epoch
                pins[i].name = u.name
                pins[i].command = u.command
                pins[i].workingDirectory = u.cwd
                changed = true
            }
        }
        if changed { persist() }
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

    // MARK: - Mutations

    func addPin(_ pin: PinnedProcess) {
        pins.append(pin)
        persist()
        refresh()
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
        guard let idx = pins.firstIndex(where: { $0.id == id }) else { return }
        let pin = pins[idx]
        if let paneId = pin.tmuxPaneId, !paneId.isEmpty {
            // Restart inside the tmux pane (Ctrl-C + re-run last command).
            Tmux.restartPane(paneId)
            // Live-sync will pick up the new pid on the next refresh.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refresh() }
            return
        }
        if let newPID = ProcessManager.restart(pin) {
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
