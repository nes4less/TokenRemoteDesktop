import SwiftUI

struct MenuBarView: View {
    let daemon: DaemonManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header
            HStack {
                Circle()
                    .fill(daemon.statusColor)
                    .frame(width: 8, height: 8)
                Text("Token Remote")
                    .font(.headline)
                Spacer()
                Text(daemon.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            // Stats
            if daemon.state == .running || daemon.state == .starting {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                    GridRow {
                        Text("Uptime")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(daemon.uptimeString)
                            .font(.caption.monospaced())
                    }
                    GridRow {
                        Text("Tasks")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("\(daemon.tasksCompleted) completed")
                            .font(.caption.monospaced())
                    }
                    if daemon.restartCount > 0 {
                        GridRow {
                            Text("Restarts")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(daemon.restartCount)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.orange)
                        }
                    }
                    if daemon.pollErrors > 0 {
                        GridRow {
                            Text("Poll Errors")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text("\(daemon.pollErrors)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.red)
                        }
                    }
                }
            }

            // Last task
            if let cmd = daemon.lastTaskCommand {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text("Last Task")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if let at = daemon.lastTaskAt {
                            Text(at, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(cmd)
                        .font(.caption2.monospaced())
                        .lineLimit(2)
                }
            }

            // Error
            if let error = daemon.lastError {
                Divider()
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }

            // Recent logs
            if !daemon.recentLogs.isEmpty {
                Divider()
                DisclosureGroup {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(daemon.recentLogs.enumerated()), id: \.offset) { _, line in
                            Text(stripTimestamp(line))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                } label: {
                    Text("Recent Logs")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Settings
            Toggle("Launch at Login", isOn: Binding(
                get: { daemon.launchAtLogin },
                set: { daemon.launchAtLogin = $0 }
            ))
            .font(.caption)
            .toggleStyle(.switch)
            .controlSize(.mini)

            Divider()

            // Actions
            HStack(spacing: 12) {
                if daemon.state == .running || daemon.state == .starting {
                    Button("Stop") { daemon.stop() }
                        .buttonStyle(.borderless)
                    Button("Restart") { daemon.restart() }
                        .buttonStyle(.borderless)
                } else {
                    Button("Start") { daemon.start() }
                        .buttonStyle(.borderless)
                }
                Spacer()
                Button("Quit") {
                    daemon.stop()
                    NSApp.terminate(nil)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            .font(.caption)
        }
        .padding(12)
        .frame(width: 300)
    }

    private func stripTimestamp(_ line: String) -> String {
        // Remove [2026-04-02T01:17:20.791Z] prefix
        if line.hasPrefix("[") {
            if let end = line.firstIndex(of: "]") {
                let next = line.index(after: end)
                let rest = line[next...].drop(while: { $0 == " " })
                return String(rest)
            }
        }
        return line
    }
}
