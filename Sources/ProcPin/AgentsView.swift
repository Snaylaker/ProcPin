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
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(state.agents) { agent in
                            AgentCard(state: state, agent: agent)
                        }
                    }
                    .padding(.vertical, 10)
                }
                .frame(maxHeight: 460)
            }
        }
        .onAppear { state.setAgentScanning(true) }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("No agents running")
                .font(.system(size: 13, weight: .semibold))
            Text("Start Claude Code, OpenCode, Codex, Aider, Gemini, Goose or pi and they'll appear here with their spawned processes.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                state.scanAgents()
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
        .padding(.horizontal, 24)
    }
}

private struct AgentCard: View {
    @ObservedObject var state: AppState
    let agent: Agents.Agent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            cardHeader
            VStack(spacing: 3) {
                ForEach(agent.nodes) { node in
                    AgentNodeRow(state: state, agent: agent, node: node)
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

    private var cardHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 12))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(agent.kind).font(.system(size: 13, weight: .bold))
                Text("PID \(agent.root.pid) · \(agent.childCount) spawned · up \(Format.uptime(uptime(agent.root.startDate)))")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text(Format.cpu(agent.totalCPU))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                Text(Format.memory(agent.totalMemory))
                    .font(.system(size: 10, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func uptime(_ start: Date) -> TimeInterval { Date().timeIntervalSince(start) }
}

private struct AgentNodeRow: View {
    @ObservedObject var state: AppState
    let agent: Agents.Agent
    let node: Agents.Node
    @State private var hovering = false

    private var isRoot: Bool { node.depth == 0 }

    var body: some View {
        HStack(spacing: 6) {
            // Tree indentation + branch glyph.
            if node.depth > 0 {
                Spacer().frame(width: CGFloat(node.depth) * 14)
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(node.proc.name)
                    .font(.system(size: 12, weight: isRoot ? .semibold : .regular))
                    .lineLimit(1)
                Text(node.proc.command)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            Text("\(Format.cpu(node.proc.cpuPercent)) · \(Format.memory(node.proc.memoryBytes))")
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(.tertiary)
                .layoutPriority(1)

            actions
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.06) : Color.white.opacity(0.001))
        )
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var actions: some View {
        HStack(spacing: 2) {
            IconButton(systemName: "pin", help: "Pin into a project", tint: .accentColor) {
                state.pinPID(node.proc.pid, name: node.proc.name,
                             project: agent.kind, role: isRoot ? "agent" : node.proc.name)
            }
            Menu {
                Button("Kill (SIGTERM)") { state.killPID(node.proc.pid, force: false) }
                Button("Force Kill (SIGKILL)") { state.killPID(node.proc.pid, force: true) }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 22, height: 20)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26)
        }
        .opacity(hovering ? 1 : 0.5)
    }
}
