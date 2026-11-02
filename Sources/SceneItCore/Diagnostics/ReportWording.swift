import Foundation

/// Every string a writer sees from crash detection and Report a Problem, in one place so the
/// owner can review the wording as a whole. The manifest text is shown on screen before
/// sending, so it lives here too.
public enum ReportWording {
    // MARK: Menus

    public static let reportMenuItem = "Report a Problem…"
    public static let debugMenu = "Debug"
    public static let crashNowMenuItem = "Crash Now"

    // MARK: Alert after a crash

    public static let crashAlertTitle = "Scene It quit unexpectedly the last time it was open."
    public static func crashAlertMessage(lastLaunch: Date?) -> String {
        let opened =
            lastLaunch.map {
                "That session started \($0.formatted(date: .abbreviated, time: .shortened)). "
            } ?? ""
        return opened
            + "You can send a report to help fix the problem. "
            + "You'll see what's included before anything is sent, and it contains no text from your books."
    }
    public static let crashAlertSend = "Send Report…"
    public static let crashAlertNotNow = "Not Now"

    // MARK: Report window

    public static let windowTitle = "Report a Problem"
    public static let preparing = "Preparing the report…"
    public static let intro =
        "This report helps diagnose problems with Scene It. It contains no text from your books. "
        + "Here is everything it includes:"
    public static let notIncludedHeading = "Not included"
    public static let createEmail = "Create Email"
    public static let showInFinder = "Show in Finder"
    public static let cancel = "Cancel"
    public static let close = "Close"
    public static func buildFailed(_ reason: String) -> String {
        "Scene It couldn't prepare the report. \(reason)"
    }
    public static let emailUnavailable =
        "Scene It couldn't open a new email. The report is selected in Finder so you can attach it "
        + "to an email to \(ProblemReport.destination) yourself."
    public static let emailSubject = "Scene It problem report"
    public static let emailBody =
        "Hello,\n\nThe Scene It problem report is attached.\n\n"
        + "What were you doing when the problem happened? (optional)\n\n"

    // MARK: Manifest (shown in the report window and saved as manifest.txt)

    public static func manifestHeader(created: String) -> String {
        "Scene It problem report, created \(created).\n"
            + "To be sent to \(ProblemReport.destination).\n"
            + "It contains no text from your books."
    }
    public static let manifestIncludedHeading = "Included:"
    public static let manifestNotIncludedHeading = "Not included:"
    public static let manifestReason = "This list."
    public static let systemReason =
        "The versions of Scene It and macOS, the Mac model, and a summary of Scene It's settings."
    public static let previousSessionsLogReason =
        "Scene It's activity log from recent sessions, including any that ended unexpectedly."
    public static let thisSessionLogReason = "Scene It's activity log for this session, as macOS recorded it."
    public static let metricKitReason = "A crash or hang report that macOS passed to Scene It."
    public static let crashReportReason = "A crash report macOS wrote when Scene It quit unexpectedly."
    public static let noMetricKitPayloads = "Crash and hang reports passed to Scene It: there are none."
    public static let noCrashReports = "Crash reports written by macOS: there are none for Scene It."
    public static func couldNotRead(_ item: String) -> String {
        "\(item): Scene It couldn't read it."
    }
    public static let previousSessionsLog = "Activity log from recent sessions"
    public static let thisSessionLog = "Activity log for this session"
    public static let metricKitFolder = "Crash and hang reports passed to Scene It"
    public static let crashReportsFolder = "Crash reports written by macOS"
    public static let systemSummary = "System summary"
}
