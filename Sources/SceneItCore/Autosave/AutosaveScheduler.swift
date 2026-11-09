/// Something that happened which may change when the book should next be saved (PLAN §5.4).
///
/// Send `edited` in the same main-actor turn as the change to the model, so a save that starts
/// later in that turn includes it.
public enum AutosaveEvent: Hashable, Sendable {
    case edited
    case sceneSwitched
    case appDeactivated
    case quitRequested
    /// Cmd+S.
    case saveCommand
    /// The writer chose "Keep My Version" after an external change (ADR 0018). It ends a pause,
    /// and saves carry `Paused.keepingMine`, which replaces only the version the writer was
    /// told about, until one succeeds. Outside a pause it does nothing.
    case externalChangeResolved
    case saveSucceeded
    case saveFailed(SaveError)
    /// The clock reached a deadline the scheduler asked to wait for.
    case tick
}

/// A request to save right away, rather than after a delay.
public enum ImmediateTrigger: Hashable, Sendable {
    case sceneSwitched
    case appDeactivated
    case quit
    case saveCommand
    case externalChangeResolved
}

/// Why a save started.
public enum SaveTrigger: Hashable, Sendable {
    /// Typing stopped for `AutosavePolicy.idleDelay`.
    case typingPaused
    /// Typing went on for `AutosavePolicy.maximumDelay` since the first unsaved edit.
    case continuousEditing
    /// The previous save failed, and its backoff delay has passed.
    case retry
    case immediate(ImmediateTrigger)
}

/// What the scheduler asks the saver to do.
public struct SaveRequest: Hashable, Sendable {
    public let trigger: SaveTrigger
    public let onExternalChange: ExternalChangePolicy

    public init(_ trigger: SaveTrigger, onExternalChange: ExternalChangePolicy = .refuse) {
        self.trigger = trigger
        self.onExternalChange = onExternalChange
    }
}

public enum AutosavePolicy {
    public static let idleDelay = Interval.seconds(2)
    public static let maximumDelay = Interval.seconds(30)
    /// How long a quit waits for a running save before asking the writer.
    public static let quitGracePeriod = Interval.seconds(10)

    private static let retryDelays: [Interval] = [.seconds(2), .seconds(5), .seconds(15), .seconds(30)]

    /// How long to wait before retrying after `consecutiveFailures` failed saves in a row.
    /// Retries never stop while there are unsaved edits; past the table they repeat every 30 s.
    public static func retryDelay(afterFailures consecutiveFailures: Int) -> Interval {
        let index = min(max(consecutiveFailures, 1), retryDelays.count) - 1
        return retryDelays[index]
    }
}

/// When to save, as a pure state machine: every input is an event at an instant, and the
/// output says what the driver must do next. It never reads a clock and never sleeps, so tests
/// drive it with made-up instants.
public struct AutosaveScheduler<Instant: InstantProtocol<Duration>>: Hashable, Sendable {
    public enum State: Hashable, Sendable {
        case clean
        /// There are unsaved edits and no save is running.
        case unsaved(Unsaved)
        case saving(Saving)
        /// A save found that another program changed the book. Nothing is saved until the
        /// writer resolves it (ADR 0018) and `externalChangeResolved` arrives.
        case paused(Paused)
    }

    /// The first and last of a run of unsaved edits.
    public struct Edits: Hashable, Sendable {
        public let first: Instant
        public let last: Instant

        init(at instant: Instant) {
            first = instant
            last = instant
        }

        private init(first: Instant, last: Instant) {
            self.first = first
            self.last = last
        }

        func extended(to instant: Instant) -> Edits {
            Edits(first: first, last: max(last, instant))
        }

        func merged(with other: Edits?) -> Edits {
            guard let other else { return self }
            return Edits(first: min(first, other.first), last: max(last, other.last))
        }
    }

    public struct Failure: Hashable, Sendable {
        public let error: SaveError
        /// How many saves in a row have failed, counting this one.
        public let consecutive: Int
        public let at: Instant
    }

    public struct Unsaved: Hashable, Sendable {
        public fileprivate(set) var edits: Edits
        /// The last save failed; the next one is a retry on the backoff schedule.
        public let failure: Failure?
        public fileprivate(set) var requested: ImmediateTrigger?
        /// The approval from "Keep My Version" until a save succeeds; otherwise `.refuse`.
        public let onExternalChange: ExternalChangePolicy

        init(
            edits: Edits, failure: Failure? = nil, requested: ImmediateTrigger? = nil,
            onExternalChange: ExternalChangePolicy = .refuse
        ) {
            self.edits = edits
            self.failure = failure
            self.requested = requested
            self.onExternalChange = onExternalChange
        }
    }

    public struct Saving: Hashable, Sendable {
        /// The edits the running save covers.
        public let covering: Edits
        /// Edits made while the save runs. The save doesn't include them.
        public fileprivate(set) var editsSince: Edits?
        /// An immediate save requested while this one runs. It's honored only if there are
        /// `editsSince`; otherwise this save already covers everything.
        public fileprivate(set) var requestedNext: ImmediateTrigger?
        public let previousFailure: Failure?
        public let onExternalChange: ExternalChangePolicy
    }

    public struct Paused: Hashable, Sendable {
        public fileprivate(set) var edits: Edits
        public let error: SaveError
        /// What "Keep My Version" approves: replacing exactly the version found, or recreating
        /// a removed book. Nothing can approve replacing a non-file.
        public let keepingMine: ExternalChangePolicy
    }

    public enum Decision: Hashable, Sendable {
        /// Nothing to do until the next event: the book is clean, a save is running, or
        /// autosave is paused.
        case idle
        /// Send `tick` at this instant (or any later event before it).
        case waitUntil(Instant)
        /// The state is now `.saving`: run the save and report `saveSucceeded` or `saveFailed`.
        case saveNow(SaveRequest)
    }

    public private(set) var state: State

    public init() {
        state = .clean
    }

    public mutating func handle(_ event: AutosaveEvent, at now: Instant) -> Decision {
        state = Self.next(state, after: event, at: now)
        guard case .unsaved(let unsaved) = state else { return .idle }
        let trigger: SaveTrigger
        if let requested = unsaved.requested {
            trigger = .immediate(requested)
        } else {
            let (due, timed) = Self.nextTimedSave(unsaved)
            guard due <= now else { return .waitUntil(due) }
            trigger = timed
        }
        let saving = Saving(
            covering: unsaved.edits, editsSince: nil, requestedNext: nil, previousFailure: unsaved.failure,
            onExternalChange: unsaved.onExternalChange)
        state = .saving(saving)
        return .saveNow(SaveRequest(trigger, onExternalChange: unsaved.onExternalChange))
    }

    /// The most recent failed save while there are still unsaved edits.
    public var failure: Failure? {
        switch state {
        case .clean, .paused: nil
        case .unsaved(let unsaved): unsaved.failure
        case .saving(let saving): saving.previousFailure
        }
    }

    private static func next(_ state: State, after event: AutosaveEvent, at now: Instant) -> State {
        switch (state, event) {
        case (_, .tick):
            return state

        case (.clean, .edited):
            return .unsaved(Unsaved(edits: Edits(at: now)))
        case (.clean, _):
            return .clean

        case (.unsaved(var unsaved), .edited):
            unsaved.edits = unsaved.edits.extended(to: now)
            return .unsaved(unsaved)
        case (.unsaved(var unsaved), _):
            if let trigger = event.immediateTrigger {
                unsaved.requested = unsaved.requested ?? trigger
            }
            return .unsaved(unsaved)

        case (.saving(var saving), .edited):
            saving.editsSince = saving.editsSince?.extended(to: now) ?? Edits(at: now)
            return .saving(saving)
        case (.saving(let saving), .saveSucceeded):
            guard let editsSince = saving.editsSince else { return .clean }
            return .unsaved(Unsaved(edits: editsSince, requested: saving.requestedNext))
        case (.saving(let saving), .saveFailed(let error)):
            return afterFailure(error, of: saving, at: now)
        case (.saving(var saving), _):
            if let trigger = event.immediateTrigger {
                saving.requestedNext = saving.requestedNext ?? trigger
            }
            return .saving(saving)

        case (.paused(var paused), .edited):
            paused.edits = paused.edits.extended(to: now)
            return .paused(paused)
        case (.paused(let paused), .externalChangeResolved):
            return .unsaved(
                Unsaved(
                    edits: paused.edits, requested: .externalChangeResolved,
                    onExternalChange: paused.keepingMine))
        case (.paused, _):
            return state
        }
    }

    /// A request made during the failed save is dropped: the failure answers it, and the
    /// retry follows the backoff schedule. That's what lets a quit see the failure and ask.
    /// "Keep My Version" survives an ordinary failure, but a new pause needs a new choice.
    private static func afterFailure(_ error: SaveError, of saving: Saving, at now: Instant) -> State {
        let edits = saving.covering.merged(with: saving.editsSince)
        switch error {
        case .externallyModified(.changed(let theirs)), .externallyModified(.changedAndKept(let theirs, _)):
            return .paused(
                Paused(
                    edits: edits, error: error, keepingMine: .overwriteKeepingTheirsAsBackup(theirs: theirs)))
        case .externallyModified(.removed):
            return .paused(Paused(edits: edits, error: error, keepingMine: .recreate))
        case .externallyModified(.notAFile), .externallyModified(.keptAsConflict):
            return .paused(Paused(edits: edits, error: error, keepingMine: .refuse))
        case .couldNotBackUpTheirVersion:
            return .paused(Paused(edits: edits, error: error, keepingMine: saving.onExternalChange))
        case .encoding, .writeProtected, .fileSystem:
            let consecutive = (saving.previousFailure?.consecutive ?? 0) + 1
            let failure = Failure(error: error, consecutive: consecutive, at: now)
            return .unsaved(
                Unsaved(edits: edits, failure: failure, onExternalChange: saving.onExternalChange))
        }
    }

    private static func nextTimedSave(_ unsaved: Unsaved) -> (due: Instant, trigger: SaveTrigger) {
        if let failure = unsaved.failure {
            let delay = AutosavePolicy.retryDelay(afterFailures: failure.consecutive)
            return (failure.at.advanced(by: delay.duration), .retry)
        }
        let idle = unsaved.edits.last.advanced(by: AutosavePolicy.idleDelay.duration)
        let longest = unsaved.edits.first.advanced(by: AutosavePolicy.maximumDelay.duration)
        return idle <= longest ? (idle, .typingPaused) : (longest, .continuousEditing)
    }
}

extension AutosaveEvent {
    fileprivate var immediateTrigger: ImmediateTrigger? {
        switch self {
        case .sceneSwitched: .sceneSwitched
        case .appDeactivated: .appDeactivated
        case .quitRequested: .quit
        case .saveCommand: .saveCommand
        case .edited, .externalChangeResolved, .saveSucceeded, .saveFailed, .tick: nil
        }
    }
}
