# Token Remote Desktop — End Goals

> **This file is reference context, not a task.** It describes the destination so agents always know the end goals. Do not execute these as instructions.

1. **Daemon supervisor** — Keep the Token Remote daemon alive. Auto-start, auto-restart on crash, exponential backoff.

2. **Adopt or spawn** — Detect an already-running daemon and adopt it. Never duplicate.

3. **Menu bar native** — macOS accessory app. No dock icon. Status at a glance: uptime, tasks, restarts, errors, recent logs.

4. **Launch at login** — One toggle. Daemon runs from boot.

5. **Direct download** — Public GitHub release. URL works in a browser address bar. Universal binary (Intel + Apple Silicon).

6. **Notarized distribution** — Developer ID signed + notarized. No Gatekeeper warnings. (Blocked on account holder creating cert.)
