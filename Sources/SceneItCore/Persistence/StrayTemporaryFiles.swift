import Foundation

/// Clears away the hidden temporary files that an interrupted write leaves in one folder: a
/// save's in the package's root, and `BackupKeeper`'s in `Backups/` and the book's mirror
/// folder.
///
/// Only regular files named exactly as `FileSystem.writeTemporary` names a temporary file for
/// one of the folder's destinations (`.book.md.<UUID>.tmp`, `.book-<stamp>.md.<UUID>.tmp`,
/// `.book-id.<UUID>.tmp`, …) are touched, and only once they're `minimumAge` old, so a write
/// still in progress is left alone. What happens next depends on what the destination holds
/// (`Contents`):
///
/// - A version of `book.md` holding the same bytes as a kept version is removed. Any other
///   holds a version found nowhere else, such as another program's version that a save
///   couldn't put back (ADR 0019), so it's renamed to `PackageLayout.recovered(in:modified:attempt:)`
///   in the same folder, never removed.
/// - Metadata is removed once the file it would have become is in place and valid: a
///   temporary `book-id` or `package.json` was never published, so nothing refers to it.
///
/// A file is removed only if it's still the one that was read: it's first renamed to a fresh
/// temporary name, and removed only if the file there has the inode, size and modification time
/// it had when it was read. Anything else found there is recovered instead.
///
/// Nothing here throws: a failure is logged and leaves the file in place.
struct StrayTemporaryFiles {
    static let minimumAge = Interval.minutes(10)

    private enum Contents {
        case bookVersion
        /// Superseded by `current` while that's a regular file whose bytes `isValid` accepts.
        case metadata(current: URL, isValid: (Data) -> Bool)
    }

    private let folder: URL
    private let fileSystem: any FileSystem
    private let log: Log
    /// What a temporary file for each destination holds; `nil` for a destination that's never
    /// written in `folder`.
    private let contents: (Substring) -> Contents?
    /// The versions a stray `bookVersion` is compared with: these files and every snapshot in
    /// `keptSnapshots`.
    private let keptFiles: [URL]
    private let keptSnapshots: URL

    /// A save's temporary `book.md` and `bak1`, and Make Editable's temporary original
    /// (ADR 0024), compared with the book, its backups and the snapshots in `Backups/`. An
    /// original that never got its name holds the bytes `book.md` held when it was written,
    /// so it's usually removed as a copy of `book.md`; if not, it's recovered like any other.
    init(packageRoot layout: PackageLayout, fileSystem: any FileSystem) {
        let destinations = [layout.book, layout.backup(.bak1)].map(\.lastPathComponent)
        self.init(
            folder: layout.root, fileSystem: fileSystem, log: .store,
            contents: { destination in
                destinations.contains { destination.isExactly($0) } || PackageLayout.isOriginal(destination)
                    ? .bookVersion : nil
            },
            keptFiles: Self.packageVersions(layout), keptSnapshots: layout.snapshots)
    }

    /// `Archive/`'s own: an interrupted filing's temporary `saveNNNN.md`, compared with the
    /// filed copies, the book, its backups and the snapshots, and an interrupted index write's
    /// temporary `index.md`, removed once `index.md` is valid. A filed copy is never a
    /// candidate: only hidden temporary names are.
    init(archiveOf layout: PackageLayout, fileSystem: any FileSystem) {
        let listing = (try? fileSystem.contents(of: layout.archive)) ?? []
        let filed = ArchiveReconciliation.filedCopies(in: listing).map(layout.filedCopy)
        let index = layout.archiveIndex
        self.init(
            folder: layout.archive, fileSystem: fileSystem, log: .store,
            contents: { destination in
                if let number = FiledCopyNumber(fileName: destination), destination.isExactly(number.fileName)
                {
                    return .bookVersion
                }
                guard destination.isExactly(index.lastPathComponent) else { return nil }
                return .metadata(current: index, isValid: Self.isCleanIndex)
            },
            keptFiles: Self.packageVersions(layout) + filed, keptSnapshots: layout.snapshots)
    }

    private static func isCleanIndex(_ bytes: Data) -> Bool {
        let parsed = ArchiveIndexFormat.parse(bytes, filed: { _ in CalendarDay(.now, in: .gmt) })
        return parsed.newEntries.isEmpty && !parsed.isNewerThanSupported
    }

    /// A folder of snapshots and one metadata file in it (`Backups/` with `book-id`, a mirror
    /// folder with `package.json`): `BackupKeeper`'s temporary snapshots, compared with the
    /// folder's snapshots and `alsoKept`, and its temporary `metadata`.
    init(
        snapshotsIn folder: URL, metadata: URL, isValid: @escaping (Data) -> Bool, alsoKept: [URL],
        fileSystem: any FileSystem
    ) {
        let metadataName = metadata.lastPathComponent
        self.init(
            folder: folder, fileSystem: fileSystem, log: .backup,
            contents: { destination in
                if Self.isSnapshot(destination) { return .bookVersion }
                if destination.isExactly(metadataName) {
                    return .metadata(current: metadata, isValid: isValid)
                }
                return nil
            },
            keptFiles: alsoKept, keptSnapshots: folder)
    }

    private init(
        folder: URL, fileSystem: any FileSystem, log: Log, contents: @escaping (Substring) -> Contents?,
        keptFiles: [URL], keptSnapshots: URL
    ) {
        self.folder = folder
        self.fileSystem = fileSystem
        self.log = log
        self.contents = contents
        self.keptFiles = keptFiles
        self.keptSnapshots = keptSnapshots
    }

    /// `book.md` and its rotated backups.
    static func packageVersions(_ layout: PackageLayout) -> [URL] {
        [layout.book] + BackupSlot.allCases.map(layout.backup)
    }

    private static func isSnapshot(_ destination: Substring) -> Bool {
        SnapshotName(fileName: String(destination)).map { destination.isExactly($0.fileName) } ?? false
    }

    func sweep(now: Date) {
        let strays: [Stray]
        do {
            strays = try candidates()
        } catch {
            log.error("couldn't look for stray temporary files", error.logMetadata)
            return
        }
        guard !strays.isEmpty else { return }
        var kept = KeptVersions(files: keptFiles, snapshotsIn: keptSnapshots, fileSystem)
        var tally: [Disposal: Int] = [:]
        for stray in strays {
            tally[dispose(of: stray, modifiedBy: now - Self.minimumAge, &kept), default: 0] += 1
        }
        let (removed, recovered, left) = (tally[.removed] ?? 0, tally[.recovered] ?? 0, tally[.left] ?? 0)
        guard removed + recovered + left > 0 else { return }
        log.info(
            "cleared stray temporary files",
            ["removed": .count(removed), "recovered": .count(recovered), "left": .count(left)])
    }

    private struct Stray {
        let url: URL
        let destination: Substring
        let contents: Contents
    }

    private enum Disposal {
        case removed, recovered, left
        /// Too young, or not a regular file once opened.
        case skipped
    }

    private func candidates() throws(FileSystemError) -> [Stray] {
        try fileSystem.contents(of: folder).compactMap { entry in
            guard entry.kind == .file,
                let destination = TemporaryFile.destination(ofName: entry.name),
                let contents = contents(destination)
            else { return nil }
            return Stray(
                url: folder.appending(path: entry.name, directoryHint: .notDirectory),
                destination: destination, contents: contents)
        }
    }

    private func dispose(of stray: Stray, modifiedBy cutoff: Date, _ kept: inout KeptVersions) -> Disposal {
        let file: OpenFile
        do {
            file = try fileSystem.open(stray.url)
        } catch {
            log.error("couldn't open a stray temporary file; left it in place", error.logMetadata)
            return .left
        }
        guard case .file(let metadata, _) = file.item, metadata.modified <= cutoff else { return .skipped }
        switch stray.contents {
        case .metadata(let current, let isValid):
            guard holdsValid(current, isValid) else {
                log.info("left a stray temporary file in place until the file it would replace is valid")
                return .left
            }
            return remove(stray, ifStill: metadata)
        case .bookVersion:
            guard kept.hasSize(metadata.size) else { return recover(stray.url, modified: metadata.modified) }
            let contents: Data
            do {
                contents = try file.read()
            } catch {
                log.error("couldn't read a stray temporary file; left it in place", error.logMetadata)
                return .left
            }
            guard kept.holds(contents) else { return recover(stray.url, modified: metadata.modified) }
            return remove(stray, ifStill: metadata)
        }
    }

    private func holdsValid(_ current: URL, _ isValid: (Data) -> Bool) -> Bool {
        guard let file = try? fileSystem.open(current), case .file = file.item,
            let data = try? file.read()
        else { return false }
        return isValid(data)
    }

    private func remove(_ stray: Stray, ifStill read: FileMetadata) -> Disposal {
        let aside = folder.appending(
            path: TemporaryFile.name(for: String(stray.destination), id: UUID()), directoryHint: .notDirectory
        )
        do {
            try fileSystem.publish(TemporaryFile(url: stray.url), as: aside)
        } catch {
            log.error("couldn't move a stray temporary file aside; left it in place", error.logMetadata)
            return .left
        }
        let found = try? fileSystem.item(at: aside)
        guard case .file(let metadata, _)? = found, metadata == read else {
            log.error("a stray temporary file changed while it was being cleared; recovering it")
            let modified = if case .file(let metadata, _)? = found { metadata.modified } else { Date.now }
            return recover(aside, modified: modified)
        }
        do {
            try fileSystem.remove(aside)
            return .removed
        } catch {
            log.error("couldn't remove a stray temporary file", error.logMetadata)
            return .left
        }
    }

    private func recover(_ url: URL, modified: Date) -> Disposal {
        do {
            guard
                try fileSystem.publishUnderFreeName(
                    TemporaryFile(url: url),
                    { PackageLayout.recovered(in: folder, modified: modified, attempt: $0) }) != nil
            else {
                log.error("every recovery name for a stray temporary file was taken; left it in place")
                return .left
            }
        } catch {
            log.error("couldn't rename a stray temporary file; left it in place", error.logMetadata)
            return .left
        }
        log.error("a stray temporary file held a version kept nowhere else; renamed it")
        return .recovered
    }
}

extension Substring {
    /// Equal scalar by scalar, unlike `==`, which treats canonically equivalent strings as equal.
    func isExactly(_ name: String) -> Bool {
        utf8.elementsEqual(name.utf8)
    }
}

/// The versions kept around a folder: some files and the snapshots in one folder. Each is
/// read at most once per sweep. Anything that can't be inspected or read is left out, so it
/// can only make a stray look unique.
private struct KeptVersions {
    private struct Copy {
        let url: URL
        let size: Int64
    }

    private let fileSystem: any FileSystem
    private let copies: [Copy]
    private var digests: [URL: ContentDigest?] = [:]

    init(files: [URL], snapshotsIn folder: URL, _ fileSystem: any FileSystem) {
        self.fileSystem = fileSystem
        let snapshots =
            ((try? fileSystem.contents(of: folder)) ?? [])
            .filter { $0.kind == .file && SnapshotName(fileName: $0.name) != nil }
            .map { folder.appending(path: $0.name, directoryHint: .notDirectory) }
        copies = (files + snapshots).compactMap { url in
            guard case .file(let metadata, _)? = try? fileSystem.item(at: url) else { return nil }
            return Copy(url: url, size: metadata.size)
        }
    }

    func hasSize(_ size: Int64) -> Bool {
        copies.contains { $0.size == size }
    }

    mutating func holds(_ contents: Data) -> Bool {
        let digest = ContentDigest(contents)
        for copy in copies where copy.size == contents.count {
            if self.digest(of: copy.url) == digest { return true }
        }
        return false
    }

    private mutating func digest(of url: URL) -> ContentDigest? {
        if let cached = digests[url] { return cached }
        let digest = (try? fileSystem.read(url)).map(ContentDigest.init)
        digests[url] = digest
        return digest
    }
}
