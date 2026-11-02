import Foundation

/// What this process is. Only `.app` may touch the user's files or locks: the test host and
/// SwiftUI previews launch the app too, and must work while the writer has Scene It open.
public enum ProcessRole: Hashable, Sendable {
    case app
    case testHost
    case preview

    public init(environment: [String: String]) {
        if environment["XCTestConfigurationFilePath"] != nil {
            self = .testHost
        } else if environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            self = .preview
        } else {
            self = .app
        }
    }

    public static let current = ProcessRole(environment: ProcessInfo.processInfo.environment)
}

/// The app-wide lock (ADR 0020) as this process has it. Keep it alive until the process exits.
public enum InstanceLock: ~Copyable, Sendable {
    case held(ExclusiveFileLock)
    /// The test host or a preview, which never asks for the lock.
    case exempt(ProcessRole)
    /// The lock file couldn't be opened or locked. The app runs anyway: refusing to launch
    /// would be worse, and each book's own lock still keeps out a second writer.
    case unavailable(FileSystemError)

    public var summary: InstanceLockSummary {
        switch self {
        case .held: .held
        case .exempt(let role): .exempt(role)
        case .unavailable: .unavailable
        }
    }
}

public enum InstanceLockSummary: Hashable, Sendable {
    case held
    case exempt(ProcessRole)
    case unavailable
}

public enum Launch<Session>: ~Copyable {
    /// Carry on: `session` was started after the lock was settled.
    case proceed(InstanceLock, session: Session)
    /// Another instance holds the lock: pass it the books this launch was asked to open,
    /// activate it, and quit before showing anything. No session was started.
    case handOff
}

public enum LaunchGate {
    /// Decides whether this launch carries on, and only then starts its session (the crash
    /// marker of ADR 0006), so a launch that hands off never touches the marker and a
    /// marker is never written by an instance that doesn't hold the lock.
    public static func open<Session>(
        role: ProcessRole, acquire: () -> LockAttempt, startSession: () -> Session
    ) -> Launch<Session> {
        let lock: InstanceLock
        if role == .app {
            switch acquire() {
            case .acquired(let acquired): lock = .held(acquired)
            case .heldElsewhere: return .handOff
            case .failed(let error): lock = .unavailable(error)
            }
        } else {
            lock = .exempt(role)
        }
        return .proceed(lock, session: startSession())
    }

    /// Locks `file`, creating its folder first if this is the first launch, and records this
    /// process's id in it so a later launch knows which instance to hand off to.
    public static func acquire(_ file: URL, processID: Int32 = getpid()) -> LockAttempt {
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        switch ExclusiveFileLock.acquire(file) {
        case .acquired(let lock):
            do {
                try lock.replaceContents(with: Data("\(processID)\n".utf8))
            } catch {
                Log.app.error("couldn't record this instance in the app lock file", error.logMetadata)
            }
            return .acquired(lock)
        case .heldElsewhere:
            return .heldElsewhere
        case .failed(let error):
            return .failed(error)
        }
    }

    /// The process id recorded in the app lock file, if it holds one.
    public static func recordedHolder(in contents: Data) -> Int32? {
        Int32(String(decoding: contents, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Which running process to hand off to: the one recorded in the lock file if it's
    /// still Scene It, otherwise any other instance with our bundle id.
    public static func handOffTarget(
        recorded: Int32?, ours: Int32, isRunningSceneIt: (Int32) -> Bool, sameBundle: [Int32]
    ) -> Int32? {
        if let recorded, recorded != ours, isRunningSceneIt(recorded) { return recorded }
        return sameBundle.first { $0 != ours }
    }
}

/// `~/Library/Application Support/Scene It/`.
public enum SupportFolder {
    public static var root: URL {
        URL.applicationSupportDirectory.appending(path: "Scene It", directoryHint: .isDirectory)
    }

    public static var instanceLock: URL {
        root.appending(path: "instance.lock", directoryHint: .notDirectory)
    }
}
