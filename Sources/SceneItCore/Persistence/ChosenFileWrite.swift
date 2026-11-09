import Foundation

/// Writes a file where the writer chose in a save panel, as a save writes `book.md`: made durable
/// under a hidden name, read back, then renamed into place, so the destination holds either what
/// was there or all of the new bytes. It replaces nothing but a plain file the writer can write
/// (the save panel has already asked about replacing it).
enum ChosenFileWrite {
    static func write(_ bytes: Data, to destination: URL, fileSystem: any FileSystem)
        throws(ChosenFileFailure)
    {
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
        do throws(FileSystemError) {
            let temporary = try fileSystem.writeTemporary(
                bytes, for: destination, permissionsFrom: destination)
            defer { fileSystem.discard(temporary.url) }
            guard try fileSystem.read(temporary.url) == bytes else {
                throw FileSystemError(.write, destination, .io)
            }
            if existing == nil {
                try fileSystem.publish(temporary, as: destination)
            } else {
                try fileSystem.move(temporary.url, over: destination)
            }
        } catch {
            throw .fileSystem(error)
        }
    }
}

/// Why a file wasn't written where the writer chose. Nothing at the destination changed.
public enum ChosenFileFailure: Error, Hashable, Sendable {
    /// A folder, link or something else that isn't a file is at the destination.
    case notAFile
    case writeProtected(WriteProtection)
    /// Includes a file that didn't read back as it was written.
    case fileSystem(FileSystemError)
}
