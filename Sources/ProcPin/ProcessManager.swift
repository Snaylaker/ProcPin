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

    /// Resolves the live status (running, uptime, CPU, memory) for a pin.
    ///
    /// A pin is considered running only if a process with its pid exists AND,
    /// when we have a recorded start time, that start time still matches (to
    /// guard against PID reuse).
    static func status(for pin: PinnedProcess) -> ProcessStatus {
        guard let sample = sample(forPID: pin.pid) else {
            return ProcessStatus(pin: pin, isRunning: false, uptimeSeconds: nil,
                                 cpuPercent: nil, memoryBytes: nil)
        }
        if let recorded = pin.observedStartEpoch {
            // Allow a couple seconds of slack for formatting rounding.
            if abs(sample.start.timeIntervalSince1970 - recorded) > 2 {
                return ProcessStatus(pin: pin, isRunning: false, uptimeSeconds: nil,
                                     cpuPercent: nil, memoryBytes: nil)
            }
        }
        let uptime = Date().timeIntervalSince(sample.start)
        return ProcessStatus(pin: pin, isRunning: true, uptimeSeconds: uptime,
                             cpuPercent: sample.cpu, memoryBytes: sample.memoryBytes)
    }

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

    // MARK: - Actions

    /// Sends SIGTERM (graceful) or SIGKILL (force) to a pid.
    @discardableResult
    static func kill(pid: Int32, force: Bool = false) -> Bool {
        let sig = force ? SIGKILL : SIGTERM
        return Darwin.kill(pid, sig) == 0
    }

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
