import Foundation
import Testing

@testable import SceneItCore

@Test func markerObservationDecidesHowTheLastSessionEnded() {
    let launch = Date(timeIntervalSinceReferenceDate: 5000)
    #expect(MarkerObservation.absent.lastSession == .cleanLastTime)
    #expect(MarkerObservation.present(launchedAt: launch).lastSession == .crashedLastTime(lastLaunch: launch))
    #expect(
        MarkerObservation.unreadable(modifiedAt: launch).lastSession == .crashedLastTime(lastLaunch: launch))
    #expect(MarkerObservation.unreadable(modifiedAt: nil).lastSession == .crashedLastTime(lastLaunch: nil))
}

@Test func firstLaunchIsClean() throws {
    let directory = try TemporaryDirectory()
    let marker = SessionMarker(directory: directory.url.appending(path: "Diagnostics"))
    #expect(marker.begin() == .cleanLastTime)
}

@Test func launchAfterCleanTerminationIsClean() throws {
    let directory = try TemporaryDirectory()
    let marker = SessionMarker(directory: directory.url)
    _ = marker.begin()
    marker.end()
    #expect(marker.begin() == .cleanLastTime)
}

@Test func launchWithoutTerminationIsACrashAtThePreviousLaunchTime() throws {
    let directory = try TemporaryDirectory()
    let marker = SessionMarker(directory: directory.url)
    let firstLaunch = Date(timeIntervalSinceReferenceDate: 800_000_000)
    _ = marker.begin(now: firstLaunch)
    #expect(marker.begin(now: firstLaunch + .hours(1)) == .crashedLastTime(lastLaunch: firstLaunch))
}

@Test func beginWritesThisSessionsMarker() throws {
    let directory = try TemporaryDirectory()
    let marker = SessionMarker(directory: directory.url)
    let launch = Date(timeIntervalSinceReferenceDate: 800_000_000)
    _ = marker.begin(now: launch)
    #expect(marker.observe() == .present(launchedAt: launch))
    marker.end()
    #expect(marker.observe() == .absent)
}

@Test func corruptMarkerCountsAsACrash() throws {
    let directory = try TemporaryDirectory()
    let marker = SessionMarker(directory: directory.url)
    try Data("not json".utf8).write(to: marker.file)
    guard case .crashedLastTime(let lastLaunch) = marker.begin() else {
        Issue.record("a corrupt marker should be read as a crash")
        return
    }
    #expect(lastLaunch != nil)
}
