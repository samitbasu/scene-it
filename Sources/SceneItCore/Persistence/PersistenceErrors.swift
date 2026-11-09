import Foundation

public enum SaveError: Error, Hashable, Sendable, CustomStringConvertible {
    case encoding(VerificationFailure)
    /// `book.md` doesn't hold what this package last read or wrote, and the save's
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
        case .writeProtected(.readOnly): "couldn't save: \(PackageLayout.bookFileName) is read-only"
        case .writeProtected(.locked): "couldn't save: \(PackageLayout.bookFileName) is locked"
        case .couldNotBackUpTheirVersion(let error):
            "couldn't save: the version another program wrote couldn't be backed up (\(error))"
        case .fileSystem(let error): "couldn't save: \(error)"
        }
    }
}

public enum ExternalChange: Hashable, Sendable, CustomStringConvertible {
    /// Another program wrote different contents, the version `theirs`. If that happened while
    /// this save was replacing `book.md`, its version was put back.
    case changed(theirs: ContentDigest)
    /// As `changed`, and the version `theirs` was kept, under `keptAs` beside the file, before
    /// anything could replace it (a review's file, ADR 0042).
    case changedAndKept(theirs: ContentDigest, keptAs: String)
    case removed
    /// A directory, link or other non-file now stands where `book.md` was. Never overwritten.
    case notAFile
    /// Another program wrote `book.md` while this save was replacing it, and its version
    /// couldn't be put back, so it was kept in the package under this file name. `book.md`
    /// holds the book this save wrote. If that name is the hidden temporary file, a later save
    /// renames it to `book.md.recovered-<time>.md` (`StrayTemporaryFiles`).
    case keptAsConflict(fileName: String)

    public var description: String {
        switch self {
        case .changed: "\(PackageLayout.bookFileName) was changed by another program"
        case .changedAndKept(_, let name):
            "the file was changed by another program; its version is in \(name)"
        case .removed: "\(PackageLayout.bookFileName) was removed by another program"
        case .notAFile: "\(PackageLayout.bookFileName) was replaced by something that isn't a file"
        case .keptAsConflict(let fileName):
            "\(PackageLayout.bookFileName) was changed by another program during the save; its version is in \(fileName)"
        }
    }
}

/// What a save does when `book.md` has changed since this package last read or wrote it.
/// Each approval names the change the writer saw, so it can't overwrite a later one.
public enum ExternalChangePolicy: Hashable, Sendable {
    /// Throw `SaveError.externallyModified` and write nothing.
    case refuse
    /// Replace the version `theirs`, but only after it's safely in `bak1`. Any other version
    /// is refused with `.changed` naming it.
    case overwriteKeepingTheirsAsBackup(theirs: ContentDigest)
    /// Recreate a `book.md` another program removed.
    case recreate
}

public enum SaveOutcome: Hashable, Sendable {
    /// `book.md` now holds the `PublishedBook`, which `BackupKeeper.keep` snapshots.
    case saved(BackupStatus, PublishedBook)
    /// `book.md` already held exactly this book, so nothing was written or rotated.
    case unchanged
}

public enum BackupStatus: Hashable, Sendable {
    /// `bak1` holds the version this save replaced, and older versions shifted down.
    case intact
    /// `book.md` was saved, but the version it replaced (this package's own previous save)
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
    case encoding(VerificationFailure)
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

extension CreateError {
    /// A book's save into a package just created, which failed.
    init(_ error: SaveError, at url: URL) {
        switch error {
        case .encoding(let failure): self = .encoding(failure)
        case .fileSystem(let error), .couldNotBackUpTheirVersion(let error): self = .fileSystem(error)
        case .externallyModified, .writeProtected:
            self = .fileSystem(FileSystemError(.write, PackageLayout(root: url).book, .io))
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
            ? "There are no backups (\(BackupSlot.bak1)…3) in the package."
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
        case .legacyJSONBook: "legacyJSONBook"
        case .unreadable: "unreadable"
        }
    }

    case missingPackageExtension
    case notFound
    case notADirectory
    case bookMissing
    case bookNotAFile
    /// There's no `book.md`, only the JSON book of a build before format 2. There's no
    /// conversion (ADR 0022), and it's never read as an empty book.
    case legacyJSONBook
    case unreadable(FileSystemError)

    public var description: String {
        switch self {
        case .missingPackageExtension:
            "it isn't a Scene It book (its name doesn't end in .\(PackageLayout.pathExtension))"
        case .notFound: "it doesn't exist"
        case .notADirectory: "it isn't a folder, but a Scene It book is a package (a folder)"
        case .bookMissing: "the package has no \(PackageLayout.bookFileName)"
        case .bookNotAFile:
            "the package's \(PackageLayout.bookFileName) isn't a regular file (it may be a folder or a link)"
        case .legacyJSONBook:
            "it was saved by a test version of Scene It, in a format this version can't read "
                + "(\(PackageLayout.legacyBookFileName) instead of \(PackageLayout.bookFileName))"
        case .unreadable(let error): "\(error)"
        }
    }
}
