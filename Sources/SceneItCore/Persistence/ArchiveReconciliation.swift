/// Launch reconciliation (PLAN §5.5, book format §8): what the File Cabinet lists, given the
/// `Archive/` folder's entries and its parsed index. A pure function: the facts it needs about
/// a filed copy (its modification day, its counts) come from the caller.
public enum ArchiveReconciliation {
    /// - A filed copy with no section is listed with `pending`'s record for it if there is one
    ///   (a filing whose index write failed) and the copy's `digest` is the record's, else with
    ///   no tags; its counts are `counts(number)`. A digest that can't be read isn't the record's.
    /// - A section whose filed copy isn't in `listing` (renamed, moved, re-cased, replaced by a
    ///   link) isn't listed, and its lines are kept in the index's `### Unparsed`.
    /// - A section with no counts gets `counts(number)`.
    /// - Anything in `listing` that isn't a regular file named `saveNNNN.md`, numbered up to
    ///   `FiledCopyNumber.highest`, is ignored.
    ///
    /// `modified` gives a filed copy's modification day, the date of a copy with no section;
    /// pass the same function to `ArchiveIndexFormat.parse`.
    public static func reconcile(
        listing: [DirectoryEntry], index parsed: ParsedArchiveIndex,
        modified: (FiledCopyNumber) -> CalendarDay, counts: (FiledCopyNumber) -> FiledCopyCounts?,
        pending: [FiledCopyNumber: PendingRecord], digest: (FiledCopyNumber) -> ContentDigest?
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
            if copy.counts == nil { copy.counts = counts(copy.number) }
            copies.append(copy)
        }
        let indexed = Set(parsed.index.copies.map(\.number))
        for number in onDisk.sorted() where !indexed.contains(number) {
            switch pending[number] {
            case let pending? where digest(number) == pending.copy:
                let record = pending.record
                copies.append(
                    FiledCopy(
                        number: number, filed: record.filed, tags: record.tags, note: record.note,
                        counts: counts(number)))
                notices.append(.recordedPendingEntry(number))
            case let pending:
                copies.append(FiledCopy(number: number, filed: modified(number), counts: counts(number)))
                notices.append(
                    pending == nil ? .listedWithoutEntry(number) : .pendingEntryForAnotherCopy(number))
            }
        }
        copies.sort { $0.number < $1.number }
        let index = ArchiveIndex(copies: copies, errors: errors)
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
                index == parsed.index ? .unneeded : .needed
            }
        return ReconciledArchive(index: index, notices: notices, next: next(after: onDisk), rewrite: rewrite)
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

/// What reconciliation found.
public struct ReconciledArchive: Hashable, Sendable {
    /// What the File Cabinet lists.
    public let index: ArchiveIndex
    public let notices: [ArchiveNotice]
    /// The number the next filed copy gets; `nil` when there's none left.
    public let next: FiledCopyNumber?
    public let rewrite: IndexRewrite

    /// The same, with `more` noticed too.
    func adding(_ more: [ArchiveNotice]) -> ReconciledArchive {
        ReconciledArchive(index: index, notices: notices + more, next: next, rewrite: rewrite)
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
