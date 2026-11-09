import Foundation

/// Writes Save Review…'s page where the reviewer chose (review format §7), as the export writes a
/// review copy (`ChosenFileWrite`). It never writes a review's own files: a page is named `.html`,
/// which neither the copy nor anything of the review's is, and it refuses the copy itself under any
/// name, and the folder where Scene It keeps the review's backups and lock.
public enum ReviewPageWriter {
    public static func write(
        _ page: String, to destination: URL, for review: ReviewContext, fileSystem: any FileSystem
    ) throws(SaveReviewFailure) {
        guard ReviewOutputWording.pageExtensions.contains(destination.pathExtension.lowercased()) else {
            throw .notAPage
        }
        guard !ReviewCopyWriter.isInside(destination, review.reviews.root),
            !isCopy(destination, review, fileSystem)
        else { throw .reviewsOwnFile }
        do throws(ChosenFileFailure) {
            try ChosenFileWrite.write(Data(page.utf8), to: destination, fileSystem: fileSystem)
        } catch {
            throw .destination(error)
        }
    }

    private static func isCopy(_ destination: URL, _ review: ReviewContext, _ fileSystem: any FileSystem)
        -> Bool
    {
        if destination.canonicalPath.lowercased() == review.copyFile.canonicalPath.lowercased() {
            return true
        }
        guard let copy = try? fileSystem.mountedIdentity(of: review.copyFile),
            let there = try? fileSystem.mountedIdentity(of: destination)
        else { return false }
        return copy == there
    }
}

/// Why Save Review… wrote nothing. Nothing at the destination changed.
public enum SaveReviewFailure: Error, Hashable, Sendable {
    /// The destination isn't named as a web page (`.html`).
    case notAPage
    /// The destination is the review copy, or in the folder of the review's backups and lock.
    case reviewsOwnFile
    case destination(ChosenFileFailure)
}

/// What `BookStore.saveReview` did.
public enum SaveReviewResult: Hashable, Sendable {
    case saved
    case failed(SaveReviewFailure)
    /// The review was closed, or had nothing to put out, when the save's turn came; nothing was
    /// written.
    case unavailable
}
