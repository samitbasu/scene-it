import Foundation
import Observation

/// The window's layout, which is the app's, not the book's (ADR 0022): it's kept between
/// launches, and changing it never edits the open book.
@MainActor
@Observable
public final class AppPreferences {
    public private(set) var rightPanel: PanelVisibility
    public private(set) var rightPanelTab: RightPanelTab
    @ObservationIgnored public let storage: any PreferenceStorage

    /// A value missing from `storage`, or one this version doesn't know, is the default.
    public init(_ storage: any PreferenceStorage) {
        self.storage = storage
        rightPanel =
            storage.string(forKey: Key.rightPanelOpen).flatMap(PanelVisibility.init(stored:)) ?? .open
        rightPanelTab =
            storage.string(forKey: Key.rightPanelTab).flatMap(RightPanelTab.init(rawValue:)) ?? .comments
    }

    public func setRightPanel(_ visibility: PanelVisibility) {
        rightPanel = visibility
        storage.set(visibility.stored, forKey: Key.rightPanelOpen)
    }

    public func toggleRightPanel() {
        setRightPanel(rightPanel == .open ? .closed : .open)
    }

    public func showRightPanelTab(_ tab: RightPanelTab) {
        rightPanelTab = tab
        storage.set(tab.rawValue, forKey: Key.rightPanelTab)
    }

    /// Opens the panel, if it's closed, on `tab`.
    public func reveal(_ tab: RightPanelTab) {
        setRightPanel(.open)
        showRightPanelTab(tab)
    }

    enum Key {
        static let rightPanelOpen = "rightPanelOpen"
        static let rightPanelTab = "rightPanelTab"
    }
}

/// The right panel's tabs, left to right.
public enum RightPanelTab: String, CaseIterable, Hashable, Sendable {
    case comments, notes, tags, errors

    /// The tabs shown over a book with `errorCount` error entries: Errors only while it has any.
    public static func shown(errorCount: Int) -> [RightPanelTab] {
        errorCount > 0 ? allCases : allCases.filter { $0 != .errors }
    }

    /// The tab the panel shows: the one last chosen, or Comments while that one is hidden.
    public static func selected(_ preferred: RightPanelTab, among shown: [RightPanelTab]) -> RightPanelTab {
        shown.contains(preferred) ? preferred : .comments
    }
}

/// Whether the right panel is open. Format 1 also stored it, as the Boolean
/// `rightPanelOpen`, which the window no longer reads (ADR 0022).
public enum PanelVisibility: Hashable, Sendable, Codable {
    case open, closed

    public init(from decoder: any Decoder) throws {
        self = try decoder.singleValueContainer().decode(Bool.self) ? .open : .closed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(self == .open)
    }
}

extension PanelVisibility {
    fileprivate init?(stored: String) {
        switch stored {
        case "open": self = .open
        case "closed": self = .closed
        default: return nil
        }
    }

    fileprivate var stored: String {
        switch self {
        case .open: "open"
        case .closed: "closed"
        }
    }
}

/// Where `AppPreferences` keeps its values.
@MainActor
public protocol PreferenceStorage: AnyObject {
    func string(forKey key: String) -> String?
    func set(_ value: String, forKey key: String)
}

public final class DefaultsPreferenceStorage: PreferenceStorage {
    private let defaults: UserDefaults

    public init(_ defaults: UserDefaults) {
        self.defaults = defaults
    }

    public func string(forKey key: String) -> String? {
        defaults.string(forKey: key)
    }

    public func set(_ value: String, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}

/// For the test host and previews, which must never touch the writer's own defaults.
public final class TransientPreferenceStorage: PreferenceStorage {
    public private(set) var values: [String: String]

    public init(_ values: [String: String] = [:]) {
        self.values = values
    }

    public func string(forKey key: String) -> String? {
        values[key]
    }

    public func set(_ value: String, forKey key: String) {
        values[key] = value
    }
}
