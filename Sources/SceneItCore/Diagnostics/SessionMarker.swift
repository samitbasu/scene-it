import Foundation

/// How the previous run of the app ended.
public enum LastSession: Equatable, Sendable {
    case cleanLastTime
    /// `lastLaunch` is `nil` when the marker was found but its launch time couldn't be read.
    case crashedLastTime(lastLaunch: Date?)
    /// The marker belongs to another copy of Scene It that is still running, such as a Debug
    /// build next to the installed app. Nothing can be said about earlier runs.
    case anotherInstanceRunning
}

/// What was on disk at launch, before this run writes its own marker.
public enum MarkerObservation: Equatable, Sendable {
    case absent
    case present(launchedAt: Date, processID: Int32)
    case unreadable(modifiedAt: Date?)

    public func lastSession(currentProcess: Int32, isLiveInstance: (Int32) -> Bool) -> LastSession {
        switch self {
        case .absent:
            .cleanLastTime
        case .present(_, let processID) where processID != currentProcess && isLiveInstance(processID):
            .anotherInstanceRunning
        case .present(let launchedAt, _):
            .crashedLastTime(lastLaunch: launchedAt)
        case .unreadable(let modifiedAt):
            .crashedLastTime(lastLaunch: modifiedAt)
        }
    }
}

/// Crash detection (ADR 0006): a marker file is written at launch and removed on clean
/// termination. A marker still present at the next launch means that run didn't terminate
/// cleanly: it crashed, was force-quit, or was stopped in the debugger.
public struct SessionMarker: Sendable {
    public let file: URL
    private let processID: Int32

    public init(directory: URL, processID: Int32 = ProcessInfo.processInfo.processIdentifier) {
        file = directory.appending(path: "session.marker")
        self.processID = processID
    }

    /// Reads the previous run's marker, then writes this run's, unless the marker belongs to
    /// another running instance. Never throws: a marker that can't be written only means the
    /// next launch can't detect a crash of this one.
    public func begin(now: Date = .now, isLiveInstance: (Int32) -> Bool) -> LastSession {
        let lastSession = observe().lastSession(currentProcess: processID, isLiveInstance: isLiveInstance)
        guard lastSession != .anotherInstanceRunning else { return lastSession }
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Contents(launchedAt: now, processID: processID))
                .write(to: file, options: .atomic)
        } catch {
            Log.diagnostics.error("Session marker not written", ["error": .error(LoggedError(error))])
        }
        return lastSession
    }

    /// Removes the marker only if this process wrote it.
    public func end() {
        guard case .present(_, let owner) = observe(), owner == processID else { return }
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            Log.diagnostics.error("Session marker not removed", ["error": .error(LoggedError(error))])
        }
    }

    func observe() -> MarkerObservation {
        let path = file.path(percentEncoded: false)
        guard FileManager.default.fileExists(atPath: path) else { return .absent }
        if let data = try? Data(contentsOf: file),
            let contents = try? JSONDecoder().decode(Contents.self, from: data)
        {
            return .present(launchedAt: contents.launchedAt, processID: contents.processID)
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return .unreadable(modifiedAt: attributes?[.modificationDate] as? Date)
    }

    private struct Contents: Codable {
        let launchedAt: Date
        let processID: Int32
    }
}
