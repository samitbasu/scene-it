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

    /// Locks `file`, creating its folder first if this is the first launch.
    public static func acquire(_ file: URL) -> LockAttempt {
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        return ExclusiveFileLock.acquire(file)
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
