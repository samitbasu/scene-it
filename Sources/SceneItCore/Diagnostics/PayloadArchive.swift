import Foundation

/// How many saved diagnostic files to keep, and for how long.
public struct RetentionPolicy: Sendable {
    public let maxCount: Int
    public let maxAge: Interval

    public init(maxCount: Int, maxAge: Interval) {
        self.maxCount = max(maxCount, 0)
        self.maxAge = maxAge
    }

    public static let metricKit = RetentionPolicy(maxCount: 20, maxAge: .days(30))

    public struct File: Hashable, Sendable {
        public let url: URL
        public let saved: Date

        public init(url: URL, saved: Date) {
            self.url = url
            self.saved = saved
        }
    }

    /// The files to delete: everything older than `maxAge`, then the oldest of the rest
    /// beyond `maxCount`.
    public func expired(_ files: [File], now: Date) -> [File] {
        let cutoff = now - maxAge
        let newestFirst = files.sorted { $0.saved > $1.saved }
        let (fresh, stale) = (
            newestFirst.filter { $0.saved >= cutoff }, newestFirst.filter { $0.saved < cutoff }
        )
        return stale + fresh.dropFirst(maxCount)
    }
}

/// The directory where MetricKit diagnostic payloads are saved, one JSON file each.
public struct PayloadArchive: Sendable {
    public let directory: URL
    public let policy: RetentionPolicy

    public init(directory: URL, policy: RetentionPolicy = .metricKit) {
        self.directory = directory
        self.policy = policy
    }

    /// Never throws: a payload that can't be saved is logged and dropped.
    public func save(_ json: Data, now: Date = .now) {
        let stamp = now.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
            .replacingOccurrences(of: ":", with: "-")
        let file = directory.appending(path: "diagnostic-\(stamp)-\(UUID().uuidString.prefix(8)).json")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try json.write(to: file, options: .atomic)
            Log.diagnostics.info("Saved MetricKit payload", ["size": .bytes(Int64(json.count))])
        } catch {
            Log.diagnostics.error("MetricKit payload not saved", ["error": .error(LoggedError(error))])
        }
        prune(now: now)
    }

    public func prune(now: Date = .now) {
        for file in policy.expired(savedFiles(), now: now) {
            do {
                try FileManager.default.removeItem(at: file.url)
            } catch {
                Log.diagnostics.error(
                    "Old MetricKit payload not removed", ["error": .error(LoggedError(error))])
            }
        }
    }

    public func savedFiles() -> [RetentionPolicy.File] {
        let contents =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return contents.filter { $0.pathExtension == "json" }.map { url in
            let saved = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate
            return RetentionPolicy.File(url: url, saved: saved ?? .distantPast)
        }
    }
}
