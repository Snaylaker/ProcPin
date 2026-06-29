import Foundation

/// Detects running AI coding agents (Claude Code, OpenCode, pi, …) and builds
/// the live process tree of everything each one has spawned (MCP servers,
/// currently-running tool commands, sub-agents).
///
/// This is intentionally tool-agnostic: an agent is just a process, and the
/// things it runs are its OS child processes. We identify the *roots* by
/// command signature, then walk the parent→child map.
enum Agents {

    /// A flattened node in an agent's process tree.
    struct Node: Identifiable {
        let proc: ProcessManager.ProcRow
        let depth: Int            // 0 == agent root
        var id: Int32 { proc.pid }
    }

    /// A detected agent and its descendant processes.
    struct Agent: Identifiable {
        let kind: String          // e.g. "Claude Code"
        let root: ProcessManager.ProcRow
        let nodes: [Node]         // includes the root at depth 0
        var id: Int32 { root.pid }

        /// Number of spawned descendant processes (excluding the root).
        var childCount: Int { max(0, nodes.count - 1) }
        var totalCPU: Double { nodes.reduce(0) { $0 + $1.proc.cpuPercent } }
        var totalMemory: UInt64 { nodes.reduce(0) { $0 + $1.proc.memoryBytes } }
    }

    /// Command signatures that identify an agent. `keyword` is matched against
    /// the basename of any argv token (whole-word) so paths and node wrappers
    /// are handled.
    private static let signatures: [(keyword: String, label: String)] = [
        ("claude", "Claude Code"),
        ("opencode", "OpenCode"),
        ("codex", "Codex"),
        ("aider", "Aider"),
        ("gemini", "Gemini CLI"),
        ("cursor-agent", "Cursor Agent"),
        ("goose", "Goose"),
        ("pi", "pi")
    ]

    /// Scans all processes and returns the detected agents with their trees.
    static func scan() -> [Agent] {
        let rows = ProcessManager.listAllDetailed()
        guard !rows.isEmpty else { return [] }

        let byPID = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0) })
        var childrenByPPID: [Int32: [ProcessManager.ProcRow]] = [:]
        for r in rows { childrenByPPID[r.ppid, default: []].append(r) }

        // Identify candidate roots by signature.
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var rootKind: [Int32: String] = [:]
        for r in rows {
            if r.pid == ownPID { continue }
            if let label = matchLabel(for: r) {
                rootKind[r.pid] = label
            }
        }

        // A root is "top-level" only if none of its ancestors is also a root,
        // so nested sub-agents appear inside their parent's tree, not twice.
        func hasRootAncestor(_ pid: Int32) -> Bool {
            var cur = byPID[pid]?.ppid ?? 0
            var guardCount = 0
            while cur > 1, guardCount < 64 {
                if rootKind[cur] != nil { return true }
                cur = byPID[cur]?.ppid ?? 0
                guardCount += 1
            }
            return false
        }

        var agents: [Agent] = []
        for (pid, label) in rootKind where !hasRootAncestor(pid) {
            guard let root = byPID[pid] else { continue }
            let nodes = flatten(root: root, childrenByPPID: childrenByPPID)
            agents.append(Agent(kind: label, root: root, nodes: nodes))
        }
        // Newest agent first.
        return agents.sorted { $0.root.startDate > $1.root.startDate }
    }

    /// Returns the agent label if a process matches a known signature.
    private static func matchLabel(for r: ProcessManager.ProcRow) -> String? {
        // Build a set of basename tokens from the command line.
        let tokens = r.command.split(separator: " ").prefix(4).map {
            ($0 as NSString).lastPathComponent.lowercased()
        }
        let tokenSet = Set(tokens)
        for sig in signatures {
            // Whole-word/basename match avoids matching substrings like "epic".
            if tokenSet.contains(sig.keyword) { return sig.label }
            // Also handle "node /path/to/claude" where claude is a basename arg.
            if tokens.contains(where: { $0 == sig.keyword }) { return sig.label }
        }
        return nil
    }

    /// Depth-first flatten of a process and all its descendants.
    private static func flatten(
        root: ProcessManager.ProcRow,
        childrenByPPID: [Int32: [ProcessManager.ProcRow]]
    ) -> [Node] {
        var out: [Node] = []
        func visit(_ proc: ProcessManager.ProcRow, _ depth: Int) {
            out.append(Node(proc: proc, depth: depth))
            let kids = (childrenByPPID[proc.pid] ?? []).sorted { $0.pid < $1.pid }
            for k in kids where depth < 32 {
                visit(k, depth + 1)
            }
        }
        visit(root, 0)
        return out
    }

    /// Whether any agent is likely installed/runnable (used to show the tab).
    static var anyRunning: Bool { !scan().isEmpty }
}
