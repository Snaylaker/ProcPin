import SwiftUI

/// Top-level popover content. Switches between the process list and the
/// add/edit screens (sheets are unreliable inside an NSPopover, so we page
/// in-place instead).
struct RootView: View {
    @ObservedObject var state: AppState

    enum Screen: Equatable {
        case list
        case settings
    }
    @State private var screen: Screen = .list

    var body: some View {
        ZStack {
            switch screen {
            case .list:
                ProcessListView(state: state, screen: $screen)
                    .transition(.opacity)
            case .settings:
                SettingsView(state: state) {
                    withAnimation(.easeInOut(duration: 0.15)) { screen = .list }
                }
                .transition(.opacity)
            }
        }
        .frame(width: 460)
        .frame(minHeight: 280)
        .background(.regularMaterial)
    }
}

// MARK: - Process list

struct ProcessListView: View {
    @ObservedObject var state: AppState
    @Binding var screen: RootView.Screen

    enum ViewMode: String, CaseIterable { case pinned = "Pinned", agents = "Agents" }
    @State private var viewMode: ViewMode = .pinned

    private let hPad: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            header
            modePicker
            if viewMode == .pinned {
                hairline
                content
            } else {
                AgentsView(state: state, screen: $screen)
            }
            hairline
            footer
        }
        .onChange(of: viewMode) { mode in
            state.setAgentScanning(mode == .agents)
        }
        .onDisappear { state.setAgentScanning(false) }
    }

    private var hairline: some View {
        Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 1)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.split.3x1.fill")
                .foregroundStyle(.tint)
                .font(.system(size: 17))
            VStack(alignment: .leading, spacing: 1) {
                Text("ProcPin")
                    .font(.system(size: 16, weight: .bold))
                Text(summaryText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, hPad)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var summaryText: String {
        let running = state.pins.filter { state.statuses[$0.id]?.isRunning ?? false }.count
        let totalCPU = state.pins.reduce(0.0) { $0 + (state.statuses[$1.id]?.cpuPercent ?? 0) }
        if state.pins.isEmpty { return "live tmux sessions" }
        return "\(running) of \(state.pins.count) running · \(Format.cpu(totalCPU)) CPU"
    }

    private var modePicker: some View {
        Picker("", selection: $viewMode) {
            ForEach(ViewMode.allCases, id: \.self) { mode in
                Text(mode == .agents ? "Agents\(state.agents.isEmpty ? "" : " \(state.agents.count)")" : mode.rawValue)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, hPad)
        .padding(.bottom, 12)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let groups = state.groupedPins(filter: "")
        if state.pins.isEmpty {
            if Tmux.tmuxPath() == nil {
                emptyState(icon: "exclamationmark.triangle", title: "tmux not found",
                           subtitle: "ProcPin shows your live tmux sessions. Install tmux (e.g. brew install tmux), then reopen. See Settings → Diagnostics.")
            } else {
                emptyState(icon: "rectangle.split.3x1", title: "No tmux sessions running",
                           subtitle: "Start a tmux session and its panes will appear here automatically.")
            }
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(groups.enumerated()), id: \.element.project) { idx, group in
                        if idx > 0 { hairline.padding(.horizontal, hPad) }
                        ProjectSection(state: state, screen: $screen,
                                       project: group.project, pins: group.pins)
                    }
                }
                .padding(.vertical, 4)
            }
            .frame(maxHeight: 600)
        }
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(title).font(.system(size: 14, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .padding(.horizontal, 28)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            switch state.updateState {
            case .available(let release):
                Button {
                    state.installUpdate()
                } label: {
                    Label("Update to \(release.version)", systemImage: "arrow.down.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .help("Download and install the new version, then relaunch")
            case .downloading:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Updating…").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            default:
                Text("\(state.pins.count) pinned")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { screen = .settings }
            } label: {
                Image(systemName: "gearshape").font(.system(size: 12))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Settings")
            Button { NSApp.terminate(nil) } label: {
                Label("Quit", systemImage: "power").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, hPad)
        .padding(.vertical, 9)
    }
}

// MARK: - Project section (flat, CodexBar-style)

struct ProjectSection: View {
    @ObservedObject var state: AppState
    @Binding var screen: RootView.Screen
    let project: String
    let pins: [PinnedProcess]

    private let hPad: CGFloat = 18

    var body: some View {
        let cap = state.capacity(forProject: project)
        let collapsed = state.isCollapsed(project)
        VStack(alignment: .leading, spacing: 9) {
            // Title row (click to fold/unfold).
            HStack(spacing: 7) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { state.toggleCollapsed(project) }
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(collapsed ? 0 : 90))
                        Text(project.isEmpty ? "Ungrouped" : project)
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.primary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Spacer()
                Text("\(cap.running)/\(cap.total) up")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if collapsed && cap.running > 0 {
                    Text("· \(Format.cpu(cap.cpu))")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                projectMenu
            }

            if !collapsed {
                // Full-width usage bar + label row.
                if cap.total > 0 {
                    MeterBar(fraction: cap.running == 0 ? 0 : min(cap.cpu / 100.0, 1),
                             tint: tint(forCPU: cap.cpu), height: 6)
                    HStack {
                        Text(cap.running == 0 ? "idle" : "\(Format.cpu(cap.cpu)) CPU")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        if cap.running > 0 {
                            Text(Format.memory(cap.memory))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Rows.
                VStack(spacing: 2) {
                    ForEach(pins) { pin in
                        ProcessRow(state: state, screen: $screen, pin: pin)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.horizontal, hPad)
        .padding(.vertical, 14)
    }

    private func tint(forCPU cpu: Double) -> Color {
        switch cpu {
        case ..<40: return .green
        case 40..<80: return .yellow
        default: return .red
        }
    }

    private var projectMenu: some View {
        let pc = state.projectPausedCount(project)
        return Menu {
            if pc.running - pc.paused > 0 {
                Button("Pause All") { state.setProjectPaused(project, paused: true) }
            }
            if pc.paused > 0 {
                Button("Resume All") { state.setProjectPaused(project, paused: false) }
            }
            if pc.running > 0 { Divider() }
            if state.projectHasTmuxPanes(project) {
                Button("Kill tmux Session “\(project)”", role: .destructive) {
                    state.killTmuxSession(project)
                }
            }
            Button("Close All Panes", role: .destructive) {
                state.killProjectAndRemove(project)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22)
    }
}

// MARK: - Process row (flat)

struct ProcessRow: View {
    @ObservedObject var state: AppState
    @Binding var screen: RootView.Screen
    let pin: PinnedProcess
    @State private var hovering = false
    @State private var showPeek = false

    @AppStorage("ProcPin.cpuAlert") private var cpuAlert: Double = 100
    @AppStorage("ProcPin.memAlertMB") private var memAlertMB: Double = 1500

    private var status: ProcessStatus? { state.statuses[pin.id] }
    private var running: Bool { status?.isRunning ?? false }
    private var paused: Bool { status?.isPaused ?? false }
    private var ports: [Int] { Array((status?.ports ?? []).prefix(3)) }
    private var isTmux: Bool { pin.tmuxPaneId?.isEmpty == false }

    /// True when the process exceeds the configured CPU or memory thresholds.
    private var isHot: Bool {
        guard running, let s = status, !s.isPaused else { return false }
        let cpu = s.cpuPercent ?? 0
        let memMB = Double(s.memoryBytes ?? 0) / 1_048_576
        return (cpuAlert > 0 && cpu >= cpuAlert) || (memAlertMB > 0 && memMB >= memAlertMB)
    }

    /// A clickable port chip that opens the local URL in the browser.
    private func portChip(_ port: Int) -> some View {
        Button {
            if let url = Self.localURL(forPort: port) {
                NSWorkspace.shared.open(url)
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "globe").font(.system(size: 8, weight: .semibold))
                Text(":\(port)").font(.system(size: 10, weight: .semibold, design: .rounded))
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.blue.opacity(0.15), in: Capsule())
            .foregroundStyle(.blue)
        }
        .buttonStyle(.plain)
        .help("Open \(Self.localURL(forPort: port)?.absoluteString ?? "")")
    }

    /// Builds a localhost URL, using https for common TLS ports.
    static func localURL(forPort port: Int) -> URL? {
        let isTLS = (port == 443 || port == 8443)
        let scheme = isTLS ? "https" : "http"
        let suffix = (port == 443 || port == 80) ? "" : ":\(port)"
        return URL(string: "\(scheme)://localhost\(suffix)")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Circle()
                    .fill(paused ? Color.yellow : (running ? Color.green : Color.secondary.opacity(0.5)))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(pin.name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        if isHot {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.orange)
                                .help("High usage (over your CPU/memory threshold)")
                        }
                        if !pin.role.isEmpty { Badge(text: pin.role) }
                        ForEach(ports, id: \.self) { port in
                            portChip(port)
                        }
                    }
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(isHot ? .orange : .secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 6)
                actions
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(hovering ? Color.primary.opacity(0.06) : .clear)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }

            if showPeek, let paneId = pin.tmuxPaneId, !paneId.isEmpty {
                PanePeekView(paneId: paneId)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 6)
                    .transition(.opacity)
            }
        }
    }

    private var subtitle: String {
        guard running, let s = status else { return "not running · PID \(pin.pid)" }
        if s.isPaused { return "paused · PID \(pin.pid)" }
        var parts = ["up \(Format.uptime(s.uptimeSeconds ?? 0))"]
        if let c = s.cpuPercent { parts.append("\(Format.cpu(c)) CPU") }
        if let m = s.memoryBytes { parts.append(Format.memory(m)) }
        return parts.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: 1) {
            // Jump + Peek are always visible for tmux-pinned rows (key actions).
            if isTmux {
                IconButton(systemName: "arrow.up.right.square", help: "Jump to tmux pane", tint: .purple) {
                    state.jumpToPane(pin.id)
                }
                IconButton(systemName: showPeek ? "text.alignleft" : "text.alignleft",
                           help: showPeek ? "Hide output" : "Peek output",
                           tint: showPeek ? .accentColor : .secondary) {
                    withAnimation(.easeInOut(duration: 0.15)) { showPeek.toggle() }
                }
            }
            // Remaining actions fade up on hover but stay faintly visible.
            Group {
                IconButton(systemName: "arrow.clockwise", help: "Restart", tint: .blue) {
                    state.restart(pin.id)
                }
                IconButton(systemName: "stop.fill", help: "Kill (SIGTERM)", tint: .orange) {
                    state.kill(pin.id, force: false)
                }
                .disabled(!running)
                .opacity(running ? 1 : 0.35)

                Menu {
                    if paused {
                        Button("Resume") { state.setPaused(pin.id, paused: false) }
                    } else {
                        Button("Pause") { state.setPaused(pin.id, paused: true) }
                            .disabled(!running)
                    }
                    Button("Force Kill (SIGKILL)") { state.kill(pin.id, force: true) }
                        .disabled(!running)
                    Divider()
                    Button(removeLabel, role: .destructive) { state.killAndRemove(pin.id) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 24, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 26)
            }
            .opacity(hovering ? 1 : 0.4)
            .animation(.easeInOut(duration: 0.12), value: hovering)
        }
    }

    private var removeLabel: String {
        (pin.tmuxPaneId?.isEmpty == false) ? "Kill & Close tmux Pane" : "Kill & Remove"
    }
}
