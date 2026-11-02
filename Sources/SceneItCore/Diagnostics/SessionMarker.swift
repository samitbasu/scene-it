import Foundation

/// How the previous run of the app ended.
public enum LastSession: Equatable, Sendable {
    case cleanLastTime
    /// `lastLaunch` is `nil` when the marker was found but its launch time couldn't be read.
    case crashedLastTime(lastLaunch: Date?)
}

/// What was on disk at launch, before this run writes its own marker.
public enum MarkerObservation: Equatable, Sendable {
    case absent
    case present(launchedAt: Date)
    case unreadable(modifiedAt: Date?)

    public var lastSession: LastSession {
        switch self {
        case .absent: .cleanLastTime
        case .present(let launchedAt): .crashedLastTime(lastLaunch: launchedAt)
        case .unreadable(let modifiedAt): .crashedLastTime(lastLaunch: modifiedAt)
        }
    }
}

/// Crash detection (ADR 0006): a marker file is written at launch and removed on clean
/// termination. A marker still present at the next launch means that run didn't terminate
/// cleanly: it crashed, was force-quit, or was stopped in the debugger.
public struct SessionMarker: Sendable {
    public let file: URL

    public init(directory: URL) {
        file = directory.appending(path: "session.marker")
    }

    /// Reads the previous run's marker, then writes this run's. Never throws: a marker that
    /// can't be written only means the next launch can't detect a crash of this one.
    public func begin(now: Date = .now) -> LastSession {
        let previous = observe()
        do {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Contents(launchedAt: now)).write(to: file, options: .atomic)
        } catch {
            Log.diagnostics.error("Session marker not written", ["error": .error(LoggedError(error))])
        }
        return previous.lastSession
    }

    public func end() {
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
            return .present(launchedAt: contents.launchedAt)
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return .unreadable(modifiedAt: attributes?[.modificationDate] as? Date)
    }

    private struct Contents: Codable {
        let launchedAt: Date
    }
}
