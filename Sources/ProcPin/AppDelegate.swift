import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem!
    private var pins: [PinnedProcess] = []

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        pins = Store.shared.load()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            let image = NSImage(
                systemSymbolName: "pin.circle",
                accessibilityDescription: "ProcPin"
            )
            image?.isTemplate = true
            button.image = image
        }

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - Menu construction

    /// Rebuild the menu each time it opens so uptimes and running state are fresh.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Header.
        let header = NSMenuItem(title: "Pinned Processes", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if pins.isEmpty {
            let empty = NSMenuItem(title: "  No pinned processes", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for pin in pins {
                menu.addItem(makePinItem(for: pin))
            }
        }

        menu.addItem(.separator())

        // Pin a new process.
        let pinMenu = NSMenuItem(title: "Pin a Process", action: nil, keyEquivalent: "")
        pinMenu.submenu = makePickerSubmenu()
        menu.addItem(pinMenu)

        let pinByCommand = NSMenuItem(
            title: "Pin by Command…",
            action: #selector(pinByCommand(_:)),
            keyEquivalent: "n"
        )
        pinByCommand.target = self
        menu.addItem(pinByCommand)

        menu.addItem(.separator())

        let refresh = NSMenuItem(title: "Refresh", action: #selector(refresh(_:)), keyEquivalent: "r")
        refresh.target = self
        menu.addItem(refresh)

        let quit = NSMenuItem(title: "Quit ProcPin", action: #selector(quit(_:)), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// One menu item per pin: title shows status + uptime, submenu has actions.
    private func makePinItem(for pin: PinnedProcess) -> NSMenuItem {
        let status = ProcessManager.status(for: pin)
        let dot = status.isRunning ? "🟢" : "🔴"
        let uptime = status.uptimeSeconds.map(Self.formatUptime) ?? "not running"
        let title = "\(dot) \(pin.name)  ·  \(uptime)"

        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu()

        let info = NSMenuItem(
            title: status.isRunning ? "PID \(pin.pid)" : "Last PID \(pin.pid)",
            action: nil,
            keyEquivalent: ""
        )
        info.isEnabled = false
        submenu.addItem(info)

        let cmd = NSMenuItem(title: truncate(pin.command, 60), action: nil, keyEquivalent: "")
        cmd.isEnabled = false
        submenu.addItem(cmd)

        submenu.addItem(.separator())

        let restart = NSMenuItem(title: "Restart", action: #selector(restartPin(_:)), keyEquivalent: "")
        restart.target = self
        restart.representedObject = pin.id
        submenu.addItem(restart)

        let kill = NSMenuItem(title: "Kill (SIGTERM)", action: #selector(killPin(_:)), keyEquivalent: "")
        kill.target = self
        kill.representedObject = pin.id
        kill.isEnabled = status.isRunning
        submenu.addItem(kill)

        let forceKill = NSMenuItem(title: "Force Kill (SIGKILL)", action: #selector(forceKillPin(_:)), keyEquivalent: "")
        forceKill.target = self
        forceKill.representedObject = pin.id
        forceKill.isEnabled = status.isRunning
        submenu.addItem(forceKill)

        submenu.addItem(.separator())

        let unpin = NSMenuItem(title: "Unpin", action: #selector(unpin(_:)), keyEquivalent: "")
        unpin.target = self
        unpin.representedObject = pin.id
        submenu.addItem(unpin)

        item.submenu = submenu
        return item
    }

    /// Submenu listing newest running processes to pin.
    private func makePickerSubmenu() -> NSMenu {
        let submenu = NSMenu()
        let live = ProcessManager.listProcesses()
        let pinnedPIDs = Set(pins.map { $0.pid })
        var shown = 0
        for proc in live {
            if proc.name.isEmpty { continue }
            if pinnedPIDs.contains(proc.pid) { continue }
            let item = NSMenuItem(
                title: "\(proc.name)  (\(proc.pid))",
                action: #selector(pinLiveProcess(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = proc.pid
            submenu.addItem(item)
            shown += 1
            if shown >= 40 { break }
        }
        if shown == 0 {
            let empty = NSMenuItem(title: "No processes found", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        }
        return submenu
    }

    // MARK: - Actions

    @objc private func pinLiveProcess(_ sender: NSMenuItem) {
        guard let pid = sender.representedObject as? Int32 else { return }
        let live = ProcessManager.listProcesses()
        guard let proc = live.first(where: { $0.pid == pid }) else { return }
        let pin = PinnedProcess(
            pid: proc.pid,
            name: proc.name,
            command: proc.command,
            workingDirectory: nil,
            observedStartEpoch: proc.startDate.timeIntervalSince1970
        )
        pins.append(pin)
        persist()
    }

    @objc private func pinByCommand(_ sender: NSMenuItem) {
        let alert = NSAlert()
        alert.messageText = "Pin a Command"
        alert.informativeText = "Enter a shell command. ProcPin will run it now and let you restart/kill it later."
        alert.addButton(withTitle: "Pin & Run")
        alert.addButton(withTitle: "Cancel")

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "e.g. node server.js"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let command = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else { return }

        guard let pid = ProcessManager.launch(command: command, workingDirectory: nil) else {
            presentError("Failed to launch command.")
            return
        }
        // Give the shell a moment, then capture its real start time.
        usleep(200_000)
        let start = ProcessManager.startDate(forPID: pid)?.timeIntervalSince1970
        let name = (command.split(separator: " ").first.map(String.init) ?? command)
        let pin = PinnedProcess(
            pid: pid,
            name: (name as NSString).lastPathComponent,
            command: command,
            workingDirectory: nil,
            observedStartEpoch: start
        )
        pins.append(pin)
        persist()
    }

    @objc private func restartPin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let idx = pins.firstIndex(where: { $0.id == id }) else { return }
        if let newPID = ProcessManager.restart(pins[idx]) {
            pins[idx].pid = newPID
            usleep(200_000)
            pins[idx].observedStartEpoch = ProcessManager.startDate(forPID: newPID)?.timeIntervalSince1970
            persist()
        } else {
            presentError("Failed to restart \(pins[idx].name).")
        }
    }

    @objc private func killPin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let pin = pins.first(where: { $0.id == id }) else { return }
        ProcessManager.kill(pid: pin.pid, force: false)
    }

    @objc private func forceKillPin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let pin = pins.first(where: { $0.id == id }) else { return }
        ProcessManager.kill(pid: pin.pid, force: true)
    }

    @objc private func unpin(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        pins.removeAll { $0.id == id }
        persist()
    }

    @objc private func refresh(_ sender: NSMenuItem) {
        // Menu rebuilds on open; nothing else needed.
    }

    @objc private func quit(_ sender: NSMenuItem) {
        NSApp.terminate(nil)
    }

    // MARK: - Helpers

    private func persist() {
        Store.shared.save(pins)
    }

    private func presentError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "ProcPin"
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func truncate(_ s: String, _ max: Int) -> String {
        s.count <= max ? s : String(s.prefix(max - 1)) + "…"
    }

    /// Formats seconds as "3d 4h", "2h 13m", "5m 02s", or "12s".
    static func formatUptime(_ seconds: TimeInterval) -> String {
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
}
