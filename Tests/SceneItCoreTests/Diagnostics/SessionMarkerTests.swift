import Foundation
import Testing

@testable import SceneItCore

private let us: Int32 = 500
private let other: Int32 = 700
private let nobodyIsRunning: @Sendable (Int32) -> Bool = { _ in false }
private let everyoneIsRunning: @Sendable (Int32) -> Bool = { _ in true }

@Test func markerObservationDecidesHowTheLastSessionEnded() {
    let launch = Date(timeIntervalSinceReferenceDate: 5000)
    func decide(_ observation: MarkerObservation, _ isLive: (Int32) -> Bool = nobodyIsRunning) -> LastSession
    {
        observation.lastSession(currentProcess: us, isLiveInstance: isLive)
    }
    #expect(decide(.absent) == .cleanLastTime)
    #expect(decide(.absent, everyoneIsRunning) == .cleanLastTime)
    #expect(decide(.present(launchedAt: launch, processID: other)) == .crashedLastTime(lastLaunch: launch))
    #expect(
        decide(.present(launchedAt: launch, processID: other), everyoneIsRunning) == .anotherInstanceRunning)
    #expect(
        decide(.present(launchedAt: launch, processID: us), everyoneIsRunning)
            == .crashedLastTime(lastLaunch: launch))
    #expect(
        decide(.unreadable(modifiedAt: launch), everyoneIsRunning) == .crashedLastTime(lastLaunch: launch))
    #expect(decide(.unreadable(modifiedAt: nil)) == .crashedLastTime(lastLaunch: nil))
}

@Test func firstLaunchIsClean() throws {
    let directory = try TemporaryDirectory()
    let marker = SessionMarker(directory: directory.url.appending(path: "Diagnostics"), processID: us)
    #expect(marker.begin(isLiveInstance: nobodyIsRunning) == .cleanLastTime)
}

@Test func launchAfterCleanTerminationIsClean() throws {
    let directory = try TemporaryDirectory()
    let marker = SessionMarker(directory: directory.url, processID: us)
    _ = marker.begin(isLiveInstance: nobodyIsRunning)
    marker.end()
    #expect(
        SessionMarker(directory: directory.url, processID: other).begin(isLiveInstance: nobodyIsRunning)
            == .cleanLastTime)
}

@Test func launchWithoutTerminationIsACrashAtThePreviousLaunchTime() throws {
    let directory = try TemporaryDirectory()
    let firstLaunch = Date(timeIntervalSinceReferenceDate: 800_000_000)
    _ = SessionMarker(directory: directory.url, processID: other).begin(
        now: firstLaunch, isLiveInstance: nobodyIsRunning)
    let next = SessionMarker(directory: directory.url, processID: us)
    #expect(
        next.begin(now: firstLaunch + .hours(1), isLiveInstance: nobodyIsRunning)
            == .crashedLastTime(lastLaunch: firstLaunch))
}

@Test func beginWritesThisSessionsMarkerAndEndRemovesIt() throws {
    let directory = try TemporaryDirectory()
    let marker = SessionMarker(directory: directory.url, processID: us)
    let launch = Date(timeIntervalSinceReferenceDate: 800_000_000)
    _ = marker.begin(now: launch, isLiveInstance: nobodyIsRunning)
    #expect(marker.observe() == .present(launchedAt: launch, processID: us))
    marker.end()
    #expect(marker.observe() == .absent)
}

@Test func aSecondInstanceLeavesTheRunningInstancesMarkerAlone() throws {
    let directory = try TemporaryDirectory()
    let launch = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let running = SessionMarker(directory: directory.url, processID: other)
    _ = running.begin(now: launch, isLiveInstance: nobodyIsRunning)

    let second = SessionMarker(directory: directory.url, processID: us)
    #expect(
        second.begin(now: launch + .minutes(5), isLiveInstance: { $0 == other }) == .anotherInstanceRunning)
    second.end()
    #expect(running.observe() == .present(launchedAt: launch, processID: other))

    running.end()
    #expect(running.observe() == .absent)
}

@Test func corruptMarkerCountsAsACrash() throws {
    let directory = try TemporaryDirectory()
    let marker = SessionMarker(directory: directory.url, processID: us)
    try Data("not json".utf8).write(to: marker.file)
    guard case .crashedLastTime(let lastLaunch) = marker.begin(isLiveInstance: everyoneIsRunning) else {
        Issue.record("a corrupt marker should be read as a crash")
        return
    }
    #expect(lastLaunch != nil)
}
