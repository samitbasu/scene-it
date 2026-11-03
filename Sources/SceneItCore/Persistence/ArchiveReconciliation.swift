/// Launch reconciliation (PLAN §5.5, book format §8): what the File Cabinet lists, given the
/// `Archive/` folder's entries and its parsed index. A pure function: the facts it needs about
/// a filed copy (its modification day, its counts) come from the caller.
public enum ArchiveReconciliation {
    /// - A filed copy with no section is listed with no tags and `counts(number)`.
    /// - A section whose filed copy isn't in `listing` is dropped.
    /// - A section with no counts gets `counts(number)`.
    /// - Anything in `listing` that isn't a regular file named `saveNNNN.md` is ignored.
    ///
    /// `modified` gives a filed copy's modification day, the date of a copy with no section;
    /// pass the same function to `ArchiveIndexFormat.parse`.
    public static func reconcile(
        listing: [DirectoryEntry], index parsed: ParsedArchiveIndex,
        modified: (FiledCopyNumber) -> CalendarDay, counts: (FiledCopyNumber) -> FiledCopyCounts?
    ) -> ReconciledArchive {
        let onDisk = Set(filedCopies(in: listing))
        var notices: [ArchiveNotice] = []
        if parsed.isNewerThanSupported, let format = parsed.declaredFormat {
            notices.append(.indexFromNewerVersion(format))
        }
        var copies: [FiledCopy] = []
        for var copy in parsed.index.copies {
            guard onDisk.contains(copy.number) else {
                notices.append(.droppedEntryWithoutFile(copy.number))
                continue
            }
            if copy.counts == nil { copy.counts = counts(copy.number) }
            copies.append(copy)
        }
        let indexed = Set(parsed.index.copies.map(\.number))
        for number in onDisk.sorted() where !indexed.contains(number) {
            copies.append(FiledCopy(number: number, filed: modified(number), counts: counts(number)))
            notices.append(.listedWithoutEntry(number))
        }
        copies.sort { $0.number < $1.number }
        let index = ArchiveIndex(copies: copies, errors: parsed.index.errors)
        let rewrite: IndexRewrite =
            if parsed.isNewerThanSupported, let format = parsed.declaredFormat {
                .refused(newerFormat: format)
            } else {
                index == parsed.index ? .unneeded : .needed
            }
        return ReconciledArchive(index: index, notices: notices, next: next(after: onDisk), rewrite: rewrite)
    }

    /// The filed copies in a listing of `Archive/`: regular files named exactly `saveNNNN.md`.
    public static func filedCopies(in listing: [DirectoryEntry]) -> [FiledCopyNumber] {
        listing.filter { $0.kind == .file }.compactMap { FiledCopyNumber(fileName: $0.name) }
    }

    /// One more than the highest number in use, whatever the gaps below it; `nil` past the
    /// largest number.
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
}

public enum IndexRewrite: Hashable, Sendable {
    /// The index already says what `ReconciledArchive.index` says.
    case unneeded
    case needed
    /// A newer Scene It wrote the index: replacing it here could lose what that version added
    /// (as ADR 0024's rule for books), so it's never rewritten.
    case refused(newerFormat: FormatVersion)
}

/// Something reconciliation or filing noticed about the archive, for the log and the writer.
public enum ArchiveNotice: Hashable, Sendable {
    /// A filed copy the index had no section for: listed with no tags, its counts computed.
    case listedWithoutEntry(FiledCopyNumber)
    /// A section whose filed copy is gone: dropped.
    case droppedEntryWithoutFile(FiledCopyNumber)
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
}
