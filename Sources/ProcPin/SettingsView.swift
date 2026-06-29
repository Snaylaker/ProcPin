import SwiftUI

/// App settings. Currently: choose the terminal used by "Jump to tmux pane".
struct SettingsView: View {
    let onClose: () -> Void

    @AppStorage(Terminals.settingsKey) private var terminalID: String = "auto"

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
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
            Text(subtitle)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
