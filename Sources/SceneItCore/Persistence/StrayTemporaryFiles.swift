import Foundation

/// Clears away the hidden temporary files that an interrupted save leaves in a package's root.
///
/// Only regular files named exactly as a save names its temporary `book.json` or `bak1`
/// (`.book.json.<UUID>.tmp`, `.book.json.bak1.<UUID>.tmp`) are touched, and only once they're
/// `minimumAge` old, so a write still in progress is left alone. One holding the same bytes as
/// `book.json`, a rotated backup or a snapshot in `Backups/` is removed. Any other holds a
/// version found nowhere else, such as another program's version that a save couldn't put back
/// (ADR 0019), so it's renamed to `PackageLayout.recovered(modified:attempt:)`, never removed.
///
/// A file is removed only if it's still the one that was read: it's first renamed to a fresh
/// temporary name, and removed only if the file there has the inode, size and modification time
/// it had when it was read. Anything else found there is recovered instead.
///
/// Nothing here throws: a failure is logged and leaves the file in place.
struct StrayTemporaryFiles {
    static let minimumAge = Interval.minutes(10)

    let layout: PackageLayout
    let fileSystem: any FileSystem

    func sweep(now: Date) {
        let names: [String]
        do {
            names = try candidateNames()
        } catch {
            Log.store.error("couldn't look for stray temporary files", error.logMetadata)
            return
        }
        guard !names.isEmpty else { return }
        var kept = KeptVersions(layout, fileSystem)
        var tally: [Disposal: Int] = [:]
        for name in names {
            let url = layout.root.appending(path: name, directoryHint: .notDirectory)
            tally[dispose(of: url, modifiedBy: now - Self.minimumAge, &kept), default: 0] += 1
        }
        let (removed, recovered, left) = (tally[.removed] ?? 0, tally[.recovered] ?? 0, tally[.left] ?? 0)
        guard removed + recovered + left > 0 else { return }
        Log.store.info(
            "cleared stray temporary files",
            ["removed": .count(removed), "recovered": .count(recovered), "left": .count(left)])
    }

    private enum Disposal {
        case removed, recovered, left
        /// Too young, or not a regular file once opened.
        case skipped
    }

    private func candidateNames() throws(FileSystemError) -> [String] {
        let destinations = [layout.book, layout.backup(.bak1)].map(\.lastPathComponent)
        return try fileSystem.contents(of: layout.root).compactMap { entry in
            guard entry.kind == .file,
                let destination = TemporaryFile.destination(ofName: entry.name),
                destinations.contains(where: { $0.utf8.elementsEqual(destination.utf8) })
            else { return nil }
            return entry.name
        }
    }

    private func dispose(of url: URL, modifiedBy cutoff: Date, _ kept: inout KeptVersions) -> Disposal {
        let file: OpenFile
        do {
            file = try fileSystem.open(url)
        } catch {
            Log.store.error("couldn't open a stray temporary file; left it in place", error.logMetadata)
            return .left
        }
        guard case .file(let metadata, _) = file.item, metadata.modified <= cutoff else { return .skipped }
        guard kept.hasSize(metadata.size) else { return recover(url, modified: metadata.modified) }
        let contents: Data
        do {
            contents = try file.read()
        } catch {
            Log.store.error("couldn't read a stray temporary file; left it in place", error.logMetadata)
            return .left
        }
        guard kept.holds(contents) else { return recover(url, modified: metadata.modified) }
        return remove(url, ifStill: metadata)
    }

    private func remove(_ url: URL, ifStill read: FileMetadata) -> Disposal {
        let aside = layout.root.appending(
            path: TemporaryFile.name(for: layout.book.lastPathComponent, id: UUID()),
            directoryHint: .notDirectory)
        do {
            try fileSystem.publish(TemporaryFile(url: url), as: aside)
        } catch {
            Log.store.error("couldn't move a stray temporary file aside; left it in place", error.logMetadata)
            return .left
        }
        let found = try? fileSystem.item(at: aside)
        guard case .file(let metadata, _)? = found, metadata == read else {
            Log.store.error("a stray temporary file changed while it was being cleared; recovering it")
            let modified = if case .file(let metadata, _)? = found { metadata.modified } else { Date.now }
            return recover(aside, modified: modified)
        }
        do {
            try fileSystem.remove(aside)
            return .removed
        } catch {
            Log.store.error("couldn't remove a stray temporary file", error.logMetadata)
            return .left
        }
    }

    private func recover(_ url: URL, modified: Date) -> Disposal {
        do {
            guard
                try fileSystem.publishUnderFreeName(
                    TemporaryFile(url: url), { layout.recovered(modified: modified, attempt: $0) }) != nil
            else {
                Log.store.error("every recovery name for a stray temporary file was taken; left it in place")
                return .left
            }
        } catch {
            Log.store.error("couldn't rename a stray temporary file; left it in place", error.logMetadata)
            return .left
        }
        Log.store.error("a stray temporary file held a version kept nowhere else; renamed it")
        return .recovered
    }
}

/// The versions the package keeps elsewhere: `book.json`, its backups and the snapshots. Each
/// is read at most once per sweep. Anything that can't be inspected or read is left out, so
/// it can only make a stray look unique.
private struct KeptVersions {
    private struct Copy {
        let url: URL
        let size: Int64
    }

    private let fileSystem: any FileSystem
    private let copies: [Copy]
    private var digests: [URL: ContentDigest?] = [:]

    init(_ layout: PackageLayout, _ fileSystem: any FileSystem) {
        self.fileSystem = fileSystem
        let snapshots =
            ((try? fileSystem.contents(of: layout.snapshots)) ?? [])
            .filter { $0.kind == .file && SnapshotName(fileName: $0.name) != nil }
            .map { layout.snapshots.appending(path: $0.name, directoryHint: .notDirectory) }
        let urls = [layout.book] + BackupSlot.allCases.map(layout.backup) + snapshots
        copies = urls.compactMap { url in
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
