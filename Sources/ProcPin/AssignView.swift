import SwiftUI

/// Add tmux panes (the only way to add) or edit an existing pin's project/role.
/// Rendered in-place over the list.
struct AssignView: View {
    @ObservedObject var state: AppState
    let editingPinID: UUID?
    let onClose: () -> Void

    // Editing fields.
    @State private var project = ""
    @State private var role = ""

    // tmux import state.
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
                    if isEditing {
                        editFields
                    } else {
                        tmuxImport
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: 560)
            Divider()
            footer
        }
        .onAppear {
            if let id = editingPinID, let pin = state.pins.first(where: { $0.id == id }) {
                project = pin.project
                role = pin.role
            } else {
                loadTmux()
            }
        }
    }

    // MARK: Header / footer

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            Text(isEditing ? "Edit Project / Role" : "Add from tmux")
                .font(.system(size: 14, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
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
            .disabled(!canCommit)
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    // MARK: Edit existing pin

    private var editFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            labeledField(title: "Project", systemImage: "folder") {
                TextField("Project", text: $project).textFieldStyle(.plain)
            }
            labeledField(title: "Role", systemImage: "tag") {
                TextField("Role", text: $role).textFieldStyle(.plain)
            }
        }
    }

    // MARK: tmux import

    @ViewBuilder
    private var tmuxImport: some View {
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
                    selectedPanes = selectedPanes.count == tmuxPanes.count ? [] : Set(tmuxPanes.map { $0.id })
                }
                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.tint)
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
                ForEach(panes) { pane in paneRow(pane) }
            }
        }
    }

    private func paneRow(_ pane: Tmux.Pane) -> some View {
        let selected = selectedPanes.contains(pane.id)
        let alreadyPinned = state.pins.contains { $0.tmuxPaneId == pane.id }
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
                        if alreadyPinned {
                            Text("pinned").font(.system(size: 9)).foregroundStyle(.tertiary)
                        }
                    }
                    Text(pane.currentPath).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                Text("PID \(pane.trackPID)").font(.system(size: 9, design: .rounded)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.03))
            )
        }
        .buttonStyle(.plain)
        .opacity(alreadyPinned && !selected ? 0.55 : 1)
    }

    // MARK: Logic

    private var commitTitle: String {
        if isEditing { return "Save" }
        return selectedPanes.isEmpty ? "Track" : "Track \(selectedPanes.count)"
    }

    private var canCommit: Bool {
        isEditing ? true : !selectedPanes.isEmpty
    }

    private func commit() {
        if let id = editingPinID {
            state.updatePin(id,
                            project: project.trimmingCharacters(in: .whitespaces),
                            role: role.trimmingCharacters(in: .whitespaces))
            onClose()
            return
        }
        let chosen = tmuxPanes.filter { selectedPanes.contains($0.id) }
        let added = state.pinTmuxPanes(chosen)
        if added == 0 {
            tmuxError = "Those panes are already pinned."
        } else {
            onClose()
        }
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
                    // Preselect panes that aren't already pinned.
                    let pinned = Set(state.pins.compactMap { $0.tmuxPaneId })
                    selectedPanes = Set(panes.map { $0.id }).subtracting(pinned)
                    if panes.isEmpty { tmuxError = "No tmux panes found." }
                case .failure(let err):
                    tmuxPanes = []
                    tmuxError = err.description
                }
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
