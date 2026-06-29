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
        // pid, lstart (5 tokens), then full command.
        guard let out = runCapturing("/bin/ps", ["-axo", "pid=,lstart=,command="]) else {
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

    /// Parses a line of `ps -axo pid=,lstart=,command=`.
    /// Example: "  1234 Mon Jun 29 16:17:00 2026 /usr/bin/node server.js"
    private static func parsePSLine(_ line: String) -> LiveProcess? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        // Need: pid + 5 lstart tokens + at least 1 command token.
        guard parts.count >= 7, let pid = Int32(parts[0]) else { return nil }
        let lstart = parts[1...5].joined(separator: " ")
        guard let startDate = lstartFormatter.date(from: lstart) else { return nil }
        let command = parts[6...].joined(separator: " ")
        return LiveProcess(pid: pid, startDate: startDate, command: command)
    }

    // MARK: - Status of a pinned process

    /// Resolves the live status (running + uptime) for a pin.
    ///
    /// A pin is considered running only if a process with its pid exists AND,
    /// when we have a recorded start time, that start time still matches (to
    /// guard against PID reuse).
    static func status(for pin: PinnedProcess) -> ProcessStatus {
        guard let start = startDate(forPID: pin.pid) else {
            return ProcessStatus(pin: pin, isRunning: false, uptimeSeconds: nil)
        }
        if let recorded = pin.observedStartEpoch {
            // Allow a couple seconds of slack for formatting rounding.
            if abs(start.timeIntervalSince1970 - recorded) > 2 {
                return ProcessStatus(pin: pin, isRunning: false, uptimeSeconds: nil)
            }
        }
        let uptime = Date().timeIntervalSince(start)
        return ProcessStatus(pin: pin, isRunning: true, uptimeSeconds: uptime)
    }

    /// Returns the start date of a pid, or nil if it isn't running.
    static func startDate(forPID pid: Int32) -> Date? {
        guard let out = runCapturing("/bin/ps", ["-o", "lstart=", "-p", "\(pid)"]) else {
            return nil
        }
        let s = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        return lstartFormatter.date(from: s)
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
