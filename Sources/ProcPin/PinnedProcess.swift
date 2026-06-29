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

    init(
        id: UUID = UUID(),
        pid: Int32,
        name: String,
        command: String,
        workingDirectory: String? = nil,
        observedStartEpoch: Double? = nil
    ) {
        self.id = id
        self.pid = pid
        self.name = name
        self.command = command
        self.workingDirectory = workingDirectory
        self.observedStartEpoch = observedStartEpoch
    }
}

/// Live, computed status for a pinned process, recomputed on each menu refresh.
struct ProcessStatus {
    let pin: PinnedProcess
    /// True if a live process matching the pin is currently running.
    let isRunning: Bool
    /// Seconds the process has been running, if running.
    let uptimeSeconds: TimeInterval?
}
