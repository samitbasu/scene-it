import AppKit
import SwiftUI
import Testing

/// Hosts `view` in an offscreen window of our own and returns the window, ordered in, once
/// `ready` holds: SwiftUI makes the view's AppKit parts on later turns, later still on a busy
/// machine, so `ready` names a part the test is about to use.
func hostOffscreen(
    _ view: some View, size: CGSize, until ready: (NSWindow) -> Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async -> NSWindow {
    let controller = NSHostingController(rootView: view)
    controller.sizingOptions = []
    let window = NSWindow(
        contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false
    )
    window.isReleasedWhenClosed = false
    window.contentViewController = controller
    window.setFrame(NSRect(origin: NSPoint(x: -30000, y: -30000), size: size), display: false)
    window.orderFront(nil)
    await eventually({ ready(window) }, sourceLocation: sourceLocation)
    return window
}
