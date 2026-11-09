import Foundation

/// Launch reconciliation (PLAN §5.5, book format §8): what the File Cabinet lists, given the
/// `Archive/` folder's entries and its parsed index. A pure function: the facts it needs about
/// a filed copy (its modification day, its counts, its digest) come from the caller.
public enum ArchiveReconciliation {
    /// - A filed copy with no section is listed with `pending`'s record for it if there is one
    ///   (a filing whose index write failed) and the copy's digest is the record's, else with
    ///   no tags. A copy whose file can't be read is listed with no tags but left out of
    ///   `indexToWrite`, so its record is checked again next time.
    /// - A filed copy's counts, where its section has none, come from `facts(number)`.
    /// - A section whose filed copy isn't in `listing` (renamed, moved, re-cased, replaced by a
    ///   link) isn't listed, and its lines are kept in the index's `### Unparsed`.
    /// - Anything in `listing` that isn't a regular file named `saveNNNN.md`, numbered up to
    ///   `FiledCopyNumber.highest`, is ignored.
    ///
    /// `modified` gives a filed copy's modification day, the date of a copy with no section;
    /// pass the same function to `ArchiveIndexFormat.parse`.
    public static func reconcile(
        listing: [DirectoryEntry], index parsed: ParsedArchiveIndex,
        modified: (FiledCopyNumber) -> CalendarDay, facts: (FiledCopyNumber) -> FiledCopyFacts?,
        pending: [FiledCopyNumber: PendingRecord]
    ) -> ReconciledArchive {
        let named = numbered(listing)
        let onDisk = Set(named.filter(\.isInRange))
        var notices: [ArchiveNotice] = named.filter { !$0.isInRange }.sorted().map(
            ArchiveNotice.numberOutOfRange)
        if parsed.isNewerThanSupported, let format = parsed.declaredFormat {
            notices.append(.indexFromNewerVersion(format))
        }
        var copies: [FiledCopy] = []
        var errors = parsed.index.errors
        for var copy in parsed.index.copies {
            guard onDisk.contains(copy.number) else {
                notices.append(.keptEntryWithoutFile(copy.number))
                errors += ArchiveIndexFormat.sectionLines(copy).map { ErrorEntry(.line, $0) } + copy.errors
                continue
            }
            if copy.counts == nil { copy.counts = facts(copy.number)?.counts }
            copies.append(copy)
        }
        let indexed = Set(parsed.index.copies.map(\.number))
        var unverified: Set<FiledCopyNumber> = []
        for number in onDisk.sorted() where !indexed.contains(number) {
            let read = facts(number)
            let unlisted = FiledCopy(number: number, filed: modified(number), counts: read?.counts)
            switch (pending[number], read) {
            case (nil, _):
                copies.append(unlisted)
                notices.append(.listedWithoutEntry(number))
            case (let pending?, let read?) where read.digest == pending.digest:
                let record = pending.record
                copies.append(
                    FiledCopy(
                        number: number, filed: record.filed, tags: record.tags, note: record.note,
                        counts: read.counts))
                notices.append(.recordedPendingEntry(number))
            case (.some, .some):
                copies.append(unlisted)
                notices.append(.pendingEntryForAnotherCopy(number))
            case (.some, nil):
                copies.append(unlisted)
                unverified.insert(number)
                notices.append(.pendingEntryUnverified(number))
            }
        }
        copies.sort { $0.number < $1.number }
        let index = ArchiveIndex(copies: copies, errors: errors)
        let toWrite = ReconciledArchive.leavingOut(unverified, of: index)
        let changesWhatWasWritten =
            !parsed.newEntries.isEmpty
            || notices.contains { if case .keptEntryWithoutFile = $0 { true } else { false } }
        let rewrite: IndexRewrite =
            if parsed.isNewerThanSupported, let format = parsed.declaredFormat {
                .refused(newerFormat: format)
            } else if changesWhatWasWritten {
                // Even when the index reads as it'll be written: until it's rewritten, the
                // repair's entries would be new again at every reconciliation.
                .neededKeepingOriginal
            } else {
                toWrite == parsed.index ? .unneeded : .needed
            }
        return ReconciledArchive(
            index: index, unverified: unverified, notices: notices, next: next(after: onDisk),
            rewrite: rewrite)
    }

    /// The filed copies in a listing of `Archive/` that filing counts: regular files named
    /// exactly `saveNNNN.md`, up to `FiledCopyNumber.highest`.
    public static func filedCopies(in listing: [DirectoryEntry]) -> [FiledCopyNumber] {
        numbered(listing).filter(\.isInRange)
    }

    private static func numbered(_ listing: [DirectoryEntry]) -> [FiledCopyNumber] {
        listing.filter { $0.kind == .file }.compactMap { FiledCopyNumber(fileName: $0.name) }
    }

    /// One more than the highest number in use, whatever the gaps below it; `nil` past
    /// `FiledCopyNumber.highest`.
    public static func next(after numbers: some Sequence<FiledCopyNumber>) -> FiledCopyNumber? {
        guard let highest = numbers.max() else { return .first }
        return highest.next
    }
}

/// A filed copy's facts that reconciliation reads from its file.
public struct FiledCopyFacts: Hashable, Sendable {
    public let counts: FiledCopyCounts?
    public let digest: ContentDigest

    public init(counts: FiledCopyCounts?, digest: ContentDigest) {
        self.counts = counts
        self.digest = digest
    }

    public init(filedBytes: Data) {
        self.init(counts: FiledCopyCounts(filedBytes: filedBytes), digest: ContentDigest(filedBytes))
    }
}

/// What reconciliation found.
public struct ReconciledArchive: Hashable, Sendable {
    /// What the File Cabinet lists.
    public let index: ArchiveIndex
    /// Copies listed in `index` with no tags because their files couldn't be read to check
    /// their pending records against.
    public let unverified: Set<FiledCopyNumber>
    public let notices: [ArchiveNotice]
    /// The number the next filed copy gets; `nil` when there's none left.
    public let next: FiledCopyNumber?
    public let rewrite: IndexRewrite

    /// What `Archive/index.md` may say: `index` without the `unverified` copies, so the next
    /// reconciliation checks their records again.
    public var indexToWrite: ArchiveIndex {
        Self.leavingOut(unverified, of: index)
    }

    static func leavingOut(_ unverified: Set<FiledCopyNumber>, of index: ArchiveIndex) -> ArchiveIndex {
        var written = index
        written.copies.removeAll { unverified.contains($0.number) }
        return written
    }

    /// The same, with `more` noticed too.
    func adding(_ more: [ArchiveNotice]) -> ReconciledArchive {
        ReconciledArchive(
            index: index, unverified: unverified, notices: notices + more, next: next, rewrite: rewrite)
    }

    /// Whether `Archive/index.md` says what `index` says: nothing stopped it being read or saved.
    public var isSaved: Bool {
        if case .refused = rewrite { return false }
        return !notices.contains { notice in
            switch notice {
            case .archiveUnreadable, .indexUnreadable, .indexNotSaved: true
            default: false
            }
        }
    }
}

public enum IndexRewrite: Hashable, Sendable {
    /// The index already says what `ReconciledArchive.index` says.
    case unneeded
    case needed
    /// The rewrite changes what the writer or another program wrote (the parse made new error
    /// entries, or a section's file is gone), so the original is kept first. New entries always
    /// need it, so the repair is made once and the entries aren't new at the next reconciliation.
    case neededKeepingOriginal
    /// A newer Scene It wrote the index: replacing it here could lose what that version added
    /// (as ADR 0024's rule for books), so it's never rewritten.
    case refused(newerFormat: FormatVersion)
}

/// Something reconciliation or filing noticed about the archive, for the log and the writer.
public enum ArchiveNotice: Hashable, Sendable {
    /// A filed copy the index had no section for: listed with no tags, its counts computed.
    case listedWithoutEntry(FiledCopyNumber)
    /// A filed copy whose filing couldn't save its section: listed with what the writer gave.
    case recordedPendingEntry(FiledCopyNumber)
    /// A filed copy with no section whose number has a pending record given to a different file
    /// there (`Archive/` was replaced): listed with no tags, as `listedWithoutEntry`.
    case pendingEntryForAnotherCopy(FiledCopyNumber)
    /// A filed copy with no section whose pending record couldn't be checked, because its file
    /// couldn't be read (evicted by a sync service, say): listed with no tags, not written to
    /// the index, and its record stays pending.
    case pendingEntryUnverified(FiledCopyNumber)
    /// A section whose filed copy isn't there: not listed, and kept in `### Unparsed`.
    case keptEntryWithoutFile(FiledCopyNumber)
    /// A `saveNNNN.md` numbered past `FiledCopyNumber.highest`: not listed or counted.
    case numberOutOfRange(FiledCopyNumber)
    /// A filed copy found without its locked flag (filing was interrupted before locking it):
    /// it was locked.
    case lockedUnlockedCopy(FiledCopyNumber)
    /// A filed copy without its locked flag that couldn't be locked.
    case couldNotLock(FiledCopyNumber, LockFailure)
    /// Before rewriting the index, its original bytes were kept under this name in `Archive/`.
    case keptOriginalIndex(fileName: String)
    /// A newer Scene It wrote the index: it's listed as read, and never rewritten.
    case indexFromNewerVersion(FormatVersion)
    /// `Archive/` couldn't be listed, so nothing was reconciled or rewritten.
    case archiveUnreadable(FileSystemError)
    /// `Archive/index.md` couldn't be read, so the filed copies are listed without their
    /// tags and notes, and the index isn't rewritten.
    case indexUnreadable(FileSystemError)
    /// The reconciled index couldn't be saved; the next open reconciles again.
    case indexNotSaved(IndexWriteFailure)
}

/// Why a new `Archive/index.md` wasn't written.
public enum IndexWriteFailure: Error, Hashable, Sendable {
    case verification(VerificationFailure)
    case fileSystem(FileSystemError)
    /// Its original couldn't be kept first, so it was left as it is.
    case originalNotKept(FileSystemError)
}
