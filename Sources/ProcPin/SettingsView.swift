import SwiftUI

/// App settings. Currently: choose the terminal used by "Jump to tmux pane".
struct SettingsView: View {
    @ObservedObject var state: AppState
    let onClose: () -> Void

    @AppStorage(Terminals.settingsKey) private var terminalID: String = "auto"
    @AppStorage("ProcPin.showDock") private var showDock: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    updatesSection
                    section(title: "General", subtitle: "") {
                        Toggle(isOn: $showDock) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text("Show Dock icon").font(.system(size: 12.5))
                                Text("Off = menu bar only").font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                        }
                        .toggleStyle(.switch)
                        .onChange(of: showDock) { AppDelegate.setDockVisible($0) }
                    }
                    section(title: "Terminal", subtitle: "Used when jumping to a tmux pane. Auto-detect figures out the hosting terminal from the pane's tty; pick a specific app if that doesn't work.") {
                        VStack(spacing: 2) {
                            ForEach(Terminals.all) { term in
                                terminalRow(term)
                            }
                        }
                    }
                }
                .padding(14)
            }
            .frame(maxHeight: 460)
        }
    }

    // MARK: Updates

    @ViewBuilder
    private var updatesSection: some View {
        section(title: "Updates", subtitle: "ProcPin \(AppInfo.version)") {
            HStack(spacing: 8) {
                switch state.updateState {
                case .available(let release):
                    Button {
                        NSWorkspace.shared.open(release.htmlURL)
                    } label: {
                        Label("Download \(release.version)", systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                case .checking:
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Checking…").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                case .upToDate:
                    Label("Up to date", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(.green)
                    Spacer()
                    checkButton
                case .unknown:
                    checkButton
                }
                if case .available = state.updateState { Spacer(); checkButton }
            }
        }
    }

    private var checkButton: some View {
        Button("Check for Updates") { state.checkForUpdates() }
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.plain)
            Text("Settings").font(.system(size: 15, weight: .bold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func section<Content: View>(
        title: String, subtitle: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .bold))
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
                .padding(.top, 2)
        }
    }

    private func terminalRow(_ term: TerminalApp) -> some View {
        let selected = terminalID == term.id
        let installed = term.bundleID == nil || isInstalled(term.bundleID!)
        return Button {
            terminalID = term.id
        } label: {
            HStack(spacing: 9) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary.opacity(0.4))
                    .font(.system(size: 13))
                Text(term.name)
                    .font(.system(size: 12.5, weight: selected ? .semibold : .regular))
                if term.id != "auto" && !installed {
                    Text("not found")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.10) : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func isInstalled(_ bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
}
