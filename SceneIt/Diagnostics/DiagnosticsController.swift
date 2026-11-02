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
    /// The report being built for the open window, if any.
    private(set) var reportPreparation: Task<Void, Never>?

    private init(directory: DiagnosticsDirectory = .forThisProcess()) {
        self.directory = directory
        ring = LogRing(directory: directory.logRingDirectory)
        metricKit = MetricKitSubscriber(archive: directory.metricKit)
    }

    func start() -> LastSession {
        launch = .now
        // Logout, shutdown and idle termination must go through applicationWillTerminate,
        // or the marker would survive a clean exit and the next launch would report a crash.
        ProcessInfo.processInfo.disableSuddenTermination()
        ProcessInfo.processInfo.disableAutomaticTermination("Session marker is removed at termination")
        Log.persist(to: ring)
        let lastSession = directory.sessionMarker.begin(isLiveInstance: Self.isRunningSceneIt)
        MXMetricManager.shared.add(metricKit)
        directory.metricKit.prune()
        Log.app.info("Launched", ["lastSession": lastSession.logValue])
        return lastSession
    }

    nonisolated static func isRunningSceneIt(_ processID: Int32) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: processID) else { return false }
        return !app.isTerminated && app.bundleIdentifier == Bundle.main.bundleIdentifier
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
        let model = ReportModel(inputs: reportInputs(), reports: directory.reports)
        let window = NSWindow(contentViewController: NSHostingController(rootView: ReportView(model: model)))
        window.title = ReportWording.windowTitle
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        model.close = { [weak window] in window?.close() }
        reportWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        reportPreparation = Task { await model.prepare() }
    }

    func reportInputs() -> ProblemReport.Inputs {
        ProblemReport.Inputs(
            logSources: [.previousSessions(ring), CurrentProcessLog.source(since: launch)],
            metricKitDirectory: directory.metricKit.directory,
            crashReportsDirectory: directory.crashReports,
            system: .current(),
            status: StatusSummary([:]))
    }
}

extension LastSession {
    fileprivate var logValue: LogValue {
        switch self {
        case .cleanLastTime: .symbol("clean")
        case .crashedLastTime: .symbol("crashed")
        case .anotherInstanceRunning: .symbol("anotherInstanceRunning")
        }
    }
}

extension DiagnosticsDirectory {
    /// Application Support, except under the test runner and SwiftUI previews, which get a
    /// temporary folder (emptied at each launch) so they never touch the user's real files.
    static func forThisProcess() -> DiagnosticsDirectory {
        if !usesTemporaryDiagnostics {
            do {
                return try applicationSupport()
            } catch {
                Log.diagnostics.error(
                    "Application Support unavailable; diagnostics are temporary",
                    ["error": .error(LoggedError(error))])
            }
        }
        return temporary(
            at: FileManager.default.temporaryDirectory.appending(path: "Scene It Test Diagnostics"))
    }
}

let usesTemporaryDiagnostics: Bool = {
    let environment = ProcessInfo.processInfo.environment
    return environment["XCTestConfigurationFilePath"] != nil
        || environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1"
}()
