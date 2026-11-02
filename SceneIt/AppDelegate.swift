import AppKit
import SceneItCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let diagnostics = DiagnosticsController.shared
    private var lastSession = LastSession.cleanLastTime

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
        lastSession = diagnostics.start()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let lastSession = lastSession
        Task { diagnostics.offerReport(after: lastSession) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        diagnostics.stop()
    }
}
