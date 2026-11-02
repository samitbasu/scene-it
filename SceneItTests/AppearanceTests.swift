import AppKit
import Testing

@MainActor
@Test func appForcesLightAppearanceAtLaunch() {
    #expect(NSApp.appearance?.name == .aqua)
}
