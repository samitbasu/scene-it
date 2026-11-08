import Foundation

/// The one undo manager whose undo and redo an observer hears of. Hearing every undo in the app
/// (`object: nil`) would run the observer inside other code's undo, where asking a view for
/// anything that goes through its delegate autoreleases the observer into that code's pool
/// (#135). The observer's earlier observations of these names are removed by name alone, so
/// none can outlive its manager and match a new one at the same address.
final class HeardUndo {
    private weak var manager: UndoManager?

    /// From now on `observer` hears, through `selector`, of `undo`'s undo and redo, and of no
    /// other manager's.
    func hear(_ undo: UndoManager, by observer: NSObject, calling selector: Selector) {
        guard undo !== manager else { return }
        let center = NotificationCenter.default
        for name in [NSNotification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            center.removeObserver(observer, name: name, object: nil)
            center.addObserver(observer, selector: selector, name: name, object: undo)
        }
        manager = undo
    }
}
