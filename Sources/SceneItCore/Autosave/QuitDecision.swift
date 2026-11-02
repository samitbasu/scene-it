/// Why quitting now would lose edits, so the writer must choose.
public enum QuitProblem: Hashable, Sendable {
    case saveFailed(SaveError)
    /// Autosave is paused on an external change (ADR 0018).
    case changedOnDisk(SaveError)
    /// A save has run for `AutosavePolicy.quitGracePeriod` without finishing. It keeps running.
    case stillSaving
}

public enum QuitVerdict: Hashable, Sendable {
    case terminate
    case askWriter(QuitProblem)
}

/// What `applicationShouldTerminate` does, given the autosave state after `quitRequested`.
public enum QuitDecision: Hashable, Sendable {
    /// A save is running or about to start: reply `.terminateLater` and decide again when it ends.
    case waitForSave
    case settled(QuitVerdict)
}

/// What the writer picked in the quit alert (`QuitWording`).
public enum QuitAlertChoice: Hashable, Sendable {
    /// Send `quitRequested` again and decide again.
    case retry
    /// Keep waiting for the running save, then decide again.
    case wait
    /// Terminate, losing the unsaved edits. Only ever the writer's explicit choice.
    case quitAnyway
    /// Don't quit.
    case cancel
}

extension AutosaveScheduler.State {
    public var quitDecision: QuitDecision {
        switch self {
        case .clean:
            .settled(.terminate)
        case .saving:
            .waitForSave
        case .unsaved(let unsaved):
            if unsaved.requested == nil, let failure = unsaved.failure {
                .settled(.askWriter(.saveFailed(failure.error)))
            } else {
                .waitForSave
            }
        case .paused(let paused):
            .settled(.askWriter(.changedOnDisk(paused.error)))
        }
    }
}
