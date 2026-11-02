import AppKit
import SceneItCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let diagnostics = DiagnosticsController.shared
    private let books = BookController.shared
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
        /// Holding the lock; collecting the books this launch was asked to open, which AppKit
        /// delivers before `applicationDidFinishLaunching`.
        case starting(LastSession, books: [URL])
        case running
        /// Waiting for the book to be saved before replying to `applicationShouldTerminate`.
        case quitting
        /// Another instance holds the lock; collecting the books to forward to it.
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
            phase = .starting(lastSession, books: [])
        case .handOff:
            Log.app.info("another instance is running; handing off to it")
            phase = .handingOff(books: [])
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        switch phase {
        case .handingOff(let books):
            phase = .handingOff(books: books + urls)
        case .starting(let lastSession, let books):
            phase = .starting(lastSession, books: books + urls)
        case .running:
            Log.app.info("asked to open books", ["count": .count(urls.count)])
            Task { await books.store.open(urls) }
        case .quitting:
            Log.app.info(
                "asked to open books while quitting; not opening them", ["count": .count(urls.count)])
        case .launching:
            Log.app.error("asked to open books before launching", ["count": .count(urls.count)])
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        switch phase {
        case .starting(let lastSession, let requested):
            phase = .running
            let lastSaved = books.memory.lastSaved
            Task {
                diagnostics.offerReport(after: lastSession, lastSaved: lastSaved)
                await books.launch(opening: requested)
            }
        case .handingOff(let books):
            InstanceHandoff.forward(books) { NSApp.terminate(nil) }
        case .launching, .running, .quitting:
            break
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        books.store.appDeactivated()
    }

    /// Replies later, once the book is saved or the writer has chosen (`QuitWording`).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        switch phase {
        case .running:
            phase = .quitting
            Task {
                switch await books.store.prepareToQuit() {
                case .left:
                    sender.reply(toApplicationShouldTerminate: true)
                case .stayed:
                    phase = .running
                    sender.reply(toApplicationShouldTerminate: false)
                }
            }
            return .terminateLater
        case .quitting:
            return .terminateCancel
        case .launching, .starting, .handingOff:
            return .terminateNow
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        switch phase {
        case .starting, .running, .quitting:
            books.store.closeForTermination()
            diagnostics.stop()
        case .launching, .handingOff:
            break
        }
    }
}
