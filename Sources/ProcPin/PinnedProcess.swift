import Foundation

/// A process the user has pinned to the menu bar.
///
/// We persist the identifying info needed to (a) find the live process again
/// and (b) relaunch it if it was killed. PIDs are reused by the OS, so we also
/// store the original command line and a captured start time to detect when a
/// pinned PID has been replaced by an unrelated process.
struct PinnedProcess: Codable, Identifiable, Equatable {
    /// Stable identifier for the pin itself (not the OS pid).
    let id: UUID
    /// Last known OS process id. May become stale if the process exits.
    var pid: Int32
    /// Short display name (e.g. "node").
    var name: String
    /// Full command line used to launch the process, for restart.
    var command: String
    /// Working directory captured at pin time, used when relaunching.
    var workingDirectory: String?
    /// Unix epoch seconds of the process start time we last observed.
    /// Used to validate that `pid` still refers to the same process.
    var observedStartEpoch: Double?

    /// User-defined project grouping (e.g. "Project One"). Empty == ungrouped.
    var project: String
    /// User-defined role within the project (e.g. "Frontend", "Backend").
    var role: String
    /// tmux pane id (e.g. "%3") if this pin originated from a tmux pane.
    /// Lets us close the pane when removing the process.
    var tmuxPaneId: String?
    /// Stable source key (tmux pane id or Ghostty tty) for identity reuse.
    var sourceKey: String?

    init(
        id: UUID = UUID(),
        pid: Int32,
        name: String,
        command: String,
        workingDirectory: String? = nil,
        observedStartEpoch: Double? = nil,
        project: String = "",
        role: String = "",
        tmuxPaneId: String? = nil,
        sourceKey: String? = nil
    ) {
        self.id = id
        self.pid = pid
        self.name = name
        self.command = command
        self.workingDirectory = workingDirectory
        self.observedStartEpoch = observedStartEpoch
        self.project = project
        self.role = role
        self.tmuxPaneId = tmuxPaneId
        self.sourceKey = sourceKey
    }

    /// True when this row comes from tmux (vs Ghostty).
    var isTmux: Bool { tmuxPaneId?.isEmpty == false }

    // Backward-compatible decoding.
    enum CodingKeys: String, CodingKey {
        case id, pid, name, command, workingDirectory, observedStartEpoch, project, role, tmuxPaneId, sourceKey
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        pid = try c.decode(Int32.self, forKey: .pid)
        name = try c.decode(String.self, forKey: .name)
        command = try c.decode(String.self, forKey: .command)
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        observedStartEpoch = try c.decodeIfPresent(Double.self, forKey: .observedStartEpoch)
        project = try c.decodeIfPresent(String.self, forKey: .project) ?? ""
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        tmuxPaneId = try c.decodeIfPresent(String.self, forKey: .tmuxPaneId)
        sourceKey = try c.decodeIfPresent(String.self, forKey: .sourceKey)
    }
}

/// Live, computed status for a pinned process, recomputed on each refresh.
struct ProcessStatus: Equatable {
    let pin: PinnedProcess
    /// True if a live process matching the pin is currently running.
    let isRunning: Bool
    /// Seconds the process has been running, if running.
    let uptimeSeconds: TimeInterval?
    /// Recent CPU usage as a percentage (0–100+, can exceed 100 on multicore).
    let cpuPercent: Double?
    /// Resident memory in bytes.
    let memoryBytes: UInt64?
    /// True if the process is suspended (SIGSTOP / ps state "T").
    var isPaused: Bool = false
    /// TCP ports the process is listening on (for "open in browser").
    var ports: [Int] = []
}
