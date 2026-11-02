import Foundation

/// App, OS and hardware versions for a problem report.
public struct SystemSummary: Sendable {
    public let appVersion: String
    public let appBuild: String
    public let osVersion: String
    public let hardwareModel: String
    public let architecture: String
    public let physicalMemoryBytes: UInt64

    public init(
        appVersion: String, appBuild: String, osVersion: String, hardwareModel: String,
        architecture: String, physicalMemoryBytes: UInt64
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.osVersion = osVersion
        self.hardwareModel = hardwareModel
        self.architecture = architecture
        self.physicalMemoryBytes = physicalMemoryBytes
    }

    public static func current(bundle: Bundle = .main) -> SystemSummary {
        let unknown = "unknown"
        return SystemSummary(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                ?? unknown,
            appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? unknown,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            hardwareModel: sysctlString("hw.model") ?? unknown,
            architecture: sysctlString("hw.machine") ?? unknown,
            physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory)
    }

    var lines: [(label: String, value: String)] {
        [
            ("Scene It version", "\(appVersion) (\(appBuild))"),
            ("macOS", osVersion),
            ("Mac model", hardwareModel),
            ("Architecture", architecture),
            (
                "Memory",
                ByteCountFormatter.string(
                    fromByteCount: Int64(clamping: physicalMemoryBytes), countStyle: .memory)
            ),
        ]
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
    }
}

/// Settings and backup state for a problem report. Values are `LogValue`s, so, like log
/// metadata, a summary can't carry text from a book.
public struct StatusSummary: Sendable {
    public let items: [(label: StaticString, value: LogValue)]

    public init(_ items: LogMetadata) {
        self.items = items.map { (label: $0.key, value: $0.value) }
    }
}
