import Foundation
import Synchronization

/// A review's file, with its lock (ADR 0042): as `BookWriter`, its mutex serializes the
/// review's saves and release, and everything it does runs off the main actor.
final class ReviewWriter: Sendable {
    private let file: Mutex<ReviewFile?>

    init(_ file: ReviewFile) {
        self.file = Mutex(file)
    }

    @concurrent
    func save(_ review: Review, onExternalChange policy: ExternalChangePolicy) async throws(SaveError)
        -> WriteResult
    {
        try file.withLock { (file) throws(SaveError) -> WriteResult in
            guard let file else { throw .fileSystem(FileSystemError(.write, URL(filePath: "/"), .notFound)) }
            return try file.save(review, onExternalChange: policy)
        }
    }

    /// Waits for a running save, then drops the file, which releases the review's lock.
    @concurrent
    func release() async {
        let released = file.withLock { file in
            defer { file = nil }
            return file
        }
        _ = consume released
    }

    /// For termination, where nothing may wait: if a save is still running, the lock is left
    /// to the kernel, which drops it when the process exits.
    func releaseUnlessSaving() {
        let released = file.withLockIfAvailable { file in
            defer { file = nil }
            return file
        }
        _ = consume released
    }
}

/// What saves the open book: a book's package, or a review's file (ADR 0042).
enum DocumentWriter: Sendable {
    case book(BookWriter)
    case review(ReviewWriter)

    /// Saves `book`, which for a review is the review of `document`'s copy.
    @concurrent
    func save(_ book: Book, of document: OpenDocument, onExternalChange policy: ExternalChangePolicy)
        async throws(SaveError) -> WriteResult
    {
        switch (self, document) {
        case (.book(let writer), _):
            return try await writer.save(book, onExternalChange: policy)
        case (.review(let writer), .review(let context)):
            return try await writer.save(context.review(of: book), onExternalChange: policy)
        case (.review, .book):
            preconditionFailure("a review's writer saves only a review")
        }
    }

    @concurrent
    func release() async {
        switch self {
        case .book(let writer): await writer.release()
        case .review(let writer): await writer.release()
        }
    }

    func releaseUnlessSaving() {
        switch self {
        case .book(let writer): writer.releaseUnlessSaving()
        case .review(let writer): writer.releaseUnlessSaving()
        }
    }

    /// The book's writer, for what only a book has: its archive and filed copies.
    var book: BookWriter? {
        if case .book(let writer) = self { writer } else { nil }
    }
}
