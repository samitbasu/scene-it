import Foundation

/// macOS's own `unzip`, to check our archives with a reader that isn't ours.
public enum Unzip {
    public static func part(_ name: String, of zip: Data) throws -> Data {
        // unzip reads a name as a pattern, where `[` opens a set of characters.
        let pattern = name.replacingOccurrences(of: "[", with: "[[]")
        return try withFile(zip) { try run("/usr/bin/unzip", ["-p", $0, pattern]) }
    }

    /// `unzip -t`: whether every entry decompresses and matches its checksum.
    public static func test(_ zip: Data) throws -> Bool {
        try withFile(zip) { (try? run("/usr/bin/unzip", ["-tq", $0])) != nil }
    }

    /// The entries' names, in the archive's order.
    public static func names(_ zip: Data) throws -> [String] {
        let listing = try withFile(zip) { try run("/usr/bin/zipinfo", ["-1", $0]) }
        return String(decoding: listing, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// The tool's output; throws if it fails.
    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failed(status: process.terminationStatus) }
        return data
    }

    public struct Failed: Error {
        public let status: Int32
    }

    /// `zip` in a file of its own, removed when `body` returns; `body` gets its path.
    private static func withFile<T>(_ zip: Data, _ body: (String) throws -> T) throws -> T {
        let file = FileManager.default.temporaryDirectory.appending(
            path: "SceneItZip-\(UUID().uuidString).zip")
        try zip.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        return try body(file.path(percentEncoded: false))
    }
}
