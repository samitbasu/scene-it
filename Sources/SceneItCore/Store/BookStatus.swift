/// What the status bar says about the open book (PLAN §4.5). One value at a time; where
/// several hold, the one the writer must act on soonest wins.
public enum BookStatus: Hashable, Sendable {
    case saved
    case unsaved
    case saving
    /// The last save failed; autosave retries on its backoff schedule.
    case failed(SaveError)
    /// Autosave is paused until the writer decides which version to keep (ADR 0018).
    case changedOnDisk(SaveError)
    /// Everything is saved, but the last save couldn't keep all its backups (ADR 0019).
    case backupsNotWorking(SavedBackups)
    case readOnly(ReadOnlyReason)
    /// The book was closed; nothing shows it any more.
    case closed

    public init<Instant>(autosave state: AutosaveScheduler<Instant>.State, lastBackups: SavedBackups?) {
        switch state {
        case .saving:
            self = .saving
        case .paused(let paused):
            self = .changedOnDisk(paused.error)
        case .unsaved(let unsaved):
            self = unsaved.failure.map { .failed($0.error) } ?? .unsaved
        case .clean:
            if let lastBackups, !lastBackups.areWorking {
                self = .backupsNotWorking(lastBackups)
            } else {
                self = .saved
            }
        }
    }
}
