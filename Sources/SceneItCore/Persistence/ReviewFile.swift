import Foundation
import Synchronization

/// Where reviews keep everything but the review file itself (review format §9 Q9): each
/// review's rotated backups, kept originals and lock, in `<root>/<review id>/`, and the locks of
/// new reviews, keyed by their copy, in `<root>/Copies/`. Only the review file sits beside the copy.
public struct ReviewsFolder: Hashable, Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    public static var standard: ReviewsFolder {
        ReviewsFolder(root: SupportFolder.root.appending(path: "Reviews", directoryHint: .isDirectory))
    }

    public func folder(for id: ReviewID) -> URL {
        root.appending(path: id.rawValue, directoryHint: .isDirectory)
    }

    /// Locked while the review is open for editing (ADR 0020, 0042).
    func lock(for id: ReviewID) -> URL {
        folder(for: id).appending(path: ".lock", directoryHint: .notDirectory)
    }

    private var copies: URL {
        root.appending(path: "Copies", directoryHint: .isDirectory)
    }

    /// Locked by a new review of the copy `export` until it has a file of its own, so two new
    /// reviews of one copy can't both be edited (ADR 0042).
    func lock(forNewReviewOf export: ExportID) -> URL {
        copies.appending(path: "\(export).lock", directoryHint: .notDirectory)
    }

    /// The review file `file`, its side files in the review's folder.
    func saved(_ file: URL, id: ReviewID) -> SavedFileLayout {
        SavedFileLayout(file: file, sideFolder: folder(for: id), sideName: "review.md")
    }

    /// Creates the review's folder, and the root above it, if they're missing.
    func makeFolder(for id: ReviewID, _ fileSystem: any FileSystem) throws(FileSystemError) {
        try make([root, folder(for: id)], fileSystem)
    }

    func makeCopiesFolder(_ fileSystem: any FileSystem) throws(FileSystemError) {
        try make([root, copies], fileSystem)
    }

    private func make(_ folders: [URL], _ fileSystem: any FileSystem) throws(FileSystemError) {
        for folder in folders {
            do {
                try fileSystem.createDirectory(at: folder)
            } catch  where error.cause == .alreadyExists {
                guard case .directory? = try fileSystem.item(at: folder) else { throw error }
            }
        }
    }
}

/// Where a review file is, and the folder its side files go in.
public struct ReviewPlace: Hashable, Sendable {
    public let file: URL
    public let id: ReviewID
    public let reviews: ReviewsFolder

    var saved: SavedFileLayout {
        reviews.saved(file, id: id)
    }
}

/// What a review is besides its book (ADR 0042): the copy it's read against, which is never
/// written, the review's ids, and its general notes as they were read.
public struct ReviewContext: Hashable, Sendable {
    /// The review copy's file.
    public let copyFile: URL
    public let copy: ReceivedCopy
    public let id: ReviewID
    public let reviews: ReviewsFolder
    /// The copy the review file says it reviews: the copy's export id, unless the file said
    /// otherwise (review format §4.1 picks only those that match).
    let reviewedCopy: ExportID
    let notes: [Paragraph]

    /// The review whose book is `book`.
    func review(of book: Book) -> Review {
        Review(book: book, notes: notes, copy: reviewedCopy, id: id)
    }
}

/// Why Review Book… couldn't open a file. Nothing was written.
public enum ReviewOpenError: Error, Hashable, Sendable {
    /// The chosen file couldn't be read, or isn't a regular file.
    case unreadable(FileSystemError)
    /// Neither a review copy nor a review file (review format §2.3, §9 Q3).
    case notAReviewCopy(URL)
    /// A copy from a newer Scene It (review format §9 Q4).
    case newerCopy(URL, FormatVersion)
    /// A review file whose copy isn't beside it (review format §4.4).
    case copyNotFound(review: URL)
    /// The review file found for the copy couldn't be read.
    case reviewUnreadable(FileSystemError)
}

/// A review as Review Book… opened it.
public struct LoadedReview: Sendable {
    public let context: ReviewContext
    public let book: Book
    public let access: Access
    /// A review of another copy that has this copy's name, so this review is saved under
    /// another (review format §4.3); told once, at open.
    public let otherReview: URL?

    public enum Access: Sendable {
        case editing(ReviewFile)
        case readOnly(ReadOnlyReason)
    }
}

/// A review open for editing: its copy, read but never written, and its review file, created at
/// the first save that has something to keep (review format §4.1) and from then on saved with the
/// book's safe-save rules (verification against the copy, rotation, atomic writes; ADR 0042).
///
/// It holds the review's lock for as long as it lives; drop the last reference off the main actor.
public final class ReviewFile: Sendable {
    private let copyFile: URL
    private let copy: ReceivedCopy
    private let id: ReviewID
    private let reviews: ReviewsFolder
    private let fileSystem: any FileSystem
    private let opener: Opener
    private let state: Mutex<State>

    /// Each state holds the lock that keeps other writers out: a new review's is its copy's, and
    /// a written one's is its own.
    private enum State {
        /// No review file yet; the first save creates one.
        case unwritten(copyLock: HeldLock)
        case written(Written)
    }

    private struct Written {
        let file: URL
        /// The digest of what was last read from or written to the file.
        var lastSeen: ContentDigest
        let lock: HeldLock
        /// Versions another program wrote, kept beside the review file, by their digest.
        var kept: [ContentDigest: String] = [:]
    }

    private init(_ context: ReviewContext, state: State, fileSystem: any FileSystem, opener: Opener) {
        copyFile = context.copyFile
        copy = context.copy
        id = context.id
        reviews = context.reviews
        self.state = Mutex(state)
        self.fileSystem = fileSystem
        self.opener = opener
    }

    /// The review file, once there is one.
    public var file: URL? {
        state.withLock { state in
            if case .written(let written) = state { written.file } else { nil }
        }
    }

    // MARK: Opening (review format §2.3, §4)

    /// Opens the review copy or review file at `url` for review: the copy and the review that
    /// belongs to it, or a new review if there isn't one. Reads, never writes, except to lock the
    /// review (which creates its folder). A review whose parse made new error entries, or that's
    /// in a newer format, opens read-only and takes no lock (review format §3.8, ADR 0024).
    public static func open(
        _ url: URL, reviews: ReviewsFolder, opened: Timestamp, freshID: @Sendable () -> ReviewID,
        fileSystem: any FileSystem = LocalFileSystem()
    ) throws(ReviewOpenError) -> LoadedReview {
        try open(
            url, reviews: reviews, opened: opened, freshID: freshID, fileSystem: fileSystem, opener: .current)
    }

    static func open(
        _ url: URL, reviews: ReviewsFolder, opened: Timestamp, freshID: () -> ReviewID,
        fileSystem: any FileSystem, opener: Opener
    ) throws(ReviewOpenError) -> LoadedReview {
        let data = try wrapping(ReviewOpenError.unreadable) { () throws(FileSystemError) in
            try readFile(url, fileSystem)
        }
        let finder = ReviewFinder(
            folder: url.deletingLastPathComponent(), fileSystem: fileSystem, opened: opened)
        let parsed = ReviewCopyFormat.parse(data, opened: opened)
        let copyFile: URL
        let copy: ReceivedCopy
        let review: Found
        if let received = ReceivedCopy(parsed) {
            if parsed.parsed.isNewerThanSupported, let format = parsed.parsed.declaredFormat {
                throw .newerCopy(url, format)
            }
            (copyFile, copy) = (url, received)
            review = try finder.review(of: received, at: url)
        } else if let bound = ReviewFormat.boundCopy(in: data) {
            guard let found = finder.copy(exported: bound, reviewedBy: url) else {
                throw .copyNotFound(review: url)
            }
            (copyFile, copy) = found
            review = .existing(url, data)
        } else {
            throw .notAReviewCopy(url)
        }
        let loaded = try load(
            review, copyFile: copyFile, copy: copy, reviews: reviews, freshID: freshID, fileSystem, opener)
        if case .new(let other) = review { return loaded.telling(other) }
        return loaded
    }

    /// The review `open` found: its file and bytes, or a new one, which notes the review of
    /// another copy that has its name (review format §4.3).
    enum Found {
        case existing(URL, Data)
        case new(otherReview: URL?)
    }

    private static func load(
        _ found: Found, copyFile: URL, copy: ReceivedCopy, reviews: ReviewsFolder, freshID: () -> ReviewID,
        _ fileSystem: any FileSystem, _ opener: Opener
    ) throws(ReviewOpenError) -> LoadedReview {
        switch found {
        case .new:
            let id = freshID()
            let context = ReviewContext(
                copyFile: copyFile, copy: copy, id: id, reviews: reviews, reviewedCopy: copy.export, notes: []
            )
            let access: LoadedReview.Access
            switch lockNewReview(of: copy.export, reviews, fileSystem, opener) {
            case .held(let lock):
                access = .editing(
                    ReviewFile(
                        context, state: .unwritten(copyLock: lock), fileSystem: fileSystem, opener: opener))
            case .readOnly(let reason):
                access = .readOnly(reason)
            }
            Log.store.info(
                "opened a review copy for a new review", ["scenes": .count(copy.book.scenes.count)])
            return LoadedReview(context: context, book: copy.book, access: access, otherReview: nil)
        case .existing(let file, let data):
            let read = ReadReview(file: file, data: data, copy: copy, reviews: reviews, freshID: freshID)
            let context = read.context(copyFile: copyFile)
            if let reason = read.readOnlyReason {
                return read.loaded(context, .readOnly(reason))
            }
            var lock: HeldLock?
            switch lockReview(read.review.id, reviews, fileSystem, opener) {
            case .held(let held): lock = held
            case .readOnly(let reason): return read.loaded(context, .readOnly(reason))
            }
            guard let held = lock, (try? fileSystem.read(file)) == data else {
                Log.store.info("a review file changed while it was being locked; reading it again")
                // Released first: the review is opened again as if for the first time.
                lock = nil
                let again: Data
                do {
                    again = try readFile(file, fileSystem)
                } catch {
                    throw .reviewUnreadable(error)
                }
                return try load(
                    .existing(file, again), copyFile: copyFile, copy: copy, reviews: reviews,
                    freshID: freshID,
                    fileSystem, opener)
            }
            let reviewFile = ReviewFile(
                context, state: .written(Written(file: file, lastSeen: ContentDigest(data), lock: held)),
                fileSystem: fileSystem, opener: opener)
            Log.store.info("opened a review", ["bytes": .bytes(Int64(data.count))])
            return read.loaded(context, .editing(reviewFile))
        }
    }

    /// A review file's bytes, read against its copy.
    private struct ReadReview {
        let file: URL
        let data: Data
        let parsed: ParsedReview
        let reviews: ReviewsFolder
        let copy: ReceivedCopy

        init(file: URL, data: Data, copy: ReceivedCopy, reviews: ReviewsFolder, freshID: () -> ReviewID) {
            self.file = file
            self.data = data
            self.copy = copy
            self.reviews = reviews
            parsed = ReviewFormat.parse(data, against: copy, freshID: freshID)
        }

        var review: Review { parsed.review }

        func context(copyFile: URL) -> ReviewContext {
            ReviewContext(
                copyFile: copyFile, copy: copy, id: review.id, reviews: reviews, reviewedCopy: review.copy,
                notes: review.notes)
        }

        /// A newer format can't be made editable, so it wins over a repair.
        var readOnlyReason: ReadOnlyReason? {
            if parsed.isNewerThanSupported, let format = parsed.declaredFormat {
                return .newerReviewFormat(format)
            }
            guard parsed.wasRepaired else { return nil }
            return .repairedOnOpen(
                .review(
                    ReviewRepair(
                        file: ReviewPlace(file: file, id: review.id, reviews: reviews), book: review.book,
                        newEntries: parsed.newEntries, original: data)))
        }

        func loaded(_ context: ReviewContext, _ access: LoadedReview.Access) -> LoadedReview {
            if case .readOnly(let reason) = access {
                Log.store.info("opened a review read-only", ["reason": .symbol(reason.logSymbol)])
            }
            return LoadedReview(context: context, book: review.book, access: access, otherReview: nil)
        }
    }

    /// The review's own lock. Application Support is on this Mac, so a lock record never blocks
    /// it and there's nothing to open anyway.
    private static func lockReview(
        _ id: ReviewID, _ reviews: ReviewsFolder, _ fileSystem: any FileSystem, _ opener: Opener
    ) -> HeldLock.Attempt {
        do {
            try reviews.makeFolder(for: id, fileSystem)
        } catch {
            return .readOnly(.lockUnavailable(error))
        }
        return HeldLock.take(reviews.lock(for: id), fileSystem, .respect, opener)
    }

    private static func lockNewReview(
        of export: ExportID, _ reviews: ReviewsFolder, _ fileSystem: any FileSystem, _ opener: Opener
    ) -> HeldLock.Attempt {
        do {
            try reviews.makeCopiesFolder(fileSystem)
        } catch {
            return .readOnly(.lockUnavailable(error))
        }
        return HeldLock.take(reviews.lock(forNewReviewOf: export), fileSystem, .respect, opener)
    }

    static func readFile(_ url: URL, _ fileSystem: any FileSystem) throws(FileSystemError) -> Data {
        guard case .file? = try fileSystem.item(at: url) else { throw FileSystemError(.read, url, .notFound) }
        return try fileSystem.read(url)
    }

    // MARK: Make Editable (ADR 0024)

    /// Make Editable's first step for a review: keeps the bytes it was read from in its folder.
    public static func keepOriginal(
        of repair: ReviewRepair, now: Date = .now, fileSystem: any FileSystem = LocalFileSystem()
    ) throws(FileSystemError) -> KeptReviewOriginal {
        try repair.file.reviews.makeFolder(for: repair.file.id, fileSystem)
        let kept = try GuardedWrite.keepOriginal(
            repair.original, of: repair.file.saved, now: now, fileSystem: fileSystem)
        Log.store.info(
            "kept the original of a review repaired as it opened",
            ["bytes": .bytes(Int64(repair.original.count))])
        return KeptReviewOriginal(url: kept, repair: repair)
    }

    /// What `edit` did with a kept original.
    public enum MadeEditable: ~Copyable, Sendable {
        case editing(ReviewFile)
        /// The lock couldn't be had; the kept original comes back for another try.
        case readOnly(KeptReviewOriginal, ReadOnlyReason)
    }

    /// Make Editable's second step: locks the review for editing. The file isn't read again: the
    /// review is the one shown read-only, and the kept original is what it last read, so a save
    /// finds any change since and stops (ADR 0018).
    public static func edit(
        _ kept: consuming KeptReviewOriginal, _ context: ReviewContext,
        fileSystem: any FileSystem = LocalFileSystem()
    ) -> MadeEditable {
        let repair = kept.repair
        switch lockReview(repair.file.id, repair.file.reviews, fileSystem, .current) {
        case .held(let lock):
            Log.store.info("made a repaired review editable")
            let written = Written(
                file: repair.file.file, lastSeen: ContentDigest(repair.original), lock: lock)
            return .editing(
                ReviewFile(context, state: .written(written), fileSystem: fileSystem, opener: .current))
        case .readOnly(let reason):
            return .readOnly(kept, reason)
        }
    }

    // MARK: Saving (review format §3.9)

    /// Writes `review` unless the review file already holds exactly it, or there's no review
    /// file yet and the review holds nothing (review format §4.1). The first save that has
    /// something to keep creates the file under the first free name of `<copy>.review.md`,
    /// `<copy>-2.review.md`, …, never replacing anything. The copy is never written.
    public func save(_ review: Review, onExternalChange policy: ExternalChangePolicy = .refuse)
        throws(SaveError) -> WriteResult
    {
        let data: Data
        do {
            data = try ReviewFormat.verifiedSerialization(of: review, against: copy)
        } catch {
            Log.store.fault(
                "the serialized review failed verification", ["error": .error(LoggedError(error))])
            throw .encoding(error)
        }
        return try state.withLock { (state) throws(SaveError) -> WriteResult in
            switch state {
            case .unwritten:
                guard !review.isEmpty else { return .unchanged }
                // The review's own lock is taken before its file exists, so whoever finds the
                // file finds it locked; the copy's lock goes once it's no longer needed.
                let lock: HeldLock
                switch Self.lockReview(id, reviews, fileSystem, opener) {
                case .held(let held): lock = held
                case .readOnly(let reason): throw .fileSystem(Self.lockFailure(reason, reviews.lock(for: id)))
                }
                let file = try create(data)
                state = .written(Written(file: file, lastSeen: ContentDigest(data), lock: lock))
                Log.store.info("created a review file", ["bytes": .bytes(Int64(data.count))])
                return .saved(Self.backups(.intact))
            case .written(var written):
                defer { state = .written(written) }
                let write = GuardedWrite(layout: reviews.saved(written.file, id: id), fileSystem: fileSystem)
                let outcome: GuardedWriteOutcome
                do throws(SaveError) {
                    outcome = try write.save(data, policy, &written.lastSeen)
                } catch {
                    guard case .externallyModified(.changed(let theirs)) = error else { throw error }
                    throw .externallyModified(keep(theirs, beside: &written))
                }
                switch outcome {
                case .unchanged:
                    return .unchanged
                case .written(let status):
                    Log.store.info("saved the review", ["bytes": .bytes(Int64(data.count))])
                    return .saved(Self.backups(status))
                }
            }
        }
    }

    private static func lockFailure(_ reason: ReadOnlyReason, _ lock: URL) -> FileSystemError {
        if case .lockUnavailable(let error) = reason { return error }
        return FileSystemError(.lock, lock, .alreadyExists)
    }

    /// Another program's version `theirs`, kept beside the review file under a name nothing
    /// rotates or replaces, `<name>.review.conflict-<UTC time>.md`, before any save may replace
    /// it (ADR 0042). Kept once per version; if it can't be kept, the change is reported as it was.
    private func keep(_ theirs: ContentDigest, beside written: inout Written) -> ExternalChange {
        if let name = written.kept[theirs] { return .changedAndKept(theirs: theirs, keptAs: name) }
        guard let data = try? fileSystem.read(written.file), ContentDigest(data) == theirs else {
            return .changed(theirs: theirs)
        }
        let now = Date.now
        let file = written.file
        let name = { (attempt: Int) in Self.conflict(of: file, at: now, attempt: attempt) }
        do {
            let temporary = try fileSystem.writeTemporary(data, for: name(1), permissionsFrom: written.file)
            guard let kept = try fileSystem.publishUnderFreeName(temporary, name) else {
                fileSystem.discard(temporary.url)
                return .changed(theirs: theirs)
            }
            written.kept[theirs] = kept.lastPathComponent
            Log.store.info("kept another program's version of a review beside it")
            return .changedAndKept(theirs: theirs, keptAs: kept.lastPathComponent)
        } catch {
            Log.store.error("couldn't keep another program's version of a review", error.logMetadata)
            return .changed(theirs: theirs)
        }
    }

    /// `X.review.conflict-<UTC time>.md` beside `X.review.md`, then `-2`, `-3`, … before `.md`.
    static func conflict(of file: URL, at date: Date, attempt: Int) -> URL {
        let base = file.deletingPathExtension().lastPathComponent
        return file.deletingLastPathComponent().appending(
            path: "\(base).conflict-\(SavedFileLayout.stamp(date, attempt)).md", directoryHint: .notDirectory)
    }

    /// A review has no tiered snapshots: only the rotation (ADR 0042).
    private static func backups(_ rotation: BackupStatus) -> SavedBackups {
        SavedBackups(rotation: rotation, snapshots: SnapshotReport(package: .notDue, mirror: .notDue))
    }

    private func create(_ data: Data) throws(SaveError) -> URL {
        let names = ReviewFinder.names(for: copyFile)
        let temporary = try wrapping(SaveError.fileSystem) { () throws(FileSystemError) in
            try fileSystem.writeTemporary(data, for: names(1), permissionsFrom: names(1))
        }
        let published: URL?
        do {
            published = try fileSystem.publishUnderFreeName(temporary, names)
        } catch {
            fileSystem.discard(temporary.url)
            throw .fileSystem(error)
        }
        guard let published else {
            fileSystem.discard(temporary.url)
            throw .fileSystem(FileSystemError(.publish, names(freeNameAttempts), .alreadyExists))
        }
        return published
    }
}

extension LoadedReview {
    fileprivate func telling(_ other: URL?) -> LoadedReview {
        LoadedReview(context: context, book: book, access: access, otherReview: other)
    }
}

/// How a review finds its copy and a copy its review (review format §4): by the export id, the
/// file names being only a convention.
struct ReviewFinder {
    let folder: URL
    let fileSystem: any FileSystem
    let opened: Timestamp

    static let suffix = ".review.md"

    /// `<copy>.review.md`, then `<copy>-2.review.md`, `<copy>-3.review.md`, … beside the copy.
    static func names(for copy: URL) -> (Int) -> URL {
        let base = copy.deletingPathExtension().lastPathComponent
        let folder = copy.deletingLastPathComponent()
        return { attempt in
            folder.appending(
                path: base + (attempt > 1 ? "-\(attempt)" : "") + suffix, directoryHint: .notDirectory)
        }
    }

    static func isReviewFile(_ name: String) -> Bool {
        name.lowercased().hasSuffix(suffix)
    }

    /// Review format §4.1.
    func review(of copy: ReceivedCopy, at copyFile: URL) throws(ReviewOpenError) -> ReviewFile.Found {
        let named = Self.names(for: copyFile)(1)
        let candidates = files().filter { Self.isReviewFile($0.lastPathComponent) }
        var matches: [(url: URL, data: Data, modified: Date)] = []
        var namedHasNoCopy = false
        var namedIsAReview = false
        for url in candidates {
            let isNamed = url.lastPathComponent == named.lastPathComponent
            let read: (FileMetadata, Data)
            do throws(FileSystemError) {
                guard case .file(let metadata, _)? = try fileSystem.item(at: url) else { continue }
                read = (metadata, try fileSystem.read(url))
            } catch {
                // The review named for this copy may be its review: never guess past it.
                if isNamed { throw .reviewUnreadable(error) }
                continue
            }
            let bound = ReviewFormat.boundCopy(in: read.1)
            // A copy saved under a review's name is a copy, not a review with its copy line lost.
            let isACopy = ReceivedCopy(ReviewCopyFormat.parse(read.1, opened: opened)) != nil
            if isNamed, !isACopy {
                namedIsAReview = true
                namedHasNoCopy = bound == nil
            }
            if bound == copy.export { matches.append((url, read.1, read.0.modified)) }
        }
        if let preferred = matches.first(where: { $0.url.lastPathComponent == named.lastPathComponent })
            ?? matches.max(by: { $0.modified < $1.modified })
        {
            return .existing(preferred.url, preferred.data)
        }
        if namedHasNoCopy {
            do {
                return .existing(named, try ReviewFile.readFile(named, fileSystem))
            } catch {
                throw .reviewUnreadable(error)
            }
        }
        return .new(otherReview: namedIsAReview ? named : nil)
    }

    /// Review format §4.4: the copy beside a review file whose export id is the review's `copy`,
    /// preferring the one named like the review.
    func copy(exported export: ExportID, reviewedBy review: URL) -> (URL, ReceivedCopy)? {
        let name = review.lastPathComponent
        let preferred = String(name.dropLast(Self.suffix.count)) + ".md"
        let copies = files().filter {
            $0.pathExtension.lowercased() == "md" && !Self.isReviewFile($0.lastPathComponent)
        }
        .sorted {
            ($0.lastPathComponent == preferred ? 0 : 1, $0.lastPathComponent) < (
                $1.lastPathComponent == preferred ? 0 : 1, $1.lastPathComponent
            )
        }
        for url in copies {
            guard let data = try? ReviewFile.readFile(url, fileSystem),
                let copy = ReceivedCopy(ReviewCopyFormat.parse(data, opened: opened)), copy.export == export
            else { continue }
            return (url, copy)
        }
        return nil
    }

    /// The regular files in the folder, sorted by name.
    private func files() -> [URL] {
        let entries = (try? fileSystem.contents(of: folder)) ?? []
        return entries.filter { $0.kind == .file }.map(\.name).sorted()
            .map { folder.appending(path: $0, directoryHint: .notDirectory) }
    }
}
