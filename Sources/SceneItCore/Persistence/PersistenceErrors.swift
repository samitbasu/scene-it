import Foundation

/// Why a book couldn't be turned into bytes that are safe to write.
public enum EncodingFailure: Error, Hashable, Sendable, CustomStringConvertible {
    /// `BookCoding.encode` refused the book (it's invalid) or the encoder failed.
    case rejected(BookEncodingError)
    /// The encoded bytes don't decode.
    case undecodable(BookDecodingError)
    /// The encoded bytes decode, but the result won't encode.
    case reencodingRejected(BookEncodingError)
    /// Decoding and re-encoding the bytes produced different bytes.
    case unstable

    public var description: String {
        switch self {
        case .rejected(let error): error.description
        case .undecodable(let error): "the encoded book doesn't decode: \(error)"
        case .reencodingRejected(let error): "the encoded book decodes, but doesn't re-encode: \(error)"
        case .unstable: "the encoded book changes when it's decoded and encoded again"
        }
    }
}

public enum SaveError: Error, Hashable, Sendable, CustomStringConvertible {
    case encoding(EncodingFailure)
    /// `book.json` doesn't hold what this package last read or wrote, and the save's
    /// `ExternalChangePolicy` (or the kind of change) doesn't allow replacing it.
    case externallyModified(ExternalChange)
    case writeProtected(WriteProtection)
    /// Under `.overwriteKeepingTheirsAsBackup`, the other program's version couldn't be put
    /// into `bak1`, so nothing was saved (ADR 0019).
    case couldNotBackUpTheirVersion(FileSystemError)
    case fileSystem(FileSystemError)

    public var description: String {
        switch self {
        case .encoding(let failure): "couldn't save: \(failure)"
        case .externallyModified(let change): "couldn't save: \(change)"
        case .writeProtected(.readOnly): "couldn't save: book.json is read-only"
        case .writeProtected(.locked): "couldn't save: book.json is locked"
        case .couldNotBackUpTheirVersion(let error):
            "couldn't save: the version another program wrote couldn't be backed up (\(error))"
        case .fileSystem(let error): "couldn't save: \(error)"
        }
    }
}

public enum ExternalChange: Hashable, Sendable, CustomStringConvertible {
    /// Another program wrote different contents. If that happened while this save was
    /// replacing `book.json`, its version was put back.
    case changed
    case removed
    /// A directory, link or other non-file now stands where `book.json` was. Never overwritten.
    case notAFile
    /// Another program wrote `book.json` while this save was replacing it, and its version
    /// couldn't be put back, so it was kept in the package under this file name. `book.json`
    /// holds the book this save wrote.
    case keptAsConflict(fileName: String)

    public var description: String {
        switch self {
        case .changed: "book.json was changed by another program"
        case .removed: "book.json was removed by another program"
        case .notAFile: "book.json was replaced by something that isn't a file"
        case .keptAsConflict(let fileName):
            "book.json was changed by another program during the save; its version is in \(fileName)"
        }
    }
}

/// What a save does when `book.json` has changed since this package last read or wrote it.
public enum ExternalChangePolicy: Hashable, Sendable {
    /// Throw `SaveError.externallyModified` and write nothing.
    case refuse
    /// Save anyway, but only after the other program's version is safely in `bak1` (or
    /// recreate `book.json` if it was removed).
    case overwriteKeepingTheirsAsBackup
}

public enum SaveOutcome: Hashable, Sendable {
    case saved(BackupStatus)
    /// `book.json` already held exactly this book, so nothing was written or rotated.
    case unchanged
}

public enum BackupStatus: Hashable, Sendable {
    /// `bak1` holds the version this save replaced, and older versions shifted down.
    case intact
    /// `book.json` was saved, but the version it replaced (this package's own previous save)
    /// couldn't be put into `bak1`; the error is the rotation step that failed (ADR 0019).
    case previousVersionNotBackedUp(FileSystemError, olderBackups: OlderBackups)
}

/// What a rotation that stopped partway did to the older backups. It never destroys
/// anything but the version in `bak3`.
public enum OlderBackups: Hashable, Sendable {
    case untouched
    /// `bak2` had already moved into `bak3`, so `bak3`'s version, if there was one, is gone,
    /// and nothing took its place in the rotation.
    case oldestRetired
}

public enum CreateError: Error, Hashable, Sendable, CustomStringConvertible {
    case missingPackageExtension(URL)
    case alreadyExists(URL)
    case encoding(EncodingFailure)
    case fileSystem(FileSystemError)

    public var description: String {
        switch self {
        case .missingPackageExtension(let url):
            "couldn't create \(url.lastPathComponent): a book's name must end in .\(PackageLayout.pathExtension)"
        case .alreadyExists(let url):
            "couldn't create \(url.lastPathComponent): something with that name already exists"
        case .encoding(let failure): "couldn't create the book: \(failure)"
        case .fileSystem(let error): "couldn't create the book: \(error)"
        }
    }
}

/// A book that couldn't be opened, with the rotated backups that a person could restore by hand.
public struct LoadError: Error, Hashable, Sendable, CustomStringConvertible {
    public let package: URL
    public let problem: LoadProblem
    /// Newest first; only those that exist.
    public let backups: [Backup]

    public var description: String {
        let name = package.lastPathComponent
        let backupList =
            backups.isEmpty
            ? "There are no backups (book.json.bak1…3) in the package."
            : "Backups in the package:\n"
                + backups.map { "- \($0.slot) (last modified \($0.modified.formatted(.iso8601)))" }
                .joined(separator: "\n")
        return "Couldn't open \(name): \(problem)\n\(backupList)"
    }
}

public struct Backup: Hashable, Sendable {
    public let slot: BackupSlot
    public let modified: Date
}

public enum LoadProblem: Error, Hashable, Sendable, CustomStringConvertible {
    var logSymbol: StaticString {
        switch self {
        case .missingPackageExtension: "missingPackageExtension"
        case .notFound: "notFound"
        case .notADirectory: "notADirectory"
        case .bookMissing: "bookMissing"
        case .bookNotAFile: "bookNotAFile"
        case .unreadable: "unreadable"
        case .undecodable: "undecodable"
        case .invalid: "invalid"
        }
    }

    case missingPackageExtension
    case notFound
    case notADirectory
    case bookMissing
    case bookNotAFile
    case unreadable(FileSystemError)
    case undecodable(BookDecodingError)
    case invalid([BookProblem])

    public var description: String {
        switch self {
        case .missingPackageExtension:
            "it isn't a Scene It book (its name doesn't end in .\(PackageLayout.pathExtension))"
        case .notFound: "it doesn't exist"
        case .notADirectory: "it isn't a folder, but a Scene It book is a package (a folder)"
        case .bookMissing: "the package has no book.json"
        case .bookNotAFile: "the package's book.json isn't a regular file (it may be a folder or a link)"
        case .unreadable(let error): "\(error)"
        case .undecodable(let error): "book.json isn't a valid book: \(error)"
        case .invalid(let problems):
            "book.json isn't a valid book:\n" + problems.map { "- \($0)" }.joined(separator: "\n")
        }
    }
}
