import Foundation

/// Resolves the *current task* an agent is working on by reading the latest
/// real user prompt from its active session transcript.
///
/// This is per-tool. Claude Code stores one JSONL transcript per session under
/// `~/.claude/projects/<encoded-cwd>/`. We locate the most-recently-modified
/// transcript for the agent's working directory and tail-read it (so we never
/// load huge files fully) to find the last genuine user prompt.
enum AgentTask {

    /// Returns the current task text for an agent, if resolvable.
    static func current(kind: String, cwd: String?) -> String? {
        guard let cwd, !cwd.isEmpty else { return nil }
        switch kind {
        case "Claude Code":
            return claudeTask(cwd: cwd)
        default:
            // Other tools (OpenCode SQLite, etc.) not yet supported.
            return nil
        }
    }

    // MARK: - Claude Code

    /// Claude encodes a project path by replacing "/" and "." with "-".
    private static func encodeClaudePath(_ path: String) -> String {
        String(path.map { ($0 == "/" || $0 == ".") ? "-" : $0 })
    }

    private static func claudeTask(cwd: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home
            .appendingPathComponent(".claude/projects", isDirectory: true)
            .appendingPathComponent(encodeClaudePath(cwd), isDirectory: true)

        guard let file = newestTranscript(in: dir) else { return nil }
        guard let tail = tailString(file, maxBytes: 96 * 1024) else { return nil }
        return latestUserPrompt(inJSONL: tail)
    }

    /// Newest `*.jsonl` (excluding `agent-*` sub-agent logs) in a directory.
    private static func newestTranscript(in dir: URL) -> URL? {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        let sessions = items.filter {
            $0.pathExtension == "jsonl" && !$0.lastPathComponent.hasPrefix("agent-")
        }
        return sessions.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return da < db
        }
    }

    // MARK: - Generic JSONL helpers

    /// Reads the last `maxBytes` of a file as a string (UTF-8, lossy at the cut).
    private static func tailString(_ url: URL, maxBytes: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        let start = end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    /// Finds the last genuine user prompt in a chunk of JSONL transcript.
    private static func latestUserPrompt(inJSONL text: String) -> String? {
        var last: String?
        for line in text.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let message = obj["message"] as? [String: Any],
                  (message["role"] as? String) == "user"
            else { continue }

            let txt = flattenText(message["content"]).trimmingCharacters(in: .whitespacesAndNewlines)
            if isRealPrompt(txt) {
                last = txt.replacingOccurrences(of: "\n", with: " ")
            }
        }
        return last
    }

    /// Flattens Claude message content (string, or array of blocks) to text.
    private static func flattenText(_ content: Any?) -> String {
        if let s = content as? String { return s }
        if let arr = content as? [[String: Any]] {
            return arr.compactMap { block -> String? in
                guard (block["type"] as? String) == "text" else { return nil }
                return block["text"] as? String
            }.joined(separator: " ")
        }
        return ""
    }

    /// Rejects empty text, slash-command wrappers, tool-result echoes, and
    /// interrupt markers so we keep only real user prompts.
    private static func isRealPrompt(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let markers = [
            "<local-command", "<command-name", "<command-message",
            "<command-args", "<command-stdout", "[Request interrupted"
        ]
        let head = String(text.prefix(40))
        for m in markers where head.contains(m) || text.contains(m) {
            return false
        }
        return true
    }
}
