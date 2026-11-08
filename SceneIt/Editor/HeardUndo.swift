import Foundation

/// The one undo manager whose undo and redo an observer hears of. Hearing every undo in the app
/// (`object: nil`) would run the observer inside other code's undo, where asking a view for
/// anything that goes through its delegate autoreleases the observer into that code's pool
/// (#135).
struct HeardUndo {
    private(set) var manager: UndoManager?

    /// From now on `observer` hears, through `selector`, of `undo`'s undo and redo, and of no
    /// other manager's.
    mutating func hear(_ undo: UndoManager, by observer: NSObject, calling selector: Selector) {
        guard undo !== manager else { return }
        let center = NotificationCenter.default
        for name in [NSNotification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            if let manager { center.removeObserver(observer, name: name, object: manager) }
            center.addObserver(observer, selector: selector, name: name, object: undo)
        }
        manager = undo
    }
}
