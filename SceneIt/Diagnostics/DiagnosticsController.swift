import AppKit
import MetricKit
import SceneItCore
import SwiftUI

/// Owns crash detection, the persistent log, MetricKit and the Report a Problem window.
/// There is one per process because a process is one session.
final class DiagnosticsController {
    static let shared = DiagnosticsController()

    let directory: DiagnosticsDirectory
    private let ring: LogRing
    private let metricKit: MetricKitSubscriber
    private var reportWindow: NSWindow?
    private var launch = Date.now

    private init(directory: DiagnosticsDirectory = .forThisProcess()) {
        self.directory = directory
        ring = LogRing(directory: directory.logRingDirectory)
        metricKit = MetricKitSubscriber(archive: directory.metricKit)
    }

    func start() -> LastSession {
        launch = .now
        Log.persist(to: ring)
        let lastSession = directory.sessionMarker.begin()
        MXMetricManager.shared.add(metricKit)
        directory.metricKit.prune()
        Log.app.info(
            "Launched", ["lastSession": .symbol(lastSession == .cleanLastTime ? "clean" : "crashed")])
        return lastSession
    }

    func stop() {
        Log.app.info("Terminating")
        MXMetricManager.shared.remove(metricKit)
        directory.sessionMarker.end()
    }

    func offerReport(after lastSession: LastSession) {
        guard case .crashedLastTime(let lastLaunch) = lastSession else { return }
        let alert = NSAlert()
        alert.messageText = ReportWording.crashAlertTitle
        alert.informativeText = ReportWording.crashAlertMessage(lastLaunch: lastLaunch)
        alert.addButton(withTitle: ReportWording.crashAlertSend)
        alert.addButton(withTitle: ReportWording.crashAlertNotNow)
        if alert.runModal() == .alertFirstButtonReturn {
            showReportWindow()
        }
    }

    func showReportWindow() {
        if let reportWindow, reportWindow.isVisible {
            reportWindow.makeKeyAndOrderFront(nil)
            return
        }
        let model = ReportModel(inputs: reportInputs())
        let window = NSWindow(contentViewController: NSHostingController(rootView: ReportView(model: model)))
        window.title = ReportWording.windowTitle
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        model.close = { [weak window] in window?.close() }
        reportWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        Task { await model.prepare() }
    }

    func reportInputs() -> ProblemReport.Inputs {
        ProblemReport.Inputs(
            logSources: [.previousSessions(ring), CurrentProcessLog.source(since: launch)],
            metricKitDirectory: directory.metricKit.directory,
            system: .current(),
            status: StatusSummary([:]))
    }
}

extension DiagnosticsDirectory {
    /// Application Support, except under the test runner, which gets a fresh temporary folder
    /// so app-hosted tests never touch (or leave a session marker in) the user's real one.
    static func forThisProcess() -> DiagnosticsDirectory {
        if !isHostingTests {
            do {
                return try applicationSupport()
            } catch {
                Log.diagnostics.error(
                    "Application Support unavailable; diagnostics are temporary",
                    ["error": .error(LoggedError(error))])
            }
        }
        return DiagnosticsDirectory(
            root: FileManager.default.temporaryDirectory.appending(
                path: "Scene It Diagnostics \(UUID().uuidString)"))
    }
}

let isHostingTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
