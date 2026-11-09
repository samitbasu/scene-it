import Foundation

/// A package's `Archive/` (PLAN §5.5, ADR 0022): the filed copies `saveNNNN.md`, each an exact
/// copy of `book.md` written once and locked, and `index.md`, which holds everything editable
/// about them.
///
/// It never changes a filed copy: a new one is published under a free name (never replacing
/// anything), and only `index.md` is ever rewritten, after keeping its original when the
/// rewrite would change what was written there.
struct Archive {
    let layout: PackageLayout
    let fileSystem: any FileSystem

    enum Access {
        case readOnly
        /// The book is open for editing, so its lock is held: a reconciled index may be saved,
        /// and a filed copy missing its locked flag is locked.
        case writable
    }

    /// Records for filed copies whose filing couldn't save their section (`ArchiveReconciliation`).
    typealias Pending = [FiledCopyNumber: FilingRecord]

    // MARK: Reconciliation

    /// Lists `Archive/`, reads its index and reconciles them. With `.writable`, also locks any
    /// filed copy that isn't locked (a filing interrupted between publishing and locking) and
    /// saves the reconciled index if it differs. A package with no `Archive/` has an empty one.
    func reconcile(_ access: Access, pending: Pending = [:]) -> ReconciledArchive {
        let listing: [DirectoryEntry]
        switch self.listing() {
        case .success(let entries):
            listing = entries
        case .failure(let error):
            let parsed = (try? readIndex())?.parsed ?? Self.emptyIndex
            return report(
                ReconciledArchive(
                    index: parsed.index, notices: [.archiveUnreadable(error)], next: nil, rewrite: .unneeded),
                .notSaved)
        }
        let locking = access == .writable ? lockUnlockedCopies(in: listing) : []
        let file: IndexFile
        do {
            file = try readIndex()
        } catch {
            let reconciled = reconcile(listing, Self.emptyIndex, pending)
            return report(
                ReconciledArchive(
                    index: reconciled.index,
                    notices: [.indexUnreadable(error)] + reconciled.notices + locking,
                    next: reconciled.next, rewrite: .unneeded),
                .notSaved)
        }
        let reconciled = reconcile(listing, file.parsed, pending).adding(locking)
        guard access == .writable,
            reconciled.rewrite == .needed || reconciled.rewrite == .neededKeepingOriginal
        else { return report(reconciled, .notSaved) }
        do throws(IndexWriteFailure) {
            let kept = try replaceIndex(
                with: reconciled.index,
                keepingOriginal: reconciled.rewrite == .neededKeepingOriginal ? file.bytes : nil)
            return report(reconciled.adding(kept), .saved)
        } catch {
            return report(reconciled.adding([.indexNotSaved(error)]), .notSaved)
        }
    }

    private func reconcile(_ listing: [DirectoryEntry], _ parsed: ParsedArchiveIndex, _ pending: Pending)
        -> ReconciledArchive
    {
        ArchiveReconciliation.reconcile(
            listing: listing, index: parsed, modified: modifiedDay, counts: counts, pending: pending)
    }

    private func report(_ reconciled: ReconciledArchive, _ index: IndexState) -> ReconciledArchive {
        for notice in reconciled.notices { notice.log(index) }
        return reconciled
    }

    private func lockUnlockedCopies(in listing: [DirectoryEntry]) -> [ArchiveNotice] {
        ArchiveReconciliation.filedCopies(in: listing).compactMap { number in
            let copy = layout.filedCopy(number)
            if case .file(_, .locked?)? = try? fileSystem.item(at: copy) { return nil }
            switch lock(copy) {
            case .locked: return .lockedUnlockedCopy(number)
            case .notLocked(let failure): return .couldNotLock(number, failure)
            case .unverified(let error): return .couldNotLock(number, .refused(error))
            }
        }
    }

    // MARK: Filing

    /// Files `bytes`, which are exactly what `book.md` holds: publishes them as the next
    /// `saveNNNN.md`, locks it, and records `record` in the index, along with `pending`'s records.
    ///
    /// Only the copy itself can fail the filing. Once it's published, a lock that doesn't take
    /// or an index that can't be updated is reported in the outcome: the copy stays, and the
    /// next reconciliation lists it.
    func file(_ bytes: Data, as record: FilingRecord, pending: Pending = [:]) throws(FilingFailure)
        -> FilingOutcome
    {
        try requireFolder()
        let existing: [DirectoryEntry]
        switch listing() {
        case .success(let entries): existing = entries
        case .failure(let error): throw .fileSystem(error)
        }
        guard let first = ArchiveReconciliation.next(after: ArchiveReconciliation.filedCopies(in: existing))
        else { throw .noFreeNumber }
        let temporary: TemporaryFile
        do {
            temporary = try fileSystem.writeTemporary(
                bytes, for: layout.filedCopy(first), permissionsFrom: layout.book)
        } catch {
            throw .fileSystem(error)
        }
        guard (try? fileSystem.read(temporary.url)) == bytes else {
            fileSystem.discard(temporary.url)
            throw .copyDiffers
        }
        let number: FiledCopyNumber
        do throws(FilingFailure) {
            number = try publish(temporary, from: first)
        } catch {
            fileSystem.discard(temporary.url)
            throw error
        }
        let lock = lock(layout.filedCopy(number))
        let copy = FiledCopy(
            number: number, filed: record.filed, tags: record.tags, note: record.note,
            counts: FiledCopyCounts(filedBytes: bytes))
        let index = recordInIndex(copy, pending: pending)
        Log.store.info(
            "filed a copy of the book",
            [
                "number": .count(number.value), "bytes": .bytes(Int64(bytes.count)),
                "locked": .symbol(lock.logSymbol), "index": .symbol(index.logSymbol),
            ])
        return FilingOutcome(number: number, lock: lock, index: index)
    }

    /// Under the first free number from `first` on: another filing that took a number
    /// meanwhile moves this one along, and nothing is ever replaced.
    private func publish(_ temporary: TemporaryFile, from first: FiledCopyNumber) throws(FilingFailure)
        -> FiledCopyNumber
    {
        var number = first
        for _ in 0..<freeNameAttempts {
            do {
                try fileSystem.publish(temporary, as: layout.filedCopy(number))
                return number
            } catch  where error.cause == .alreadyExists {
                guard let next = number.next else { throw .noFreeNumber }
                number = next
            } catch {
                throw .fileSystem(error)
            }
        }
        throw .noFreeNumber
    }

    /// Sets the immutable flag, then checks it's there: some volumes (network shares among
    /// them) refuse it, and a volume could accept it and keep nothing. A check that fails is
    /// tried once more, then reported as unverified, never as unlocked: the flag may be set.
    private func lock(_ copy: URL) -> CopyLock {
        do {
            try fileSystem.makeImmutable(copy)
        } catch {
            Log.store.error("couldn't lock a filed copy", error.logMetadata)
            return .notLocked(.refused(error))
        }
        var lastError: FileSystemError?
        for _ in 0..<2 {
            do {
                guard case .file(_, .locked?)? = try fileSystem.item(at: copy) else {
                    Log.store.error("a filed copy's locked flag didn't take; the disk doesn't keep it")
                    return .notLocked(.flagNotKept)
                }
                return .locked
            } catch {
                lastError = error
            }
        }
        let error = lastError ?? FileSystemError(.inspect, copy, .io)
        Log.store.error("couldn't check a filed copy's locked flag", error.logMetadata)
        return .unverified(error)
    }

    /// Reconciles the index with the folder as it is now, the new copy included, and gives
    /// `copy` its section.
    private func recordInIndex(_ copy: FiledCopy, pending: Pending) -> IndexUpdate {
        let file: IndexFile
        let listing: [DirectoryEntry]
        do throws(FileSystemError) {
            file = try readIndex()
            listing = try self.listing().get()
        } catch {
            Log.store.error("couldn't read the archive to record a filed copy", error.logMetadata)
            return .notUpdated(.couldNotRead(error))
        }
        let reconciled = reconcile(listing, file.parsed, pending)
        let noticed = reconciled.notices.filter { $0 != .listedWithoutEntry(copy.number) }
        if case .refused(let format) = reconciled.rewrite {
            for notice in noticed { notice.log(.notSaved) }
            return .notUpdated(.newerFormat(format))
        }
        var index = reconciled.index
        index.copies.removeAll { $0.number == copy.number }
        index.copies.append(copy)
        index.copies.sort { $0.number < $1.number }
        do throws(IndexWriteFailure) {
            let kept = try replaceIndex(
                with: index, keepingOriginal: reconciled.rewrite == .neededKeepingOriginal ? file.bytes : nil)
            for notice in noticed + kept { notice.log(.saved) }
            return .updated(index)
        } catch {
            for notice in noticed { notice.log(.notSaved) }
            return .notUpdated(.notWritten(error))
        }
    }

    // MARK: Files

    private static let emptyIndex = ParsedArchiveIndex(
        index: ArchiveIndex(), newEntries: [], declaredFormat: .current)

    private func requireFolder() throws(FilingFailure) {
        let item: FileItem?
        do {
            item = try fileSystem.item(at: layout.archive)
        } catch {
            throw .fileSystem(error)
        }
        switch item {
        case .directory?:
            return
        case .file?, .symbolicLink?, .other?:
            throw .archiveNotAFolder
        case nil:
            do {
                try fileSystem.createDirectory(at: layout.archive)
            } catch  where error.cause == .alreadyExists {
                return
            } catch {
                throw .fileSystem(error)
            }
        }
    }

    /// Missing is empty.
    private func listing() -> Result<[DirectoryEntry], FileSystemError> {
        do {
            return .success(try fileSystem.contents(of: layout.archive))
        } catch  where error.cause == .notFound {
            return .success([])
        } catch {
            return .failure(error)
        }
    }

    /// `index.md` as read: its bytes (`nil` when there's none) and what they parse to.
    private struct IndexFile {
        let bytes: Data?
        let parsed: ParsedArchiveIndex
    }

    /// A missing index is an empty one; anything at its name that isn't a readable file is a
    /// failure, so the index is never rewritten over what it might hold.
    private func readIndex() throws(FileSystemError) -> IndexFile {
        let bytes: Data
        do {
            bytes = try fileSystem.read(layout.archiveIndex)
        } catch  where error.cause == .notFound {
            return IndexFile(bytes: nil, parsed: Self.emptyIndex)
        }
        return IndexFile(bytes: bytes, parsed: ArchiveIndexFormat.parse(bytes, filed: modifiedDay))
    }

    /// Writes `index` over `index.md`, first keeping `original` (when given) under a new
    /// `index.md.original-<UTC time>.md`. If the original can't be kept, nothing is written.
    private func replaceIndex(with index: ArchiveIndex, keepingOriginal original: Data?)
        throws(IndexWriteFailure)
        -> [ArchiveNotice]
    {
        let bytes: Data
        do {
            bytes = try ArchiveIndexFormat.verifiedSerialization(of: index)
        } catch {
            Log.store.fault("the serialized archive index failed verification")
            throw .verification(error)
        }
        var notices: [ArchiveNotice] = []
        if let original {
            do throws(FileSystemError) {
                notices.append(.keptOriginalIndex(fileName: try keep(original)))
            } catch {
                Log.store.error(
                    "couldn't keep the archive index's original; left it as it is", error.logMetadata)
                throw .originalNotKept(error)
            }
        }
        do throws(FileSystemError) {
            let temporary = try fileSystem.writeTemporary(
                bytes, for: layout.archiveIndex, permissionsFrom: layout.archiveIndex)
            do {
                try fileSystem.move(temporary.url, over: layout.archiveIndex)
            } catch {
                fileSystem.discard(temporary.url)
                throw error
            }
        } catch {
            Log.store.error("couldn't save the archive index", error.logMetadata)
            throw .fileSystem(error)
        }
        return notices
    }

    private func keep(_ original: Data) throws(FileSystemError) -> String {
        let now = Date.now
        let temporary = try fileSystem.writeTemporary(
            original, for: layout.originalIndex(at: now, attempt: 1), permissionsFrom: layout.archiveIndex)
        let kept: URL?
        do {
            kept = try fileSystem.publishUnderFreeName(temporary) {
                layout.originalIndex(at: now, attempt: $0)
            }
        } catch {
            fileSystem.discard(temporary.url)
            throw error
        }
        guard let kept else {
            fileSystem.discard(temporary.url)
            throw FileSystemError(
                .publish, layout.originalIndex(at: now, attempt: freeNameAttempts), .alreadyExists)
        }
        return kept.lastPathComponent
    }

    /// The local day a filed copy was last modified, or today if it can't be inspected.
    private func modifiedDay(_ number: FiledCopyNumber) -> CalendarDay {
        let modified: Date =
            if case .file(let metadata, _)? = try? fileSystem.item(at: layout.filedCopy(number)) {
                metadata.modified
            } else {
                .now
            }
        return CalendarDay(modified, in: .current)
    }

    /// Read-only: a filed copy is parsed, never opened as a book.
    private func counts(_ number: FiledCopyNumber) -> FiledCopyCounts? {
        guard let bytes = try? fileSystem.read(layout.filedCopy(number)) else { return nil }
        return FiledCopyCounts(filedBytes: bytes)
    }
}

/// What the writer gives a copy as it's filed (PLAN §7.1). `FiledCopy` admits the text.
public struct FilingRecord: Hashable, Sendable {
    public let filed: CalendarDay
    public let tags: [String]
    public let note: String

    public init(filed: CalendarDay, tags: [String] = [], note: String = "") {
        self.filed = filed
        self.tags = tags
        self.note = note
    }
}

/// What File a Copy did.
public enum FilingResult: Hashable, Sendable {
    case filed(FilingOutcome)
    case failed(FilingFailure)
    /// No book is open for editing.
    case unavailable
}

/// Why nothing was filed. `Archive/` holds no new copy.
public enum FilingFailure: Error, Hashable, Sendable {
    /// The book couldn't be saved first.
    case save(SaveError)
    /// A save was still running after `AutosavePolicy.quitGracePeriod`.
    case stillSaving
    /// After saving, `book.md` didn't hold the book: another program wrote it.
    case bookChangedOnDisk
    /// The copy's bytes didn't read back as `book.md`'s.
    case copyDiffers
    case archiveNotAFolder
    /// Every name from the next number on is taken, or a copy is numbered
    /// `FiledCopyNumber.highest`.
    case noFreeNumber
    /// The book was closed before the filing ran.
    case unavailable
    case fileSystem(FileSystemError)
}

/// What filing did once the copy was published as `number`.
public struct FilingOutcome: Hashable, Sendable {
    public let number: FiledCopyNumber
    public let lock: CopyLock
    public let index: IndexUpdate

    /// Everything happened: the copy is locked and indexed.
    public var isComplete: Bool {
        if case .updated = index { lock == .locked } else { false }
    }
}

public enum CopyLock: Hashable, Sendable {
    case locked
    /// The copy is filed but can be changed: Scene It still never writes to it.
    case notLocked(LockFailure)
    /// The flag was set, but checking it failed: the copy may or may not be locked. The next
    /// reconciliation checks again.
    case unverified(FileSystemError)

    var logSymbol: StaticString {
        switch self {
        case .locked: "locked"
        case .notLocked(.refused): "refused"
        case .notLocked(.flagNotKept): "flagNotKept"
        case .unverified: "unverified"
        }
    }
}

public enum LockFailure: Hashable, Sendable {
    /// Setting the flag failed: a volume with no such flag (some network shares; APFS, HFS+,
    /// FAT and exFAT all keep it on macOS 27), or a file-system error.
    case refused(FileSystemError)
    /// The volume accepted the flag but doesn't keep it.
    case flagNotKept
}

public enum IndexUpdate: Hashable, Sendable {
    case updated(ArchiveIndex)
    /// The copy has no section; the next reconciliation lists it with no tags or note.
    case notUpdated(IndexFailure)

    var logSymbol: StaticString {
        switch self {
        case .updated: "updated"
        case .notUpdated(.couldNotRead): "couldNotRead"
        case .notUpdated(.newerFormat): "newerFormat"
        case .notUpdated(.notWritten): "notWritten"
        }
    }
}

public enum IndexFailure: Hashable, Sendable {
    case couldNotRead(FileSystemError)
    /// A newer Scene It wrote the index, so it's left as it is.
    case newerFormat(FormatVersion)
    case notWritten(IndexWriteFailure)
}

/// Whether the index a notice was logged for is on disk, for what the log says was recorded.
private enum IndexState {
    case saved
    case notSaved
}

extension ArchiveNotice {
    fileprivate func log(_ index: IndexState) {
        switch self {
        case .listedWithoutEntry(let number):
            Log.store.info(
                "listed a filed copy the archive index didn't have", ["number": .count(number.value)])
        case .recordedPendingEntry(let number):
            switch index {
            case .saved:
                Log.store.info(
                    "recorded a filed copy's tags and note that its filing couldn't save",
                    ["number": .count(number.value)])
            case .notSaved:
                Log.store.info(
                    "listed a filed copy's pending tags and note without saving them",
                    ["number": .count(number.value)])
            }
        case .keptEntryWithoutFile(let number):
            Log.store.error(
                "kept an archive index entry whose filed copy is missing as unparsed lines",
                ["number": .count(number.value)])
        case .numberOutOfRange(let number):
            Log.store.error(
                "ignored a filed copy numbered past the highest", ["number": .count(number.value)])
        case .lockedUnlockedCopy(let number):
            Log.store.info("locked a filed copy that wasn't locked", ["number": .count(number.value)])
        case .couldNotLock(let number, _):
            Log.store.error("couldn't lock a filed copy that wasn't locked", ["number": .count(number.value)])
        case .keptOriginalIndex:
            Log.store.info("kept the archive index's original before rewriting it")
        case .indexFromNewerVersion(let format):
            Log.store.info(
                "the archive index is from a newer version; it won't be rewritten",
                ["format": .count(format.number)])
        case .archiveUnreadable(let error):
            Log.store.error("couldn't list the archive", error.logMetadata)
        case .indexUnreadable(let error):
            Log.store.error("couldn't read the archive index", error.logMetadata)
        case .indexNotSaved:
            Log.store.error("couldn't save the reconciled archive index")
        }
    }
}
