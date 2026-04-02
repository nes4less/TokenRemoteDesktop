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

    // Login Item
    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                logger.info("Launch at login: \(newValue)")
            } catch {
                logger.error("Failed to set launch at login: \(error.localizedDescription)")
            }
        }
    }

    init() {
        // Schedule auto-start after a brief delay to let SwiftUI finish setup
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            if self.autoStartOnInit && self.state == .stopped {
                self.start()
            }
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
    private let healthyThreshold: TimeInterval = 300 // 5 min before backoff resets

    // MARK: - Node resolution
    private func resolveNodePath() -> String? {
        let candidates = [
            "/usr/local/bin/node",
            "/opt/homebrew/bin/node",
        ]
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }
        // Try `which node` as fallback
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

    private var daemonScript: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.token-remote/daemon/index.mjs"
    }

    private var daemonDir: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.token-remote/daemon"
    }

    // MARK: - Lifecycle

    func start() {
        guard state != .running && state != .starting else { return }

        guard let nodePath = resolveNodePath() else {
            lastError = "Node.js not found. Install from nodejs.org"
            state = .crashed
            logger.error("Node binary not found")
            return
        }

        guard FileManager.default.fileExists(atPath: daemonScript) else {
            lastError = "Daemon script not found at \(daemonScript)"
            state = .crashed
            logger.error("Daemon script missing: \(self.daemonScript)")
            return
        }

        state = .starting
        lastError = nil
        logger.info("Starting daemon: \(nodePath) \(self.daemonScript)")

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: nodePath)
        proc.arguments = [daemonScript]
        proc.currentDirectoryURL = URL(fileURLWithPath: daemonDir)

        // Pass through environment so .env loaded by dotenv works
        var env = ProcessInfo.processInfo.environment
        env["FORCE_COLOR"] = "0"
        env["NO_COLOR"] = "1"
        proc.environment = env

        let stdout = Pipe()
        let stderr = Pipe()
        proc.standardOutput = stdout
        proc.standardError = stderr

        self.stdoutPipe = stdout
        self.stderrPipe = stderr
        self.process = proc

        // Read stdout
        stdout.fileHandleForReading.readabilityHandler = { @Sendable [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
            let parsedLines = lines.map { String($0.prefix(200)) }
            let isHealthy = lines.contains { $0.contains("poll loop") || $0.contains("Device registered") }

            // Parse task activity
            var taskCommand: String?
            var taskCompleted = false
            var pollErrorCount = 0
            for line in lines {
                if line.contains("Running task") || line.contains("Sending instruction") {
                    // Extract command after the colon
                    if let colonRange = line.range(of: ": ", options: .backwards) {
                        taskCommand = String(line[colonRange.upperBound...].prefix(100))
                    }
                }
                if line.contains("Task") && line.contains("complete") {
                    taskCompleted = true
                }
                if line.contains("Poll error") {
                    pollErrorCount += 1
                }
            }

            Task { @MainActor in
                guard let self else { return }
                self.lastLogLine = parsedLines.last
                for line in parsedLines {
                    self.recentLogs.append(line)
                }
                while self.recentLogs.count > self.maxRecentLogs {
                    self.recentLogs.removeFirst()
                }
                if isHealthy {
                    self.state = .running
                    self.startedAt = self.startedAt ?? Date()
                    self.lastHealthyAt = Date()
                }
                if let cmd = taskCommand {
                    self.lastTaskCommand = cmd
                    self.lastTaskAt = Date()
                }
                if taskCompleted {
                    self.tasksCompleted += 1
                }
                self.pollErrors += pollErrorCount
            }
            logger.debug("daemon: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // Read stderr
        stderr.fileHandleForReading.readabilityHandler = { @Sendable [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let errorText = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
            Task { @MainActor in
                self?.lastError = errorText
            }
            logger.error("daemon stderr: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        // Termination handler
        proc.terminationHandler = { @Sendable [weak self] p in
            let code = p.terminationStatus
            logger.info("Daemon exited with code \(code)")
            Task { @MainActor in
                self?.handleTermination(exitCode: code)
            }
        }

        do {
            try proc.run()
            startedAt = Date()
            // Give it a moment, then mark running if not already
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(3))
                if self?.state == .starting {
                    self?.state = .running
                    self?.lastHealthyAt = Date()
                }
            }
            logger.info("Daemon process launched (pid \(proc.processIdentifier))")
        } catch {
            state = .crashed
            lastError = error.localizedDescription
            logger.error("Failed to launch daemon: \(error.localizedDescription)")
        }
    }

    func stop() {
        autoRestart = false
        killProcess()
        state = .stopped
        startedAt = nil
        autoRestart = true // re-enable for next manual start
    }

    func restart() {
        autoRestart = true
        killProcess()
        backoffSeconds = 2
        restartCount += 1
        start()
    }

    private func killProcess() {
        guard let proc = process, proc.isRunning else { return }
        proc.terminate()
        // Give it 3 seconds to shutdown gracefully, then force kill
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
            if proc.isRunning {
                proc.interrupt() // SIGINT
            }
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

        // Reset backoff if daemon was healthy for a while
        if let healthy = lastHealthyAt,
           Date().timeIntervalSince(healthy) > healthyThreshold {
            backoffSeconds = 2
        }

        let delay = backoffSeconds
        logger.info("Daemon crashed (exit \(exitCode)). Restarting in \(delay)s...")
        lastError = "Exited with code \(exitCode). Restarting in \(Int(delay))s..."

        backoffSeconds = min(backoffSeconds * 2, maxBackoff)

        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.autoRestart, self.state == .crashed else { return }
            self.start()
        }
    }
}
