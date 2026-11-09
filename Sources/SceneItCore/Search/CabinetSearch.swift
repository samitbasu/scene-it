import Foundation

/// What the File Cabinet scope searches (PLAN §9.1): the copies filed in a range of days, either
/// end open, and of those all, or the one picked.
public struct CabinetChoice: Hashable, Sendable {
    public var dates: FiledDates
    /// `nil` for every copy in the range.
    public var copy: FiledCopyNumber?

    public init(dates: FiledDates = FiledDates(), copy: FiledCopyNumber? = nil) {
        self.dates = dates
        self.copy = copy
    }

    /// The copy picker's copies: those filed in the range, newest first.
    public func pickable(in index: ArchiveIndex) -> [FiledCopy] {
        FileCabinet.newestFirst(index.copies.filter { dates.contains($0.filed) })
    }

    /// The copies searched, newest first: the one picked, or every one in the range. A picked
    /// copy outside the range is searched as no copy, since the picker can't show it
    /// (`fitted(to:)`).
    public func searched(in index: ArchiveIndex) -> [FiledCopy] {
        let pickable = pickable(in: index)
        guard let copy else { return pickable }
        return pickable.filter { $0.number == copy }
    }

    /// This choice with the picked copy forgotten if the range no longer holds it, or the index
    /// no longer has it.
    public func fitted(to index: ArchiveIndex) -> CabinetChoice {
        guard let copy, !pickable(in: index).contains(where: { $0.number == copy }) else { return self }
        return CabinetChoice(dates: dates)
    }
}

/// One version's results in the File Cabinet: the copy's own tag hit, if any, and its scenes.
public struct VersionHits: Hashable, Sendable {
    public let version: SearchVersion
    /// The order the engine ranked them in; a copy's own tags are listed like a scene.
    public let scenes: [SceneHits]

    /// `scenes` in groups by version, in the order of `versions`; a version with no hits has no
    /// group, and hits of a version not in `versions` are left out.
    public static func grouped(_ scenes: [SceneHits], by versions: [SearchVersion]) -> [VersionHits] {
        let byVersion = Dictionary(grouping: scenes, by: \.version)
        return versions.compactMap { version in
            byVersion[version].map { VersionHits(version: version, scenes: $0) }
        }
    }
}

/// The File Cabinet's summary counts (PLAN §9.1): "12 matches in 9 scenes across 3 filed copies ·
/// tags match on 2 copies".
public struct CabinetCounts: Hashable, Sendable {
    /// Hits in scenes, not in the copies' own tags.
    public let matches: Int
    public let scenes: Int
    /// The copies with a hit in a scene.
    public let copies: Int
    /// The copies whose own tags matched.
    public let taggedCopies: Int

    public init(_ scenes: [SceneHits]) {
        let inScenes = scenes.filter { $0.scene != nil }
        matches = inScenes.reduce(0) { $0 + $1.hits.count }
        self.scenes = inScenes.count
        copies = Set(inScenes.map(\.version)).count
        taggedCopies = scenes.count { $0.scene == nil }
    }
}

/// A filed copy as the File Cabinet's search holds it: indexed, or why it couldn't be.
public enum FiledCopyIndex: Sendable {
    case indexed(KeywordSearch)
    /// Not searched; the sheet says so.
    case unreadable(FileSystemError)
}

/// The filed copies' search indexes (PLAN §9.2): each copy is read, parsed and indexed off the
/// main actor the first time a File Cabinet search asks for it, then kept until the book closes.
/// Only each copy's search units and their words are kept, never its book.
///
/// A filed copy is only ever read here.
@MainActor
public final class FiledCopyIndexes {
    public typealias Load = @Sendable (FiledCopyNumber) async -> FiledCopyIndex

    private let load: Load
    private var loads: [FiledCopyNumber: Task<FiledCopyIndex, Never>] = [:]
    private var loaded: [FiledCopyNumber: FiledCopyIndex] = [:]

    public init(load: @escaping Load) {
        self.load = load
    }

    /// Reads the filed copies of the package at `layout`.
    convenience init(layout: PackageLayout, fileSystem: any FileSystem, defaults: ParseDefaults) {
        self.init { number in await Self.index(number, layout, fileSystem, defaults) }
    }

    /// `number`'s index, read now unless it was already, or is being.
    public func index(of number: FiledCopyNumber) async -> FiledCopyIndex {
        if let index = loaded[number] { return index }
        let index = await start(number).value
        loaded[number] = index
        loads[number] = nil
        return index
    }

    /// Starts reading each of `numbers` not yet read, all at once.
    public func prepare(_ numbers: [FiledCopyNumber]) {
        for number in numbers where loaded[number] == nil { _ = start(number) }
    }

    /// Whether `number` has been read, so a search won't wait for it.
    public func isLoaded(_ number: FiledCopyNumber) -> Bool {
        loaded[number] != nil
    }

    /// A copy was just filed as `number`: once any File Cabinet search has run, it's read at once,
    /// so the next search doesn't wait for it.
    func filed(_ number: FiledCopyNumber) {
        guard !loads.isEmpty || !loaded.isEmpty else { return }
        _ = start(number)
    }

    /// The book closed: every index goes.
    func drop() {
        for load in loads.values { load.cancel() }
        loads = [:]
        loaded = [:]
    }

    private func start(_ number: FiledCopyNumber) -> Task<FiledCopyIndex, Never> {
        if let task = loads[number] { return task }
        let load = self.load
        let task = Task { await load(number) }
        loads[number] = task
        return task
    }

    @concurrent
    private nonisolated static func index(
        _ number: FiledCopyNumber, _ layout: PackageLayout, _ fileSystem: any FileSystem,
        _ defaults: ParseDefaults
    ) async -> FiledCopyIndex {
        do throws(FileSystemError) {
            let parsed = try defaults.parseFiledCopy(layout.filedCopy(number), fileSystem)
            return .indexed(KeywordSearch(units: SearchUnit.units(of: parsed.book, version: .filed(number))))
        } catch {
            Log.store.error("couldn't read a filed copy to search it", error.logMetadata)
            return .unreadable(error)
        }
    }
}

extension ParseDefaults {
    /// A filed copy's bytes, parsed as a book and never opened as one: the file is only read.
    func parseFiledCopy(_ file: URL, _ fileSystem: any FileSystem) throws(FileSystemError) -> ParsedBook {
        parse(try fileSystem.read(file))
    }
}
