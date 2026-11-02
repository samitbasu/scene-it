import Foundation

/// How the store asks the writer things. The app answers with `NSAlert`; tests answer from a script.
@MainActor
public protocol StorePrompts: AnyObject {
    func ask<Choice>(_ alert: WriterAlert<Choice>) async -> Choice
    func tell(_ notice: Notice) async
}

/// Something the writer should know, with only an OK button.
public struct Notice: Hashable, Sendable {
    public let title: String
    public let message: String

    public init(title: String, message: String) {
        self.title = title
        self.message = message
    }
}

/// The two ways out of ADR 0018's pause. Both keep both versions on disk.
public enum ExternalChangeChoice: Hashable, Sendable {
    /// Save over the other version, which becomes `bak1`.
    case keepMyVersion
    /// Save my version as a new book next to this one, then reopen this one from disk.
    case openOtherVersion
}

/// What the store remembers between launches: recent books (by path; the app isn't
/// sandboxed) and when a book was last saved, for the crash alert. Never any manuscript text.
@MainActor
public protocol BookMemory: AnyObject {
    /// Most recent first.
    var recentBookPaths: [String] { get set }
    var lastSaved: Date? { get set }
}

public final class DefaultsBookMemory: BookMemory {
    private let defaults: UserDefaults

    public init(_ defaults: UserDefaults) {
        self.defaults = defaults
    }

    public var recentBookPaths: [String] {
        get { defaults.stringArray(forKey: Key.recentBooks) ?? [] }
        set { defaults.set(newValue, forKey: Key.recentBooks) }
    }

    public var lastSaved: Date? {
        get { defaults.object(forKey: Key.lastSaved) as? Date }
        set { defaults.set(newValue, forKey: Key.lastSaved) }
    }

    private enum Key {
        static let recentBooks = "recentBooks"
        static let lastSaved = "lastSaved"
    }
}

/// For the test host and previews, which must never touch the writer's own defaults.
public final class TransientBookMemory: BookMemory {
    public var recentBookPaths: [String] = []
    public var lastSaved: Date?

    public init() {}
}
