import SwiftUI

/// App settings.
struct SettingsView: View {
    @ObservedObject var state: AppState
    let onClose: () -> Void

    @AppStorage(Terminals.settingsKey) private var terminalID: String = "auto"
    @AppStorage("ProcPin.cpuAlert") private var cpuAlert: Double = 100
    @AppStorage("ProcPin.memAlertMB") private var memAlertMB: Double = 1500

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    updatesSection
                    alertsSection
                    section(title: "Terminal", subtitle: "Used when jumping to a tmux pane. Auto-detect figures out the hosting terminal from the pane's tty; pick a specific app if that doesn't work.") {
                        VStack(spacing: 2) {
                            ForEach(Terminals.all) { term in
                                terminalRow(term)
                            }
                        }
                    }
                    diagnosticsSection
                }
                .padding(14)
            }
            .frame(maxHeight: 600)
        }
    }

    // MARK: Alerts

    private var alertsSection: some View {
        section(title: "Alerts", subtitle: "Flag a process with a warning when it exceeds these. Set 0 to disable.") {
            VStack(spacing: 8) {
                HStack {
                    Text("CPU over").font(.system(size: 12.5))
                    Spacer()
                    TextField("", value: $cpuAlert, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                        .multilineTextAlignment(.trailing)
                    Text("%").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                HStack {
                    Text("Memory over").font(.system(size: 12.5))
                    Spacer()
                    TextField("", value: $memAlertMB, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                        .multilineTextAlignment(.trailing)
                    Text("MB").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
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
                        state.installUpdate()
                    } label: {
                        Label("Update to \(release.version) & Restart", systemImage: "arrow.down.circle.fill")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Spacer()
                    Button("Notes") { NSWorkspace.shared.open(release.htmlURL) }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary)
                case .downloading:
                    ProgressView().controlSize(.small)
                    Text("Downloading & installing…").font(.system(size: 11)).foregroundStyle(.secondary)
                case .checking:
                    ProgressView().controlSize(.small)
                    Text("Checking…").font(.system(size: 11)).foregroundStyle(.secondary)
                case .upToDate:
                    Label("Up to date", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11)).foregroundStyle(.green)
                    Spacer()
                    checkButton
                case .failed(let msg):
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
                    Spacer()
                    checkButton
                case .unknown:
                    checkButton
                }
            }
        }
    }

    private var checkButton: some View {
        Button("Check for Updates") { state.checkForUpdates() }
            .buttonStyle(.bordered)
            .controlSize(.small)
    }

    // MARK: Diagnostics

    private var diagnosticsSection: some View {
        section(title: "Diagnostics", subtitle: "") {
            HStack(spacing: 6) {
                let path = Tmux.tmuxPath()
                Image(systemName: path != nil ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(path != nil ? .green : .red)
                    .font(.system(size: 11))
                Text(path != nil ? "tmux: \(path!)" : "tmux: not found on PATH")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
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
