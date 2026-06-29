import SwiftUI

/// Inline live tail of a tmux pane's output (last ~20 lines), refreshed while
/// visible. Captures off the main thread so the UI stays responsive.
struct PanePeekView: View {
    let paneId: String

    @State private var text = "…"
    @State private var timer: Timer?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(text)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.primary.opacity(0.85))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                Color.clear.frame(height: 1).id("bottom")
            }
            .frame(height: 150)
            .background(Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onChange(of: text) { _ in
                withAnimation(.linear(duration: 0.1)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
        }
        .onAppear { load(); start() }
        .onDisappear { timer?.invalidate(); timer = nil }
    }

    private func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { _ in load() }
    }

    private func load() {
        let id = paneId
        DispatchQueue.global(qos: .userInitiated).async {
            let raw = Tmux.capturePane(id, lines: 60) ?? ""
            var lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                lines.removeLast()
            }
            let tail = lines.suffix(20).joined(separator: "\n")
            DispatchQueue.main.async {
                self.text = tail.isEmpty ? "(no output)" : tail
            }
        }
    }
}
