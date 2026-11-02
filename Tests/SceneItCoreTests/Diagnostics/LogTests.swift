import Foundation
import Testing

@testable import SceneItCore

private struct DescribedError: LocalizedError {
    let errorDescription: String?
}

@Test func composedMessageListsMetadataInOrder() {
    let id = UUID()
    let text = Log.compose(
        "Saved book",
        ["scenes": .count(12), "size": .bytes(2048), "mode": .symbol("autosave"), "book": .id(id)])
    #expect(text == "Saved book scenes=12 size=2048B mode=autosave book=\(id.uuidString)")
}

@Test func loggedErrorsCarryTheirIdentityButNotTheirDescription() {
    let sentence = "The lighthouse keeper burned every letter."
    let error = DescribedError(errorDescription: sentence)
    #expect(error.localizedDescription.contains(sentence))
    let text = Log.compose("Failed", ["error": .error(LoggedError(error))])
    #expect(!text.contains(sentence))
    #expect(text.contains("DescribedError"))
}

@Test func logRingReturnsEntriesOldestFirst() throws {
    let directory = try TemporaryDirectory()
    let ring = LogRing(directory: directory.url)
    let entries = (0..<3).map {
        LogEntry(
            date: Date(timeIntervalSinceReferenceDate: Double($0)), level: .info, category: .store,
            message: "entry \($0)")
    }
    entries.forEach(ring.append)
    #expect(try ring.entries() == entries)
}

@Test func logRingStaysWithinItsCapacityAndKeepsTheNewestEntries() throws {
    let directory = try TemporaryDirectory()
    let capacity = 4096
    let ring = LogRing(directory: directory.url, capacityBytes: capacity)
    for index in 0..<500 {
        ring.append(LogEntry(date: .now, level: .info, category: .store, message: "entry \(index)"))
    }
    let sizes = try [ring.currentFile, ring.previousFile].map {
        try FileManager.default.attributesOfItem(atPath: $0.path(percentEncoded: false))[.size] as? Int ?? 0
    }
    #expect(sizes.reduce(0, +) <= capacity)
    let kept = try ring.entries()
    #expect(kept.last?.message == "entry 499")
    #expect(kept.count < 500)
}

@Test func logRingSkipsALineTornByACrash() throws {
    let directory = try TemporaryDirectory()
    let ring = LogRing(directory: directory.url)
    let entry = LogEntry(date: .now, level: .error, category: .app, message: "before the crash")
    ring.append(entry)
    let torn = try FileHandle(forWritingTo: ring.currentFile)
    try torn.seekToEnd()
    try torn.write(contentsOf: Data("{\"date\":12,\"lev".utf8))
    try torn.close()
    #expect(try ring.entries() == [entry])
}

@Test func persistedLogMessagesReachTheRing() throws {
    let directory = try TemporaryDirectory()
    let ring = LogRing(directory: directory.url)
    Log.persist(to: ring)
    defer { Log.persist(to: nil) }
    let marker = UUID()
    Log.diagnostics.info("Ring test", ["marker": .id(marker)])
    Log.diagnostics.debug("Debug entries stay out of the ring", ["marker": .id(marker)])
    let matching = try ring.entries().filter { $0.message.contains(marker.uuidString) }
    #expect(matching.map(\.message) == ["Ring test marker=\(marker.uuidString)"])
    #expect(matching.first?.category == .diagnostics)
}

@Test func infoEntriesCanBeReadBackFromTheUnifiedLog() throws {
    let marker = UUID()
    Log.store.info("Unified log info test", ["marker": .id(marker)])
    let entries = try CurrentProcessLog.entries(since: .now - .minutes(1))
    let match = try #require(entries.first { $0.message.contains(marker.uuidString) })
    #expect(match.level == .info)
    #expect(match.category == .store)
}
