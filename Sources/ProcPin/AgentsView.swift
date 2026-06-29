import SwiftUI

/// Live view of running AI agents (Claude Code, OpenCode, …) and the process
/// tree each one has spawned. Auto-refreshes while visible.
struct AgentsView: View {
    @ObservedObject var state: AppState
    @Binding var screen: RootView.Screen

    var body: some View {
        Group {
            if state.agents.isEmpty {
                empty
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(state.agents.enumerated()), id: \.element.id) { idx, agent in
                            if idx > 0 {
                                Rectangle().fill(Color.primary.opacity(0.07))
                                    .frame(height: 1).padding(.horizontal, 18)
                            }
                            AgentSection(state: state, agent: agent)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 600)
            }
        }
        .onAppear { state.setAgentScanning(true) }
    }

    private var empty: some View {
        VStack(spacing: 9) {
            Image(systemName: "sparkles")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text("No agents running")
                .font(.system(size: 14, weight: .semibold))
            Text("Start Claude Code, OpenCode, Codex, Aider, Gemini, Goose or pi and they'll appear here with their spawned processes.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button { state.scanAgents() } label: {
                Label("Rescan", systemImage: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 44)
        .padding(.horizontal, 28)
    }
}

private struct AgentSection: View {
    @ObservedObject var state: AppState
    let agent: Agents.Agent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            titleRow
            if let task = agent.currentTask, !task.isEmpty {
                taskBanner(task)
            }
            // Total CPU bar + label row.
            MeterBar(fraction: min(agent.totalCPU / 100.0, 1), tint: tint(agent.totalCPU), height: 6)
            HStack {
                Text("\(Format.cpu(agent.totalCPU)) CPU")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Format.memory(agent.totalMemory)) · \(agent.childCount) spawned")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            // Process tree.
            VStack(spacing: 2) {
                ForEach(agent.nodes) { node in
                    AgentNodeRow(state: state, agent: agent, node: node)
                }
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var titleRow: some View {
        HStack(spacing: 7) {
            Image(systemName: "sparkles").font(.system(size: 12)).foregroundStyle(.tint)
            Text(agent.kind).font(.system(size: 15, weight: .bold))
            if let cwd = agent.cwd {
                Text((cwd as NSString).lastPathComponent)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tint)
            }
            Spacer()
            Text("up \(Format.uptime(Date().timeIntervalSince(agent.root.startDate)))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func taskBanner(_ task: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: "quote.opening").font(.system(size: 10)).foregroundStyle(.tint).padding(.top, 2)
            Text(task)
                .font(.system(size: 11.5))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.10), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func tint(_ cpu: Double) -> Color {
        switch cpu { case ..<40: return .green; case 40..<80: return .yellow; default: return .red }
    }
}

private struct AgentNodeRow: View {
    @ObservedObject var state: AppState
    let agent: Agents.Agent
    let node: Agents.Node
    @State private var hovering = false

    private var isRoot: Bool { node.depth == 0 }

    var body: some View {
        HStack(spacing: 6) {
            if node.depth > 0 {
                Spacer().frame(width: CGFloat(node.depth) * 14)
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(node.proc.name)
                    .font(.system(size: 12.5, weight: isRoot ? .semibold : .regular))
                    .lineLimit(1)
                Text(node.proc.command)
                    .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Text("\(Format.cpu(node.proc.cpuPercent)) · \(Format.memory(node.proc.memoryBytes))")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(.tertiary)
                .layoutPriority(1)
            actions
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.06) : .clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var actions: some View {
        HStack(spacing: 1) {
            Menu {
                Button("Kill (SIGTERM)") { state.killPID(node.proc.pid, force: false) }
                Button("Force Kill (SIGKILL)") { state.killPID(node.proc.pid, force: true) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 24)
        }
        .opacity(hovering ? 1 : 0.0)
        .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}
