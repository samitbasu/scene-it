import Foundation

/// Writes a review copy where the writer chose, as a save writes `book.md`: serialized,
/// verified by reading it back, then made durable under a hidden name and renamed into place,
/// so the destination holds either what was there or the whole copy. It never writes inside
/// the book's package, and never replaces anything but a plain file the writer can write.
///
/// The package is recognized by `identity`, read as the book opened, and by the identity at its
/// path now: the path is only as current as the last rename or move in Finder. A package that
/// can't be identified either way exports nothing.
public enum ReviewCopyWriter {
    public static func write(
        _ copy: ReviewCopy, to destination: URL, outside book: PackageLayout,
        identifiedAs identity: MountedIdentity?,
        fileSystem: any FileSystem
    ) throws(ExportFailure) {
        let package = Set([identity, try? fileSystem.mountedIdentity(of: book.root)].compactMap { $0 })
        guard !package.isEmpty else { throw .bookUnidentified }
        guard !isInside(destination, book.root), !reaches(package, from: destination, fileSystem) else {
            throw .insideTheBook
        }
        let bytes: Data
        do {
            bytes = try ReviewCopyFormat.verifiedSerialization(of: copy)
        } catch {
            throw .verification(error)
        }
        let existing: FileItem?
        do {
            existing = try fileSystem.item(at: destination)
        } catch {
            throw .fileSystem(error)
        }
        switch existing {
        case nil, .file(_, protection: nil): break
        case .file(_, protection: let protection?): throw .writeProtected(protection)
        case .directory, .symbolicLink, .other: throw .notAFile
        }
        do {
            let temporary = try fileSystem.writeTemporary(
                bytes, for: destination, permissionsFrom: destination)
            defer { fileSystem.discard(temporary.url) }
            if existing == nil {
                try fileSystem.publish(temporary, as: destination)
            } else {
                try fileSystem.move(temporary.url, over: destination)
            }
        } catch {
            throw .fileSystem(error)
        }
    }

    /// Whether `url` is `folder` or anything in it, however either is spelled. The destination
    /// needn't exist yet, so its folder is the one resolved. Case is ignored, as the usual
    /// volumes ignore it: on a case-sensitive one this refuses a little more than it must.
    static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let root = folder.canonicalPath.lowercased()
        let parent = url.deletingLastPathComponent().canonicalPath.lowercased()
        let path = (parent == "/" ? "" : parent) + "/" + url.lastPathComponent.lowercased()
        return path == root || path.hasPrefix(root + "/")
    }

    /// Whether `url`, or a folder above it that exists, has one of `package`'s identities, so a
    /// second name for the package that paths don't reveal (a firmlink, another spelling, a new
    /// name) is caught too. Links in the folders above are resolved first.
    static func reaches(_ package: Set<MountedIdentity>, from url: URL, _ fileSystem: any FileSystem) -> Bool
    {
        var current = url.deletingLastPathComponent().standardizedFileURL.resolvingSymlinksInPath()
        var candidates = [url]
        while current.path(percentEncoded: false) != "/" {
            candidates.append(current)
            current = current.deletingLastPathComponent()
        }
        return candidates.contains { candidate in
            (try? fileSystem.mountedIdentity(of: candidate)).map(package.contains) ?? false
        }
    }
}

/// Why a review copy wasn't written. Nothing at the destination changed.
public enum ExportFailure: Error, Hashable, Sendable {
    /// The destination is the open book's package, or inside it.
    case insideTheBook
    /// The open book's package couldn't be identified, as it opened or now, so a destination
    /// inside it couldn't be told apart.
    case bookUnidentified
    /// A folder, link or something else that isn't a file is at the destination.
    case notAFile
    case writeProtected(WriteProtection)
    case verification(VerificationFailure)
    case fileSystem(FileSystemError)
}

/// What `BookStore.exportReviewCopy` did.
public enum ExportResult: Hashable, Sendable {
    case exported
    case failed(ExportFailure)
    /// The book was closed, or read again, before the export's turn came; nothing was written.
    case unavailable
}
