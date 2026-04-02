import Foundation
import Observation
import SwiftUI
import ServiceManagement
import os

private let logger = Logger(subsystem: "com.tokenremote.desktop", category: "DaemonManager")

enum DaemonState: String {
    case stopped = "Stopped"
    case starting = "Starting"
    case running = "Running"
    case crashed = "Crashed"
}

@MainActor
@Observable
final class DaemonManager {
    // MARK: - Public state
    var state: DaemonState = .stopped
    var restartCount: Int = 0
    var lastError: String?
    var lastLogLine: String?
    private(set) var startedAt: Date?
    var autoStartOnInit = true

    // Task tracking
    var lastTaskCommand: String?
    var lastTaskAt: Date?
    var tasksCompleted: Int = 0
    var pollErrors: Int = 0
    var recentLogs: [String] = []
    private let maxRecentLogs = 8

    // Uptime refresh
    var uptimeTick: Int = 0

    // Login Item — cached to avoid TCC blocking on main thread
    private var _launchAtLoginCached: Bool?
    var launchAtLogin: Bool {
        get {
            if let cached = _launchAtLoginCached { return cached }
            let status = SMAppService.mainApp.status == .enabled
            _launchAtLoginCached = status
            return status
        }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                _launchAtLoginCached = newValue
                logger.info("Launch at login: \(newValue)")
            } catch {
                logger.error("Failed to set launch at login: \(error.localizedDescription)")
            }
        }
    }

    init() {
        // Launch daemon from a background thread to avoid blocking during SwiftUI setup.
        // Process.run() does not require the main thread.
        let script = daemonScript
        let dir = daemonDir
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) { [weak self] in
            self?.launchDaemonFromBackground(script: script, dir: dir)
        }

        // Uptime refresh timer
        Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                self.uptimeTick += 1
            }
        }
    }

    // MARK: - Computed
    var statusIcon: String {
        switch state {
        case .running: "circle.fill"
        case .starting: "circle.dotted"
        case .stopped: "circle"
        case .crashed: "exclamationmark.circle.fill"
        }
    }

    var statusColor: Color {
        switch state {
        case .running: .green
        case .starting: .yellow
        case .stopped: .secondary
        case .crashed: .red
        }
    }

    var statusText: String { state.rawValue }

    var uptimeString: String {
        _ = uptimeTick // trigger refresh
        guard let started = startedAt else { return "—" }
        let elapsed = Date().timeIntervalSince(started)
        let h = Int(elapsed) / 3600
        let m = (Int(elapsed) % 3600) / 60
        let s = Int(elapsed) % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        return String(format: "%dm %02ds", m, s)
    }

    // MARK: - Private
    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var backoffSeconds: TimeInterval = 2
    private var lastHealthyAt: Date?
    private var autoRestart = true
    private let maxBackoff: TimeInterval = 60
    private let healthyResetThreshold: TimeInterval = 30

    /// PID of an externally-started daemon we adopted (not our child process)
    private var adoptedPID: Int32?

    // MARK: - Node resolution (nonisolated — safe to call from any thread)
    private nonisolated func resolveNodePath() -> String? {
        let candidates = [
            "/usr/local/bin/node",
            "/opt/homebrew/bin/node",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        let which = Process()
        let pipe = Pipe()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = ["node"]
        which.standardOutput = pipe
        which.standardError = FileHandle.nullDevice
        try? which.run()
        which.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private nonisolated var daemonScript: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.token-remote/daemon/index.mjs"
    }

    private nonisolated var daemonDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.token-remote/daemon"
    }

    // MARK: - Existing process detection (nonisolated)

    private nonisolated func findExistingDaemonPID() -> Int32? {
        let pgrep = Process()
        let pipe = Pipe()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        // Match only node processes running the daemon script (excludes shell/grep matches)
        pgrep.arguments = ["-f", "node.*token-remote/daemon/index.mjs"]
        pgrep.standardOutput = pipe
        pgrep.standardError = FileHandle.nullDevice
        try? pgrep.run()
        pgrep.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !output.isEmpty else { return nil }
        return output.split(separator: "\n").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }.first
    }

    // MARK: - Background launch (called from GCD, not main actor)

    /// Launches the daemon process entirely from a background thread.
    /// Only touches MainActor for state updates via Task{}.
    private nonisolated func launchDaemonFromBackground(script: String, dir: String) {
        // Check for existing daemon
        if let pid = findExistingDaemonPID() {
            Task { @MainActor [weak self] in self?.adoptExistingDaemon(pid: pid) }
            return
        }

        guard let nodePath = resolveNodePath() else {
            Task { @MainActor [weak self] in
                self?.lastError = "Node.js not found. Install from nodejs.org"
                self?.state = .crashed
            }
            return
        }

        guard FileManager.default.fileExists(atPath: script) else {
            Task { @MainActor [weak self] in
                self?.lastError = "Daemon script not found"
                self?.state = .crashed
            }
            return
        }


        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodePath)
        proc.arguments = [script]
        proc.currentDirectoryURL = URL(fileURLWithPath: dir)

        var env = ProcessInfo.processInfo.environment
        env["FORCE_COLOR"] = "0"
        env["NO_COLOR"] = "1"
        proc.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        // Termination handler (runs on arbitrary thread)
        proc.terminationHandler = { [weak self] p in
            let code = p.terminationStatus
            Task { @MainActor in self?.handleTermination(exitCode: code) }
        }

        // Pipe handlers (run on arbitrary thread, dispatch to MainActor)
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            let parsedLines = lines.map { String($0.prefix(200)) }
            let isHealthy = lines.contains { $0.contains("poll loop") || $0.contains("Device registered") }

            var taskCommand: String?
            var taskCompleted = false
            var pollErrorCount = 0
            for line in lines {
                if line.contains("Running task") || line.contains("Sending instruction"),
                   let r = line.range(of: ": ", options: .backwards) {
                    taskCommand = String(line[r.upperBound...].prefix(100))
                }
                if line.contains("Task") && line.contains("complete") { taskCompleted = true }
                if line.contains("Poll error") { pollErrorCount += 1 }
            }

            Task { @MainActor in
                guard let self else { return }
                self.lastLogLine = parsedLines.last
                for line in parsedLines { self.recentLogs.append(line) }
                while self.recentLogs.count > self.maxRecentLogs { self.recentLogs.removeFirst() }
                if isHealthy {
                    self.state = .running
                    self.startedAt = self.startedAt ?? Date()
                    self.lastHealthyAt = Date()
                }
                if let cmd = taskCommand { self.lastTaskCommand = cmd; self.lastTaskAt = Date() }
                if taskCompleted { self.tasksCompleted += 1 }
                self.pollErrors += pollErrorCount
            }
        }

        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let errorText = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
            Task { @MainActor in self?.lastError = errorText }
        }

        do {
            try proc.run()
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.process = proc
                self.stdoutPipe = stdout
                self.stderrPipe = stderr
                self.state = .starting
                self.startedAt = Date()
                // Mark running after a moment
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(3))
                    if self.state == .starting {
                        self.state = .running
                        self.lastHealthyAt = Date()
                    }
                }
            }
        } catch {
            Task { @MainActor [weak self] in
                self?.state = .crashed
                self?.lastError = error.localizedDescription
            }
        }
    }

    // MARK: - Adopt existing daemon

    private func adoptExistingDaemon(pid: Int32) {
        adoptedPID = pid
        state = .running
        startedAt = Date()
        lastHealthyAt = Date()
        lastError = nil

        Task { @MainActor in
            while self.state == .running {
                try? await Task.sleep(for: .seconds(5))
                let alive = kill(pid, 0) == 0
                if !alive {
                    self.adoptedPID = nil
                    self.startedAt = nil
                    self.handleTermination(exitCode: 1)
                    break
                }
                self.uptimeTick += 1
            }
        }
    }

    // MARK: - Lifecycle

    func start() {
        guard state != .running && state != .starting else { return }

        // Check for an existing daemon before spawning
        if let existingPID = findExistingDaemonPID() {
            adoptExistingDaemon(pid: existingPID)
            return
        }

        let script = daemonScript
        let dir = daemonDir
        state = .starting
        lastError = nil

        // Launch from background to avoid blocking main thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.launchDaemonFromBackground(script: script, dir: dir)
        }
    }

    func stop() {
        autoRestart = false
        killProcess()
        state = .stopped
        startedAt = nil
        adoptedPID = nil
        autoRestart = true
    }

    func restart() {
        autoRestart = true
        killProcess()
        backoffSeconds = 2
        restartCount += 1
        adoptedPID = nil
        start()
    }

    private func killProcess() {
        if let pid = adoptedPID {
            kill(pid, SIGTERM)
            adoptedPID = nil
        }
        guard let proc = process, proc.isRunning else { return }
        proc.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if proc.isRunning { proc.interrupt() }
        }
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
    }

    private func handleTermination(exitCode: Int32) {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        startedAt = nil

        if !autoRestart {
            state = .stopped
            return
        }

        state = .crashed
        restartCount += 1

        if let healthy = lastHealthyAt,
           Date().timeIntervalSince(healthy) > healthyResetThreshold {
            backoffSeconds = 2
        }

        let delay = backoffSeconds
        lastError = "Exited with code \(exitCode). Restarting in \(Int(delay))s..."
        backoffSeconds = min(backoffSeconds * 1.5, maxBackoff)

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.autoRestart, self.state == .crashed else { return }
            self.start()
        }
    }
}
