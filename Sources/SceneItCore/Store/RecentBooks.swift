import Foundation

/// The recent-books list as a pure value: most recent first, each book once, at most `limit`.
public enum RecentBooks {
    public static let limit = 10

    public static func remembering(_ book: URL, in list: [String]) -> [String] {
        let path = book.canonicalPath
        return Array(([path] + list.filter { $0 != path }).prefix(limit))
    }

    public static func forgetting(_ book: URL, in list: [String]) -> [String] {
        let path = book.canonicalPath
        return list.filter { $0 != path }
    }
}
