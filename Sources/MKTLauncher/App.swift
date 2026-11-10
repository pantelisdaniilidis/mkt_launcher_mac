import SwiftUI
import AppKit

@main
struct MKTLauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = ConnectionStore()
    @AppStorage(FunctionKeys.enabledKey) private var standardFKeys = true
    @AppStorage(TerminalSession.commandAsControlKey) private var commandAsControl = true

    var body: some Scene {
        Window("MKT Launcher", id: "launcher") {
            LauncherView()
                .environmentObject(store)
        }
        .defaultSize(width: 480, height: 420)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Session") {
                // ⌘R itself is sent to the host as Ctrl-R (⌘ = Ctrl rule).
                Button("Reconnect") { TerminalSession.current?.reconnect() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Disconnect") { TerminalSession.current?.disconnect() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Divider()
                Toggle("F1–F12 Without fn", isOn: $standardFKeys)
                    .onChange(of: standardFKeys) { on in
                        if on { FunctionKeys.appDidBecomeActive() } else { FunctionKeys.appDidResignActive() }
                    }
                Toggle("⌘ Acts as Ctrl (⌘Z = Ctrl-Z)", isOn: $commandAsControl)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidBecomeActive(_ notification: Notification) {
        FunctionKeys.appDidBecomeActive()
    }

    func applicationDidResignActive(_ notification: Notification) {
        FunctionKeys.appDidResignActive()
    }

    func applicationWillTerminate(_ notification: Notification) {
        FunctionKeys.appDidResignActive()
    }

    /// Double-clicking a .mkt file in Finder opens it straight away, like KoalaTerm did.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if let c = MKTImporter.load(url) {
                TerminalSession.start(c)
            } else {
                let alert = NSAlert()
                alert.messageText = "Cannot open \(url.lastPathComponent)"
                alert.informativeText = "It doesn't look like a KoalaTerm setup file."
                alert.runModal()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let n = TerminalSession.connectedCount
        guard n > 0 else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = n == 1 ? "1 session is still connected." : "\(n) sessions are still connected."
        alert.informativeText = "Quitting will disconnect them."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            TerminalSession.closeAll()
            return .terminateNow
        }
        return .terminateCancel
    }
}
