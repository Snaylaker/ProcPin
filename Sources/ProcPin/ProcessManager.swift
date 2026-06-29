import Foundation
import Darwin

/// Queries the OS for process info and performs kill / restart actions.
///
/// We shell out to `ps` for listing and timing because it is robust across
/// macOS versions and avoids fragile C-interop with libproc. Signal delivery
/// uses the native `kill(2)` syscall.
enum ProcessManager {

    // MARK: - Live process listing

    /// A snapshot of a currently running process, used by the "pin" picker.
    struct LiveProcess {
        let pid: Int32
        let startDate: Date
        let command: String
        let cpuPercent: Double
        let memoryBytes: UInt64
        /// Short name derived from the command (basename of argv[0]).
        var name: String {
            let exe = command.split(separator: " ").first.map(String.init) ?? command
            return (exe as NSString).lastPathComponent
        }
    }

    private static let lstartFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return f
    }()

    /// Returns all running processes owned by the user, newest first.
    static func listProcesses() -> [LiveProcess] {
        // pid, %cpu, rss(KB), lstart (5 tokens), then full command.
        guard let out = runCapturing("/bin/ps", ["-axo", "pid=,%cpu=,rss=,lstart=,command="]) else {
            return []
        }
        var result: [LiveProcess] = []
        for line in out.split(separator: "\n") {
            guard let proc = parsePSLine(String(line)) else { continue }
            result.append(proc)
        }
        // Newest started first feels most useful when pinning.
        return result.sorted { $0.startDate > $1.startDate }
    }

    /// A process row including its parent pid, for building process trees.
    struct ProcRow {
        let pid: Int32
        let ppid: Int32
        let startDate: Date
        let command: String
        let cpuPercent: Double
        let memoryBytes: UInt64
        let stat: String        // ps state code, e.g. "S", "R", "T" (stopped)
        var isStopped: Bool { stat.contains("T") }
        var name: String {
            let exe = command.split(separator: " ").first.map(String.init) ?? command
            return (exe as NSString).lastPathComponent
        }
    }

    /// Returns every process with its parent pid (for process-tree views).
    static func listAllDetailed() -> [ProcRow] {
        // pid, ppid, %cpu, rss(KB), state, lstart (5 tokens), then full command.
        guard let out = runCapturing("/bin/ps", ["-axo", "pid=,ppid=,%cpu=,rss=,state=,lstart=,command="]) else {
            return []
        }
        var result: [ProcRow] = []
        for line in out.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // pid + ppid + cpu + rss + state + 5 lstart + >=1 command = 11
            guard parts.count >= 11,
                  let pid = Int32(parts[0]),
                  let ppid = Int32(parts[1]) else { continue }
            let cpu = Double(parts[2]) ?? 0
            let rssKB = UInt64(parts[3]) ?? 0
            let stat = parts[4]
            let lstart = parts[5...9].joined(separator: " ")
            guard let start = lstartFormatter.date(from: lstart) else { continue }
            let command = parts[10...].joined(separator: " ")
            result.append(ProcRow(pid: pid, ppid: ppid, startDate: start, command: command,
                                  cpuPercent: cpu, memoryBytes: rssKB * 1024, stat: stat))
        }
        return result
    }

    /// Parses a line of `ps -axo pid=,%cpu=,rss=,lstart=,command=`.
    /// Example: "1234 12.3 123456 Mon Jun 29 16:17:00 2026 /usr/bin/node server.js"
    private static func parsePSLine(_ line: String) -> LiveProcess? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // Need: pid + cpu + rss + 5 lstart tokens + at least 1 command token.
        guard parts.count >= 9, let pid = Int32(parts[0]) else { return nil }
        let cpu = Double(parts[1]) ?? 0
        let rssKB = UInt64(parts[2]) ?? 0
        let lstart = parts[3...7].joined(separator: " ")
        guard let startDate = lstartFormatter.date(from: lstart) else { return nil }
        let command = parts[8...].joined(separator: " ")
        return LiveProcess(
            pid: pid,
            startDate: startDate,
            command: command,
            cpuPercent: cpu,
            memoryBytes: rssKB * 1024
        )
    }

    // MARK: - Status of a pinned process

    private struct Sample {
        let start: Date
        let cpu: Double
        let memoryBytes: UInt64
    }

    /// One `ps` call returning start time + CPU + memory for a pid.
    private static func sample(forPID pid: Int32) -> Sample? {
        guard let out = runCapturing("/bin/ps", ["-o", "lstart=,%cpu=,rss=", "-p", "\(pid)"]) else {
            return nil
        }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // lstart (5) + cpu + rss
        guard parts.count >= 7 else { return nil }
        let lstart = parts[0...4].joined(separator: " ")
        guard let start = lstartFormatter.date(from: lstart) else { return nil }
        let cpu = Double(parts[5]) ?? 0
        let rssKB = UInt64(parts[6]) ?? 0
        return Sample(start: start, cpu: cpu, memoryBytes: rssKB * 1024)
    }

    /// Computes status for many pins using a SINGLE `ps` call (instead of one
    /// per pin). This is the hot path used by the periodic refresh.
    static func statuses(for pins: [PinnedProcess]) -> [UUID: ProcessStatus] {
        guard !pins.isEmpty else { return [:] }
        let rows = listAllDetailed()
        var byPID: [Int32: ProcRow] = [:]
        byPID.reserveCapacity(rows.count)
        for r in rows { byPID[r.pid] = r }

        let now = Date()
        var result: [UUID: ProcessStatus] = [:]
        result.reserveCapacity(pins.count)
        for pin in pins {
            guard let r = byPID[pin.pid] else {
                result[pin.id] = ProcessStatus(pin: pin, isRunning: false, uptimeSeconds: nil,
                                               cpuPercent: nil, memoryBytes: nil)
                continue
            }
            // Guard against PID reuse by comparing start times.
            if let recorded = pin.observedStartEpoch,
               abs(r.startDate.timeIntervalSince1970 - recorded) > 2 {
                result[pin.id] = ProcessStatus(pin: pin, isRunning: false, uptimeSeconds: nil,
                                               cpuPercent: nil, memoryBytes: nil)
                continue
            }
            result[pin.id] = ProcessStatus(pin: pin, isRunning: true,
                                           uptimeSeconds: now.timeIntervalSince(r.startDate),
                                           cpuPercent: r.cpuPercent, memoryBytes: r.memoryBytes,
                                           isPaused: r.isStopped)
        }
        return result
    }

    /// Single-pin status (used by one-off calls, not the refresh loop).
    static func status(for pin: PinnedProcess) -> ProcessStatus {
        guard let sample = sample(forPID: pin.pid) else {
            return ProcessStatus(pin: pin, isRunning: false, uptimeSeconds: nil,
                                 cpuPercent: nil, memoryBytes: nil)
        }
        if let recorded = pin.observedStartEpoch,
           abs(sample.start.timeIntervalSince1970 - recorded) > 2 {
            return ProcessStatus(pin: pin, isRunning: false, uptimeSeconds: nil,
                                 cpuPercent: nil, memoryBytes: nil)
        }
        return ProcessStatus(pin: pin, isRunning: true,
                             uptimeSeconds: Date().timeIntervalSince(sample.start),
                             cpuPercent: sample.cpu, memoryBytes: sample.memoryBytes)
    }

    /// Returns the start date of a pid, or nil if it isn't running.
    static func startDate(forPID pid: Int32) -> Date? {
        sample(forPID: pid)?.start
    }

    /// Returns the full command line of a pid, if available.
    static func commandLine(forPID pid: Int32) -> String? {
        guard let out = runCapturing("/bin/ps", ["-o", "command=", "-p", "\(pid)"]) else {
            return nil
        }
        let s = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    /// Returns the pids running on a tty (e.g. "ttys003" or "/dev/ttys003").
    static func pids(onTTY tty: String) -> [Int32] {
        let dev = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
        guard !dev.isEmpty, let out = runCapturing("/bin/ps", ["-t", dev, "-o", "pid="]) else {
            return []
        }
        return out.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    // MARK: - Actions

    /// Sends SIGTERM (graceful) or SIGKILL (force) to a pid.
    @discardableResult
    static func kill(pid: Int32, force: Bool = false) -> Bool {
        let sig = force ? SIGKILL : SIGTERM
        return Darwin.kill(pid, sig) == 0
    }

    /// Suspends a process (SIGSTOP) — freezes it without terminating.
    @discardableResult
    static func suspend(pid: Int32) -> Bool { Darwin.kill(pid, SIGSTOP) == 0 }

    /// Resumes a suspended process (SIGCONT).
    @discardableResult
    static func resume(pid: Int32) -> Bool { Darwin.kill(pid, SIGCONT) == 0 }

    /// Kills the current process (if any) and relaunches it from its command
    /// line. Returns the new pid on success.
    @discardableResult
    static func restart(_ pin: PinnedProcess) -> Int32? {
        if startDate(forPID: pin.pid) != nil {
            _ = kill(pid: pin.pid, force: false)
            // Give it a brief moment to exit before relaunch.
            usleep(300_000)
            if startDate(forPID: pin.pid) != nil {
                _ = kill(pid: pin.pid, force: true)
                usleep(200_000)
            }
        }
        return launch(command: pin.command, workingDirectory: pin.workingDirectory)
    }

    /// Launches a command line via `/bin/sh -lc`, detached from this app, and
    /// returns the spawned shell's pid.
    @discardableResult
    static func launch(command: String, workingDirectory: String?) -> Int32? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-lc", command]
        if let wd = workingDirectory {
            task.currentDirectoryURL = URL(fileURLWithPath: wd)
        }
        task.standardInput = FileHandle.nullDevice
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            return task.processIdentifier
        } catch {
            return nil
        }
    }

    // MARK: - Shell helper

    /// Runs an executable and returns stdout as a string, or nil on failure.
    private static func runCapturing(_ path: String, _ args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
