import SwiftUI

/// Top-level popover content. Switches between the process list and the
/// add/edit screens (sheets are unreliable inside an NSPopover, so we page
/// in-place instead).
struct RootView: View {
    @ObservedObject var state: AppState

    enum Screen: Equatable {
        case list
        case assign(editing: UUID?)
    }
    @State private var screen: Screen = .list

    var body: some View {
        ZStack {
            switch screen {
            case .list:
                ProcessListView(state: state, screen: $screen)
                    .transition(.opacity)
            case .assign(let editing):
                AssignView(state: state, editingPinID: editing) {
                    withAnimation(.easeInOut(duration: 0.15)) { screen = .list }
                }
                .transition(.opacity)
            }
        }
        .frame(width: 384)
        .frame(minHeight: 220)
        .background(.regularMaterial)
    }
}

// MARK: - Process list

struct ProcessListView: View {
    @ObservedObject var state: AppState
    @Binding var screen: RootView.Screen
    @State private var search = ""

    enum ViewMode: String, CaseIterable { case pinned = "Pinned", agents = "Agents" }
    @State private var viewMode: ViewMode = .pinned

    private let hPad: CGFloat = 18

    var body: some View {
        VStack(spacing: 0) {
            header
            modePicker
            if viewMode == .pinned {
                searchBar
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
            Image(systemName: "pin.circle.fill")
                .foregroundStyle(.tint)
                .font(.system(size: 19))
            VStack(alignment: .leading, spacing: 1) {
                Text("ProcPin")
                    .font(.system(size: 16, weight: .bold))
                Text(summaryText)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { screen = .assign(editing: nil) }
            } label: {
                Label("Add", systemImage: "plus")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.horizontal, hPad)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var summaryText: String {
        let running = state.pins.filter { state.statuses[$0.id]?.isRunning ?? false }.count
        let totalCPU = state.pins.reduce(0.0) { $0 + (state.statuses[$1.id]?.cpuPercent ?? 0) }
        if state.pins.isEmpty { return "no processes pinned" }
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

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            TextField("Search project, role, name…", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .padding(.horizontal, hPad)
        .padding(.bottom, 12)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let groups = state.groupedPins(filter: search)
        if state.pins.isEmpty {
            emptyState(icon: "tray", title: "No pinned processes",
                       subtitle: "Click Add to pin a running process, run a command, or import a tmux session.")
        } else if groups.isEmpty {
            emptyState(icon: "magnifyingglass", title: "No matches",
                       subtitle: "Nothing matches “\(search)”.")
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
            .frame(maxHeight: 440)
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
        HStack {
            Text("\(state.pins.count) pinned")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
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
        VStack(alignment: .leading, spacing: 9) {
            // Title row.
            HStack(spacing: 7) {
                Text(project.isEmpty ? "Ungrouped" : project)
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Text("\(cap.running)/\(cap.total) up")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                projectMenu
            }

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
        Menu {
            if state.projectHasTmuxPanes(project) {
                Button("Kill tmux Session “\(project)”", role: .destructive) {
                    state.killTmuxSession(project)
                }
            }
            Button("Kill All & Remove", role: .destructive) {
                state.killProjectAndRemove(project)
            }
            Button("Unpin All (keep running)") {
                state.unpinProject(project)
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

    private var status: ProcessStatus? { state.statuses[pin.id] }
    private var running: Bool { status?.isRunning ?? false }

    var body: some View {
        HStack(spacing: 10) {
            StatusDot(running: running)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(pin.name)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if !pin.role.isEmpty { Badge(text: pin.role) }
                }
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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
    }

    private var subtitle: String {
        guard running, let s = status else { return "not running · PID \(pin.pid)" }
        var parts = ["up \(Format.uptime(s.uptimeSeconds ?? 0))"]
        if let c = s.cpuPercent { parts.append("\(Format.cpu(c)) CPU") }
        if let m = s.memoryBytes { parts.append(Format.memory(m)) }
        return parts.joined(separator: " · ")
    }

    private var actions: some View {
        HStack(spacing: 1) {
            IconButton(systemName: "arrow.clockwise", help: "Restart", tint: .blue) {
                state.restart(pin.id)
            }
            IconButton(systemName: "stop.fill", help: "Kill (SIGTERM)", tint: .orange) {
                state.kill(pin.id, force: false)
            }
            .disabled(!running)
            .opacity(running ? 1 : 0.35)

            Menu {
                Button("Force Kill (SIGKILL)") { state.kill(pin.id, force: true) }
                    .disabled(!running)
                Button("Edit Project / Role…") {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        screen = .assign(editing: pin.id)
                    }
                }
                Divider()
                Button(removeLabel, role: .destructive) { state.killAndRemove(pin.id) }
                Button("Unpin (keep running)") { state.unpin(pin.id) }
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
        .opacity(hovering ? 1 : 0.0)
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }

    private var removeLabel: String {
        (pin.tmuxPaneId?.isEmpty == false) ? "Kill & Close tmux Pane" : "Kill & Remove"
    }
}
