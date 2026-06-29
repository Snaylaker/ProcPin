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
        .frame(width: 380)
        .frame(minHeight: 200)
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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            modePicker
            Divider().opacity(0.5)
            if viewMode == .pinned {
                searchBar
                Divider().opacity(0.5)
                content
            } else {
                AgentsView(state: state, screen: $screen)
            }
            Divider()
            footer
        }
        .onChange(of: viewMode) { mode in
            state.setAgentScanning(mode == .agents)
        }
        .onDisappear { state.setAgentScanning(false) }
    }

    private var modePicker: some View {
        Picker("", selection: $viewMode) {
            ForEach(ViewMode.allCases, id: \.self) { mode in
                Text(mode == .agents ? "Agents\(state.agents.isEmpty ? "" : " (\(state.agents.count))")" : mode.rawValue)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "pin.circle.fill")
                .foregroundStyle(.tint)
                .font(.system(size: 17))
            VStack(alignment: .leading, spacing: 1) {
                Text("ProcPin")
                    .font(.system(size: 14, weight: .bold))
                Text(summaryText)
                    .font(.system(size: 10, design: .rounded))
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
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var summaryText: String {
        let running = state.pins.filter { state.statuses[$0.id]?.isRunning ?? false }.count
        let totalCPU = state.pins.reduce(0.0) { $0 + (state.statuses[$1.id]?.cpuPercent ?? 0) }
        if state.pins.isEmpty { return "no processes pinned" }
        return "\(running)/\(state.pins.count) running · \(Format.cpu(totalCPU)) CPU"
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 12))
            TextField("Search by project, role, name…", text: $search)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var content: some View {
        let groups = state.groupedPins(filter: search)
        if state.pins.isEmpty {
            emptyState(
                icon: "tray",
                title: "No pinned processes",
                subtitle: "Click Add to pin a running process or run a command."
            )
        } else if groups.isEmpty {
            emptyState(
                icon: "magnifyingglass",
                title: "No matches",
                subtitle: "Nothing matches “\(search)”."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(groups, id: \.project) { group in
                        ProjectSection(state: state, screen: $screen,
                                       project: group.project, pins: group.pins)
                    }
                }
                .padding(.vertical, 10)
            }
            .frame(maxHeight: 420)
        }
    }

    private func emptyState(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal, 24)
    }

    private var footer: some View {
        HStack {
            Text("\(state.pins.count) pinned")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit", systemImage: "power")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - Project section

struct ProjectSection: View {
    @ObservedObject var state: AppState
    @Binding var screen: RootView.Screen
    let project: String
    let pins: [PinnedProcess]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader
            VStack(spacing: 5) {
                ForEach(pins) { pin in
                    ProcessRow(state: state, screen: $screen, pin: pin)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.primary.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.06), lineWidth: 1)
                )
        )
        .padding(.horizontal, 10)
    }

    private var sectionHeader: some View {
        let cap = state.capacity(forProject: project)
        let allRunning = cap.total > 0 && cap.running == cap.total
        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: project.isEmpty ? "square.dashed" : "folder.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.tint)
                Text(project.isEmpty ? "Ungrouped" : project)
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                HStack(spacing: 4) {
                    Circle()
                        .fill(allRunning ? Color.green : (cap.running == 0 ? Color.secondary.opacity(0.5) : Color.yellow))
                        .frame(width: 6, height: 6)
                    Text("\(cap.running)/\(cap.total) up")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            if cap.running > 0 {
                HStack(spacing: 8) {
                    MeterBar(fraction: min(cap.cpu / 100.0, 1), tint: tint(forCPU: cap.cpu))
                    Text("\(Format.cpu(cap.cpu)) CPU")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(Format.memory(cap.memory))
                        .font(.system(size: 10, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func tint(forCPU cpu: Double) -> Color {
        switch cpu {
        case ..<40: return .green
        case 40..<80: return .yellow
        default: return .red
        }
    }
}

// MARK: - Process row

struct ProcessRow: View {
    @ObservedObject var state: AppState
    @Binding var screen: RootView.Screen
    let pin: PinnedProcess
    @State private var hovering = false

    private var status: ProcessStatus? { state.statuses[pin.id] }
    private var running: Bool { status?.isRunning ?? false }

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(running: running)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(pin.name)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                    if !pin.role.isEmpty {
                        Badge(text: pin.role)
                    }
                }
                Text(running ? "up \(Format.uptime(status?.uptimeSeconds ?? 0)) · PID \(pin.pid)" : "not running")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if running, let s = status {
                CapacityBar(cpuPercent: s.cpuPercent ?? 0, memoryBytes: s.memoryBytes)
            }

            actions
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.07) : Color.white.opacity(0.001))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(Color.primary.opacity(hovering ? 0.06 : 0), lineWidth: 1)
                )
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var actions: some View {
        HStack(spacing: 2) {
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
                Button("Unpin", role: .destructive) { state.unpin(pin.id) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 24, height: 22)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 28)
        }
        .opacity(hovering ? 1 : 0.55)
    }
}
