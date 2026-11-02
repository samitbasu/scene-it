import AppKit
import SceneItCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let diagnostics = DiagnosticsController.shared
    private var phase = Phase.launching

    /// The app-wide lock (ADR 0020), held until the process exits.
    private static var instanceLock: InstanceLock?

    static var instanceLockSummary: InstanceLockSummary? {
        switch instanceLock {
        case .some(let lock): lock.summary
        case .none: nil
        }
    }

    private enum Phase {
        case launching
        case running(LastSession)
        /// Another instance holds the lock; collecting the books this launch was asked to
        /// open, which AppKit delivers before `applicationDidFinishLaunching`.
        case handingOff(books: [URL])
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .aqua)
        let launch = LaunchGate.open(
            role: .current, acquire: { LaunchGate.acquire(SupportFolder.instanceLock) },
            startSession: { diagnostics.start() })
        switch consume launch {
        case .proceed(let lock, let lastSession):
            if case .unavailable = lock.summary {
                Log.app.error("couldn't take the app lock; running without it")
            }
            Self.instanceLock = consume lock
            phase = .running(lastSession)
        case .handOff:
            Log.app.info("another instance is running; handing off to it")
            phase = .handingOff(books: [])
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        switch phase {
        case .handingOff(let books):
            phase = .handingOff(books: books + urls)
        case .launching, .running:
            Log.app.info("asked to open books", ["count": .count(urls.count)])
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        switch phase {
        case .running(let lastSession):
            Task { diagnostics.offerReport(after: lastSession) }
        case .handingOff(let books):
            InstanceHandoff.forward(books) { NSApp.terminate(nil) }
        case .launching:
            break
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard case .running = phase else { return }
        diagnostics.stop()
    }
}
