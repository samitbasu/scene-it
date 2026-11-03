import Foundation

/// A package's `Archive/` (PLAN §5.5, ADR 0022): the filed copies `saveNNNN.md`, each an exact
/// copy of `book.md` written once and locked, and `index.md`, which holds everything editable
/// about them.
///
/// It never changes a filed copy: a new one is published under a free name (never replacing
/// anything), and only `index.md` is ever rewritten.
struct Archive {
    let layout: PackageLayout
    let fileSystem: any FileSystem

    enum Access {
        case readOnly
        /// The book is open for editing, so its lock is held: a reconciled index may be saved.
        case writable
    }

    // MARK: Reconciliation

    /// Lists `Archive/`, reads its index and reconciles them; with `.writable`, saves the
    /// reconciled index if it differs. A package with no `Archive/` has an empty one.
    func reconcile(_ access: Access) -> ReconciledArchive {
        let listing: [DirectoryEntry]
        switch self.listing() {
        case .success(let entries):
            listing = entries
        case .failure(let error):
            let parsed = (try? readIndex()) ?? Self.emptyIndex
            return report(
                ReconciledArchive(
                    index: parsed.index, notices: [.archiveUnreadable(error)], next: nil,
                    rewrite: .unneeded))
        }
        let parsed: ParsedArchiveIndex
        var unreadable: [ArchiveNotice] = []
        do {
            parsed = try readIndex()
        } catch {
            parsed = Self.emptyIndex
            unreadable = [.indexUnreadable(error)]
        }
        let reconciled = reconcile(listing, parsed)
        guard unreadable.isEmpty else {
            return report(
                ReconciledArchive(
                    index: reconciled.index, notices: unreadable + reconciled.notices, next: reconciled.next,
                    rewrite: .unneeded))
        }
        guard access == .writable, reconciled.rewrite == .needed else { return report(reconciled) }
        do throws(IndexWriteFailure) {
            try write(reconciled.index)
            return report(reconciled)
        } catch {
            return report(
                ReconciledArchive(
                    index: reconciled.index, notices: reconciled.notices + [.indexNotSaved(error)],
                    next: reconciled.next, rewrite: reconciled.rewrite))
        }
    }

    private func reconcile(_ listing: [DirectoryEntry], _ parsed: ParsedArchiveIndex) -> ReconciledArchive {
        ArchiveReconciliation.reconcile(
            listing: listing, index: parsed, modified: modifiedDay, counts: counts)
    }

    private func report(_ reconciled: ReconciledArchive) -> ReconciledArchive {
        for notice in reconciled.notices { notice.log() }
        return reconciled
    }

    // MARK: Filing

    /// Files `bytes`, which are exactly what `book.md` holds: publishes them as the next
    /// `saveNNNN.md`, locks it, and records `record` in the index.
    ///
    /// Only the copy itself can fail the filing. Once it's published, a lock that doesn't take
    /// or an index that can't be updated is reported in the outcome: the copy stays, and the
    /// next reconciliation lists it.
    func file(_ bytes: Data, as record: FilingRecord) throws(FilingFailure) -> FilingOutcome {
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
        let index = recordInIndex(copy)
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

    /// Sets the immutable flag, then checks it's there: some volumes accept the call and keep
    /// nothing.
    private func lock(_ copy: URL) -> CopyLock {
        do {
            try fileSystem.makeImmutable(copy)
            guard case .file(_, .locked?)? = try fileSystem.item(at: copy) else {
                Log.store.error("a filed copy's locked flag didn't take; the disk doesn't keep it")
                return .notLocked(.flagNotKept)
            }
            return .locked
        } catch {
            Log.store.error("couldn't lock a filed copy", error.logMetadata)
            return .notLocked(.refused(error))
        }
    }

    /// Reconciles the index with the folder as it is now, the new copy included, and gives
    /// `copy` its section.
    private func recordInIndex(_ copy: FiledCopy) -> IndexUpdate {
        let parsed: ParsedArchiveIndex
        let listing: [DirectoryEntry]
        do throws(FileSystemError) {
            parsed = try readIndex()
            listing = try self.listing().get()
        } catch {
            Log.store.error("couldn't read the archive to record a filed copy", error.logMetadata)
            return .notUpdated(.couldNotRead(error))
        }
        let reconciled = reconcile(listing, parsed)
        for notice in reconciled.notices where notice != .listedWithoutEntry(copy.number) { notice.log() }
        if case .refused(let format) = reconciled.rewrite { return .notUpdated(.newerFormat(format)) }
        var index = reconciled.index
        index.copies.removeAll { $0.number == copy.number }
        index.copies.append(copy)
        index.copies.sort { $0.number < $1.number }
        do throws(IndexWriteFailure) {
            try write(index)
            return .updated(index)
        } catch {
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

    /// A missing index is an empty one; anything at its name that isn't a readable file is a
    /// failure, so the index is never rewritten over what it might hold.
    private func readIndex() throws(FileSystemError) -> ParsedArchiveIndex {
        let bytes: Data
        do {
            bytes = try fileSystem.read(layout.archiveIndex)
        } catch  where error.cause == .notFound {
            return Self.emptyIndex
        }
        return ArchiveIndexFormat.parse(bytes, filed: modifiedDay)
    }

    private func write(_ index: ArchiveIndex) throws(IndexWriteFailure) {
        let bytes: Data
        do {
            bytes = try ArchiveIndexFormat.verifiedSerialization(of: index)
        } catch {
            Log.store.fault("the serialized archive index failed verification")
            throw .verification(error)
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
    /// Every name from the next number on is taken, or the numbers ran out.
    case noFreeNumber
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

    var logSymbol: StaticString {
        switch self {
        case .locked: "locked"
        case .notLocked(.refused): "refused"
        case .notLocked(.flagNotKept): "flagNotKept"
        }
    }
}

public enum LockFailure: Hashable, Sendable {
    /// Setting or checking the flag failed: typically a volume with no such flag (FAT, exFAT).
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

extension ArchiveNotice {
    fileprivate func log() {
        switch self {
        case .listedWithoutEntry(let number):
            Log.store.info(
                "listed a filed copy the archive index didn't have", ["number": .count(number.value)])
        case .droppedEntryWithoutFile(let number):
            Log.store.error(
                "dropped an archive index entry whose filed copy is missing", ["number": .count(number.value)]
            )
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
