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
    /// `book.json` isn't the file this package last read or wrote: something else changed,
    /// replaced or removed it.
    case externallyModified
    case fileSystem(FileSystemError)

    public var description: String {
        switch self {
        case .encoding(let failure): "couldn't save: \(failure)"
        case .externallyModified: "couldn't save: book.json was changed by something other than Scene It"
        case .fileSystem(let error): "couldn't save: \(error)"
        }
    }
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
        case .notADirectory: "it's a file, but a Scene It book is a package (a folder)"
        case .bookMissing: "the package has no book.json"
        case .bookNotAFile: "the package's book.json isn't a regular file"
        case .unreadable(let error): "\(error)"
        case .undecodable(let error): "book.json isn't a valid book: \(error)"
        case .invalid(let problems):
            "book.json isn't a valid book:\n" + problems.map { "- \($0)" }.joined(separator: "\n")
        }
    }
}
