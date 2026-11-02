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
/// Nothing here throws: a failure is logged and leaves the file where it is.
struct StrayTemporaryFiles {
    static let minimumAge = Interval.minutes(10)

    let layout: PackageLayout
    let fileSystem: any FileSystem

    func sweep(now: Date) {
        let strays: [Stray]
        do {
            strays = try find(olderThan: now - Self.minimumAge)
        } catch {
            Log.store.error("couldn't look for stray temporary files", error.logMetadata)
            return
        }
        guard !strays.isEmpty else { return }
        let copies = knownCopies()
        var removed = 0
        var recovered = 0
        for stray in strays {
            switch dispose(of: stray, copies) {
            case .removed: removed += 1
            case .recovered: recovered += 1
            case .left: break
            }
        }
        Log.store.info(
            "cleared stray temporary files",
            ["found": .count(strays.count), "removed": .count(removed), "recovered": .count(recovered)])
    }

    private struct Stray {
        let url: URL
        let metadata: FileMetadata
    }

    private enum Disposal {
        case removed, recovered, left
    }

    private func find(olderThan cutoff: Date) throws(FileSystemError) -> [Stray] {
        let destinations = [layout.book, layout.backup(.bak1)].map(\.lastPathComponent)
        return try fileSystem.contents(of: layout.root).compactMap { entry in
            guard entry.kind == .file,
                let destination = TemporaryFile.destination(ofName: entry.name),
                destinations.contains(where: { $0.utf8.elementsEqual(destination.utf8) })
            else { return nil }
            let url = layout.root.appending(path: entry.name, directoryHint: .notDirectory)
            guard case .file(let metadata, _)? = try? fileSystem.item(at: url), metadata.modified <= cutoff
            else { return nil }
            return Stray(url: url, metadata: metadata)
        }
    }

    private struct Copy {
        let url: URL
        let size: Int64
    }

    /// The files whose versions are kept elsewhere: anything that can't be inspected is left
    /// out, so it can only make a stray look unique.
    private func knownCopies() -> [Copy] {
        let snapshots =
            ((try? fileSystem.contents(of: layout.snapshots)) ?? [])
            .filter { $0.kind == .file && SnapshotName(fileName: $0.name) != nil }
            .map { layout.snapshots.appending(path: $0.name, directoryHint: .notDirectory) }
        let urls = [layout.book] + BackupSlot.allCases.map(layout.backup) + snapshots
        return urls.compactMap { url in
            guard case .file(let metadata, _)? = try? fileSystem.item(at: url) else { return nil }
            return Copy(url: url, size: metadata.size)
        }
    }

    private func dispose(of stray: Stray, _ copies: [Copy]) -> Disposal {
        let contents: Data
        do {
            contents = try fileSystem.read(stray.url)
        } catch {
            Log.store.error("couldn't read a stray temporary file; left it in place", error.logMetadata)
            return .left
        }
        let isKept = copies.contains { copy in
            copy.size == contents.count && (try? fileSystem.read(copy.url)) == contents
        }
        return isKept ? remove(stray) : recover(stray)
    }

    private func remove(_ stray: Stray) -> Disposal {
        do {
            try fileSystem.remove(stray.url)
            return .removed
        } catch {
            Log.store.error("couldn't remove a stray temporary file", error.logMetadata)
            return .left
        }
    }

    private func recover(_ stray: Stray) -> Disposal {
        for attempt in 1...Self.recoveryNameAttempts {
            do {
                try fileSystem.publish(
                    TemporaryFile(url: stray.url),
                    as: layout.recovered(modified: stray.metadata.modified, attempt: attempt))
                Log.store.error("a stray temporary file held a version kept nowhere else; renamed it")
                return .recovered
            } catch  where error.cause == .alreadyExists {
                continue
            } catch {
                Log.store.error("couldn't rename a stray temporary file; left it in place", error.logMetadata)
                return .left
            }
        }
        Log.store.error("every recovery name for a stray temporary file was taken; left it in place")
        return .left
    }

    private static let recoveryNameAttempts = 100
}
