import SwiftUI

/// Add a new pin (pick a running process or run a command) or edit an existing
/// pin's project / role. Rendered in-place over the list.
struct AssignView: View {
    @ObservedObject var state: AppState
    let editingPinID: UUID?
    let onClose: () -> Void

    enum Mode: String, CaseIterable { case pick = "Pick Running", command = "Run Command", tmux = "tmux" }
    @State private var mode: Mode = .pick

    @State private var project = ""
    @State private var role = ""
    @State private var command = ""
    @State private var search = ""
    @State private var selectedPID: Int32?
    @State private var error: String?

    // tmux detection state
    @State private var tmuxPanes: [Tmux.Pane] = []
    @State private var tmuxError: String?
    @State private var tmuxLoading = false
    @State private var selectedPanes: Set<String> = []

    private var isEditing: Bool { editingPinID != nil }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if !isEditing && mode == .tmux {
                        tmuxIntro
                    } else {
                        projectRoleFields
                    }
                    if !isEditing {
                        Picker("", selection: $mode) {
                            ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        switch mode {
                        case .pick: pickRunning
                        case .command: runCommand
                        case .tmux: tmuxSection
                        }
                    }
                    if let error {
                        Text(error)
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                    }
                }
                .padding(12)
            }
            .frame(maxHeight: 460)
            Divider()
            footer
        }
        .onAppear {
            if let id = editingPinID, let pin = state.pins.first(where: { $0.id == id }) {
                project = pin.project
                role = pin.role
            }
            state.refreshLiveProcesses()
        }
        .onChange(of: mode) { newMode in
            if newMode == .tmux && tmuxPanes.isEmpty && tmuxError == nil {
                loadTmux()
            }
        }
    }

    // MARK: Sections

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            Text(isEditing ? "Edit Project / Role" : "Add Process")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var projectRoleFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                labeledField(title: "Project", systemImage: "folder") {
                    HStack(spacing: 4) {
                        TextField("e.g. Project One", text: $project)
                            .textFieldStyle(.plain)
                        if !state.projectNames.filter({ !$0.isEmpty }).isEmpty {
                            Menu {
                                ForEach(state.projectNames.filter { !$0.isEmpty }, id: \.self) { p in
                                    Button(p) { project = p }
                                }
                            } label: {
                                Image(systemName: "chevron.down").font(.system(size: 9))
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .frame(width: 16)
                        }
                    }
                }
                labeledField(title: "Role", systemImage: "tag") {
                    TextField("e.g. Frontend", text: $role)
                        .textFieldStyle(.plain)
                }
            }
            // Quick role chips.
            HStack(spacing: 6) {
                ForEach(["Frontend", "Backend", "Database", "Worker"], id: \.self) { r in
                    Button { role = r } label: {
                        Text(r).font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(role == r ? 0.25 : 0.08), in: Capsule())
                            .foregroundStyle(.tint)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var pickRunning: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).font(.system(size: 12))
                TextField("Search running processes…", text: $search)
                    .textFieldStyle(.plain).font(.system(size: 12))
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))

            let items = filteredLive
            if items.isEmpty {
                Text("No running processes match.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 3) {
                    ForEach(items, id: \.pid) { proc in
                        liveRow(proc)
                    }
                }
            }
        }
    }

    private func liveRow(_ proc: ProcessManager.LiveProcess) -> some View {
        let selected = selectedPID == proc.pid
        return Button {
            selectedPID = proc.pid
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.4))
                    .font(.system(size: 13))
                VStack(alignment: .leading, spacing: 1) {
                    Text(proc.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(proc.command).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 1) {
                    Text("PID \(proc.pid)").font(.system(size: 9, design: .rounded)).foregroundStyle(.tertiary)
                    Text("\(Format.cpu(proc.cpuPercent)) · \(Format.memory(proc.memoryBytes))")
                        .font(.system(size: 9, design: .rounded)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.03))
            )
        }
        .buttonStyle(.plain)
    }

    private var tmuxIntro: some View {
        HStack(spacing: 8) {
            Image(systemName: "rectangle.split.3x1.fill")
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Track tmux sessions")
                    .font(.system(size: 12, weight: .semibold))
                Text("Each session becomes a project; each pane is tracked with its window as the role.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var tmuxSection: some View {
        HStack(spacing: 8) {
            Button(action: loadTmux) {
                Label(tmuxLoading ? "Detecting…" : "Detect tmux Sessions",
                      systemImage: "arrow.triangle.2.circlepath")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(tmuxLoading)

            if !tmuxPanes.isEmpty {
                Spacer()
                Button(selectedPanes.count == tmuxPanes.count ? "Deselect All" : "Select All") {
                    if selectedPanes.count == tmuxPanes.count {
                        selectedPanes.removeAll()
                    } else {
                        selectedPanes = Set(tmuxPanes.map { $0.id })
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.tint)
            }
        }

        if let tmuxError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(tmuxError).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }

        let bySession = Dictionary(grouping: tmuxPanes, by: { $0.session })
            .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
        ForEach(bySession, id: \.key) { session, panes in
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "folder.fill").font(.system(size: 10)).foregroundStyle(.tint)
                    Text(session).font(.system(size: 12, weight: .bold))
                    Text("\(panes.count) pane\(panes.count == 1 ? "" : "s")")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                ForEach(panes) { pane in
                    tmuxPaneRow(pane)
                }
            }
        }
    }

    private func tmuxPaneRow(_ pane: Tmux.Pane) -> some View {
        let selected = selectedPanes.contains(pane.id)
        return Button {
            if selected { selectedPanes.remove(pane.id) } else { selectedPanes.insert(pane.id) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: selected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.4))
                    .font(.system(size: 13))
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(pane.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        Badge(text: pane.suggestedRole)
                    }
                    Text(pane.currentPath).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text("PID \(pane.trackPID)")
                    .font(.system(size: 9, design: .rounded)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.03))
            )
        }
        .buttonStyle(.plain)
    }

    private func loadTmux() {
        tmuxLoading = true
        tmuxError = nil
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Tmux.detect()
            DispatchQueue.main.async {
                tmuxLoading = false
                switch result {
                case .success(let panes):
                    tmuxPanes = panes
                    selectedPanes = Set(panes.map { $0.id })
                    if panes.isEmpty { tmuxError = "No tmux panes found." }
                case .failure(let err):
                    tmuxPanes = []
                    tmuxError = err.description
                }
            }
        }
    }

    private var runCommand: some View {
        VStack(alignment: .leading, spacing: 6) {
            labeledField(title: "Command", systemImage: "terminal") {
                TextField("e.g. npm run dev", text: $command)
                    .textFieldStyle(.plain)
            }
            Text("ProcPin runs this with /bin/sh and tracks it for restart/kill.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private var footer: some View {
        HStack {
            Button("Cancel", action: onClose)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            Spacer()
            Button(action: commit) {
                Text(commitTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(minWidth: 56)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(!canCommit)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    // MARK: Logic

    private var filteredLive: [ProcessManager.LiveProcess] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let base = state.liveProcesses.filter { !$0.name.isEmpty }
        let filtered = q.isEmpty ? base : base.filter {
            $0.name.lowercased().contains(q) || $0.command.lowercased().contains(q)
        }
        return Array(filtered.prefix(60))
    }

    private var commitTitle: String {
        if isEditing { return "Save" }
        if mode == .tmux && !selectedPanes.isEmpty { return "Track \(selectedPanes.count)" }
        return "Add"
    }

    private var canCommit: Bool {
        if isEditing { return true }
        switch mode {
        case .pick: return selectedPID != nil
        case .command: return !command.trimmingCharacters(in: .whitespaces).isEmpty
        case .tmux: return !selectedPanes.isEmpty
        }
    }

    private func commit() {
        let proj = project.trimmingCharacters(in: .whitespaces)
        let r = role.trimmingCharacters(in: .whitespaces)

        if let id = editingPinID {
            state.updatePin(id, project: proj, role: r)
            onClose()
            return
        }

        switch mode {
        case .pick:
            guard let pid = selectedPID,
                  let proc = state.liveProcesses.first(where: { $0.pid == pid }) else { return }
            state.pinLive(proc, project: proj, role: r)
            onClose()
        case .command:
            let cmd = command.trimmingCharacters(in: .whitespaces)
            if state.pinCommand(cmd, project: proj, role: r) {
                onClose()
            } else {
                error = "Failed to launch command."
            }
        case .tmux:
            let chosen = tmuxPanes.filter { selectedPanes.contains($0.id) }
            let added = state.pinTmuxPanes(chosen)
            if added == 0 {
                error = "Selected panes are already pinned."
            } else {
                onClose()
            }
        }
    }

    // MARK: Helper

    private func labeledField<Content: View>(
        title: String, systemImage: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
                .font(.system(size: 12))
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
