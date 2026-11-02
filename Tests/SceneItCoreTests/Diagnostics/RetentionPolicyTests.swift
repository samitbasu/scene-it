import Foundation
import Testing

@testable import SceneItCore

private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func file(_ name: String, age: Interval) -> RetentionPolicy.File {
    RetentionPolicy.File(url: URL(filePath: "/tmp/\(name).json"), saved: now - age)
}

@Test func pruningRemovesFilesOlderThanTheMaximumAge() {
    let policy = RetentionPolicy(maxCount: 10, maxAge: .days(30))
    let old = file("old", age: .days(31))
    let recent = file("recent", age: .days(29))
    #expect(policy.expired([recent, old], now: now) == [old])
}

@Test func pruningKeepsOnlyTheNewestFilesBeyondTheMaximumCount() {
    let policy = RetentionPolicy(maxCount: 2, maxAge: .days(30))
    let files = (1...4).map { file("f\($0)", age: .hours($0)) }
    #expect(Set(policy.expired(files.shuffled(), now: now).map(\.url)) == Set(files[2...].map(\.url)))
}

@Test func pruningAppliesAgeBeforeCount() {
    let policy = RetentionPolicy(maxCount: 1, maxAge: .days(1))
    let fresh = file("fresh", age: .hours(1))
    let fresher = file("fresher", age: .minutes(1))
    let stale = file("stale", age: .days(2))
    #expect(Set(policy.expired([fresh, stale, fresher], now: now)) == Set([stale, fresh]))
}

@Test func pruningTreatsFutureDatedFilesAsNewest() {
    let policy = RetentionPolicy(maxCount: 1, maxAge: .days(1))
    let future = RetentionPolicy.File(url: URL(filePath: "/tmp/future.json"), saved: now + .hours(3))
    let present = file("present", age: .zero)
    #expect(policy.expired([present, future], now: now) == [present])
}

@Test func pruningKeepsEverythingWithinLimits() {
    let policy = RetentionPolicy(maxCount: 5, maxAge: .days(30))
    #expect(policy.expired([file("a", age: .days(1)), file("b", age: .days(2))], now: now).isEmpty)
}

@Test func negativeMaximumCountClampsToZero() {
    let policy = RetentionPolicy(maxCount: -3, maxAge: .days(30))
    #expect(policy.maxCount == 0)
    #expect(policy.expired([file("a", age: .zero)], now: now).count == 1)
}

@Test func payloadArchiveSavesAndPrunesToTheCount() throws {
    let directory = try TemporaryDirectory()
    let archive = PayloadArchive(
        directory: directory.url, policy: RetentionPolicy(maxCount: 2, maxAge: .days(30)))
    for index in 0..<4 {
        archive.save(Data("{\"n\":\(index)}".utf8))
    }
    #expect(archive.savedFiles().count == 2)
}
