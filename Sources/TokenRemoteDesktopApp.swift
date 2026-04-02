import SwiftUI
import ServiceManagement

@main
struct TokenRemoteDesktopApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var daemonManager = DaemonManager()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(daemon: daemonManager)
        } label: {
            Image(systemName: daemonManager.statusIcon)
                .symbolRenderingMode(.palette)
                .foregroundStyle(daemonManager.statusColor)
        }
        .menuBarExtraStyle(.window)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
