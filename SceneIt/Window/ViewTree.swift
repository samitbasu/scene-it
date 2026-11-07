import AppKit

/// `view` and everything under it.
func subviewTree(of view: NSView?) -> [NSView] {
    guard let view else { return [] }
    return [view] + view.subviews.flatMap(subviewTree)
}
