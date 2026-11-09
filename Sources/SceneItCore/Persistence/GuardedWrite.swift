import Foundation

/// A file Scene It saves with its safe-save rules, and where that file's side files go: the
/// rotated backups (ADR 0005), another program's version kept during a save (ADR 0018) and Make
/// Editable's kept originals (ADR 0024). A book's are beside `book.md` in its package; a review's
/// are in its own folder in Application Support (review format §9 Q9, ADR 0042).
public struct SavedFileLayout: Hashable, Sendable {
    public let file: URL
    public let sideFolder: URL
    /// What the side files are named after: `<sideName>.bak1`, `<sideName>.conflict-<time>`, …
    let sideName: String

    public func backup(_ slot: BackupSlot) -> URL {
        side("\(sideName).bak\(slot.rawValue)")
    }

    /// `<sideName>.conflict-<UTC time>`, then `-2`, `-3`, … for later attempts in the same second.
    public func conflict(at date: Date, attempt: Int) -> URL {
        side("\(sideName).conflict-\(Self.stamp(date, attempt))")
    }

    /// `<sideName>.original-<UTC time>.md`, then `-2`, `-3`, … before `.md`. Nothing rotates,
    /// prunes or sweeps it: it's not a backup slot, a snapshot or a temporary file's name.
    public func original(at date: Date, attempt: Int) -> URL {
        side("\(sideName).original-\(Self.stamp(date, attempt)).md")
    }

    static func stamp(_ date: Date, _ attempt: Int) -> String {
        UTCStamp.string(for: date) + (attempt > 1 ? "-\(attempt)" : "")
    }

    private func side(_ name: String) -> URL {
        sideFolder.appending(path: name, directoryHint: .notDirectory)
    }
}

/// What a guarded write did.
enum GuardedWriteOutcome {
    /// The file already held exactly these bytes, so nothing was written or rotated.
    case unchanged
    case written(BackupStatus)
}

/// Replaces a file the safe way: never over another program's version unless that version is
/// safely in `bak1` (ADR 0019), with the backups rotated, the new bytes written to a temporary
/// file first and swapped into place, and a version another program wrote during the swap
/// kept rather than lost (ADR 0018). `lastSeen` is the digest of what the caller last read or
/// wrote; the caller serializes calls for one file.
struct GuardedWrite {
    let layout: SavedFileLayout
    let fileSystem: any FileSystem

    /// When this throws, the file is unchanged.
    func save(_ data: Data, _ policy: ExternalChangePolicy, _ lastSeen: inout ContentDigest)
        throws(SaveError) -> GuardedWriteOutcome
    {
        let current = try readCurrent(lastSeen, policy)
        if current?.data == data { return .unchanged }
        let backups = try replaceFile(with: data, current: current, &lastSeen)
        lastSeen = ContentDigest(data)
        return .written(backups)
    }

    /// What the file holds now, and whose it is.
    private struct Current {
        let data: Data
        let owner: Owner
    }

    private enum Owner {
        /// The bytes are the caller's own last read or write.
        case ours
        case theirs
    }

    /// `nil` if the file was removed and `policy` allows recreating it.
    private func readCurrent(_ lastSeen: ContentDigest, _ policy: ExternalChangePolicy) throws(SaveError)
        -> Current?
    {
        let item = try wrapping(SaveError.fileSystem) { () throws(FileSystemError) in
            try fileSystem.item(at: layout.file)
        }
        switch item {
        case nil:
            guard policy == .recreate else { throw refusal(.removed) }
            return nil
        case .directory, .symbolicLink, .other:
            throw refusal(.notAFile)
        case .file(_, let protection):
            if let protection { throw .writeProtected(protection) }
            let data = try wrapping(SaveError.fileSystem) { () throws(FileSystemError) in
                try fileSystem.read(layout.file)
            }
            let digest = ContentDigest(data)
            if digest == lastSeen { return Current(data: data, owner: .ours) }
            guard policy == .overwriteKeepingTheirsAsBackup(theirs: digest) else {
                throw refusal(.changed(theirs: digest))
            }
            return Current(data: data, owner: .theirs)
        }
    }

    private func refusal(_ change: ExternalChange) -> SaveError {
        Log.store.error("refused to save over a file changed by another program")
        return .externallyModified(change)
    }

    /// The refusal for a file that changed during the save, naming what's there now.
    private func changedDuringSave() -> SaveError {
        let item: FileItem?
        do {
            item = try fileSystem.item(at: layout.file)
        } catch {
            return .fileSystem(error)
        }
        switch item {
        case nil:
            return refusal(.removed)
        case .directory, .symbolicLink, .other:
            return refusal(.notAFile)
        case .file:
            do {
                return refusal(.changed(theirs: ContentDigest(try fileSystem.read(layout.file))))
            } catch {
                return .fileSystem(error)
            }
        }
    }

    /// Writes both temporary files first, so every failure that leaves the disk unchanged
    /// happens before any rename. Then the renames: the backup rotation, then the file.
    private func replaceFile(
        with data: Data, current: Current?, _ lastSeen: inout ContentDigest
    ) throws(SaveError) -> BackupStatus {
        var unpublished: [URL] = []
        do throws(SaveError) {
            var backup: (file: TemporaryFile, bak1: Bak1)?
            if let current {
                let bak1 = bak1Holding(current.data)
                if bak1 != .holdsCurrent {
                    let file = try wrapping(SaveError.fileSystem) { () throws(FileSystemError) in
                        try fileSystem.writeTemporary(
                            current.data, for: layout.backup(.bak1), permissionsFrom: layout.file)
                    }
                    unpublished.append(file.url)
                    backup = (file, bak1)
                }
            }
            let replacement = try wrapping(SaveError.fileSystem) { () throws(FileSystemError) in
                try fileSystem.writeTemporary(data, for: layout.file, permissionsFrom: layout.file)
            }
            unpublished.append(replacement.url)
            var status = BackupStatus.intact
            if let backup, let current {
                do {
                    try rotateBackups(publishing: backup.file, over: backup.bak1)
                } catch {
                    guard current.owner == .ours else { throw .couldNotBackUpTheirVersion(error.cause) }
                    Log.store.error(
                        "couldn't back up the previous version; saving anyway", error.cause.logMetadata)
                    fileSystem.discard(backup.file.url)
                    status = .previousVersionNotBackedUp(error.cause, olderBackups: error.olderBackups)
                }
            }
            unpublished = []
            try replace(with: replacement, holding: data, expecting: current?.data, &lastSeen)
            return status
        } catch {
            unpublished.forEach(fileSystem.discard)
            Log.store.error("couldn't save a file")
            throw error
        }
    }

    private enum Bak1 {
        case holdsCurrent, absent, holdsOther
    }

    /// Anything that can't be read counts as different, so a damaged slot never stops a save.
    private func bak1Holding(_ current: Data) -> Bak1 {
        let url = layout.backup(.bak1)
        let item: FileItem?
        do {
            item = try fileSystem.item(at: url)
        } catch {
            return .holdsOther
        }
        guard let item else { return .absent }
        guard case .file(let metadata, _) = item, metadata.size == current.count,
            let contents = try? fileSystem.read(url), contents == current
        else { return .holdsOther }
        return .holdsCurrent
    }

    /// Shifts `bak2`→`bak3` and `bak1`→`bak2` (unless `bak1` is empty, which absorbs the shift),
    /// then publishes `backup` into the empty `bak1`. Stops at the first failure, so it never
    /// destroys a version other than the one in `bak3`.
    private func rotateBackups(publishing backup: TemporaryFile, over bak1: Bak1) throws(RotationFailure) {
        var olderBackups = OlderBackups.untouched
        let shifts: [(BackupSlot, BackupSlot)] = bak1 == .absent ? [] : [(.bak2, .bak3), (.bak1, .bak2)]
        for (source, destination) in shifts {
            do {
                try fileSystem.move(layout.backup(source), over: layout.backup(destination))
            } catch  where error.cause == .notFound {
                continue
            } catch {
                throw RotationFailure(cause: error, olderBackups: olderBackups)
            }
            if destination == .bak3 { olderBackups = .oldestRetired }
        }
        do {
            try fileSystem.publish(backup, as: layout.backup(.bak1))
        } catch {
            throw RotationFailure(cause: error, olderBackups: olderBackups)
        }
    }

    private struct RotationFailure: Error {
        let cause: FileSystemError
        let olderBackups: OlderBackups
    }

    /// Replaces the file with `replacement` (which holds `data`) only if it still holds
    /// `expected` (or, for `nil`, nothing), and disposes of `replacement`.
    ///
    /// With `exchange`, the check happens after the swap: if the displaced file isn't
    /// `expected`, another program renamed a new version into place after `readCurrent`, and
    /// it's swapped back. That closes the window for writers that rename into place, as sync
    /// services and most editors do. A writer that already had the file open and edits it
    /// in place can still write to the displaced file after the comparison, and that write is
    /// lost when the file is discarded. Volumes that can't swap get a re-check just before a
    /// plain rename.
    private func replace(
        with replacement: TemporaryFile, holding data: Data, expecting expected: Data?,
        _ lastSeen: inout ContentDigest
    ) throws(SaveError) {
        guard let expected else {
            do {
                return try fileSystem.publish(replacement, as: layout.file)
            } catch {
                fileSystem.discard(replacement.url)
                throw error.cause == .alreadyExists ? changedDuringSave() : .fileSystem(error)
            }
        }
        do {
            try fileSystem.exchange(replacement, with: layout.file)
        } catch  where error.cause == .unsupported {
            return try replaceWithoutExchange(replacement, expecting: expected)
        } catch {
            fileSystem.discard(replacement.url)
            throw .fileSystem(error)
        }
        if (try? fileSystem.read(replacement.url)) == expected {
            fileSystem.discard(replacement.url)
            return
        }
        do {
            try fileSystem.exchange(replacement, with: layout.file)
        } catch {
            throw keepAsConflict(replacement, published: data, &lastSeen)
        }
        fileSystem.discard(replacement.url)
        throw changedDuringSave()
    }

    /// For volumes that can't swap (FAT, exFAT, HFS+). A change landing between this re-read
    /// and the rename is lost; the window is a few microseconds.
    private func replaceWithoutExchange(_ replacement: TemporaryFile, expecting expected: Data)
        throws(SaveError)
    {
        guard (try? fileSystem.read(layout.file)) == expected else {
            fileSystem.discard(replacement.url)
            throw changedDuringSave()
        }
        do {
            try fileSystem.move(replacement.url, over: layout.file)
        } catch {
            fileSystem.discard(replacement.url)
            throw .fileSystem(error)
        }
    }

    /// The file now holds `published` and the other program's version sits at the temporary
    /// name, which nothing reads; give it a visible name so it isn't lost.
    ///
    /// `lastSeen` becomes the digest of what this save wrote, not of a fresh read: a third
    /// write landing now must not be mistaken for ours.
    private func keepAsConflict(
        _ displaced: TemporaryFile, published: Data, _ lastSeen: inout ContentDigest
    ) -> SaveError {
        lastSeen = ContentDigest(published)
        let now = Date.now
        do {
            if let conflict = try fileSystem.publishUnderFreeName(
                displaced, { layout.conflict(at: now, attempt: $0) })
            {
                Log.store.fault("another program changed a file during a save; kept its version separately")
                return .externallyModified(.keptAsConflict(fileName: conflict.lastPathComponent))
            }
        } catch {
            Log.store.fault("couldn't rename another program's version of a file", error.logMetadata)
        }
        guard case .file? = try? fileSystem.item(at: displaced.url) else { return changedDuringSave() }
        return .externallyModified(.keptAsConflict(fileName: displaced.url.lastPathComponent))
    }

    /// Make Editable's first step (ADR 0024): writes `original` to a new
    /// `<sideName>.original-<UTC time>.md`, flushed to the drive. It never replaces a file, and
    /// nothing ever removes the one it writes.
    static func keepOriginal(
        _ original: Data, of layout: SavedFileLayout, now: Date, fileSystem: any FileSystem
    ) throws(FileSystemError) -> URL {
        let temporary = try fileSystem.writeTemporary(
            original, for: layout.original(at: now, attempt: 1), permissionsFrom: layout.file)
        let kept: URL?
        do {
            kept = try fileSystem.publishUnderFreeName(temporary) { layout.original(at: now, attempt: $0) }
        } catch {
            fileSystem.discard(temporary.url)
            throw error
        }
        guard let kept else {
            fileSystem.discard(temporary.url)
            throw FileSystemError(
                .publish, layout.original(at: now, attempt: freeNameAttempts), .alreadyExists)
        }
        return kept
    }

    /// Writes `data` to `url`, which must not exist yet.
    static func writeNewFile(_ data: Data, at url: URL, _ fileSystem: any FileSystem) throws(FileSystemError)
    {
        let temporary = try fileSystem.writeTemporary(data, for: url, permissionsFrom: url)
        defer { fileSystem.discard(temporary.url) }
        try fileSystem.publish(temporary, as: url)
    }
}

/// An editing lock (ADR 0020), held for as long as this lives, with the record that tells
/// others about it where the `flock` alone can't. Dropping the last reference releases it,
/// first taking our record back out of the file if it's still ours. That does file I/O, so
/// drop the last reference off the main actor.
final class HeldLock: Sendable {
    private let lock: ExclusiveFileLock
    /// What this lock wrote into its file, where the `flock` alone can't be trusted.
    private let record: LockRecord?

    private init(lock: consuming ExclusiveFileLock, record: LockRecord?) {
        self.lock = lock
        self.record = record
    }

    /// The file is never removed: see `ExclusiveFileLock`. A record that isn't ours (someone
    /// chose "Open Anyway") is left alone.
    deinit {
        guard let record, (try? lock.contents()).flatMap(LockRecord.decode) == record else { return }
        do {
            try lock.replaceContents(with: Data())
        } catch {
            Log.store.error("couldn't clear this Mac's record from a lock file", error.logMetadata)
        }
    }

    enum Attempt {
        case held(HeldLock)
        case readOnly(ReadOnlyReason)
    }

    /// Locks `file` for editing. Where the `flock` can't keep out other Macs, a live record of
    /// someone else's makes it read-only, unless `policy` opens it anyway.
    static func take(
        _ file: URL, _ fileSystem: any FileSystem, _ policy: LockRecordPolicy, _ opener: Opener
    ) -> Attempt {
        let lock: ExclusiveFileLock
        switch fileSystem.lock(file) {
        case .acquired(let acquired): lock = acquired
        case .heldElsewhere: return .readOnly(.openElsewhere)
        case .failed(let error): return .readOnly(.lockUnavailable(error))
        }
        guard lock.enforcement == .none || fileSystem.locality(of: file) == .network else {
            return .held(HeldLock(lock: lock, record: nil))
        }
        let existing = (try? lock.contents()).flatMap(LockRecord.decode)
        if let other = LockRecord.blocking(existing, opener: opener, policy: policy) {
            return .readOnly(
                other.hostID == opener.mac.id ? .openInAnotherProcess(other) : .openOnAnotherMac(other))
        }
        let ours = LockRecord(opener, since: .now)
        do {
            try lock.replaceContents(with: ours.encoded())
        } catch {
            Log.store.error(
                "couldn't record this process in a lock file; others may not see it's open",
                ["error": .error(LoggedError(error))])
            return .held(HeldLock(lock: lock, record: nil))
        }
        return .held(HeldLock(lock: lock, record: ours))
    }
}

/// Runs `body`, turning its file-system error into the caller's error type.
func wrapping<T, E: Error>(
    _ wrap: (FileSystemError) -> E, _ body: () throws(FileSystemError) -> T
) throws(E) -> T {
    do {
        return try body()
    } catch {
        throw wrap(error)
    }
}
