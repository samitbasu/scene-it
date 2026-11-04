import Foundation
import Testing

@testable import SceneItCore

/// Book format §5.4: an entry's reason, and repairing it, by reading it back in its place.
struct EntryRepairTests {
    static let created = "2026-10-31T20:40:00-07:00"
    /// "letter" is c12-18.
    static let body = "He read the letter twice."

    /// The only entry of `text`'s book, which must have exactly one.
    private func onlyEntry(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> (
        Book, ErrorRef
    ) {
        let book = parse(text).book
        let refs = book.errorGroups.flatMap(\.refs)
        try #require(refs.count == 1, "\(refs)", sourceLocation: sourceLocation)
        return (book, refs[0])
    }

    private func repaired(_ repair: EntryRepair?, sourceLocation: SourceLocation = #_sourceLocation) throws
        -> BookPart
    {
        guard case .repaired(let part)? = repair else {
            Issue.record(
                "expected a repair, got \(String(describing: repair))", sourceLocation: sourceLocation)
            throw CancellationError()
        }
        return part
    }

    private func scene(_ part: BookPart, sourceLocation: SourceLocation = #_sourceLocation) throws
        -> BookScene
    {
        guard case .scene(let scene) = part else {
            Issue.record("expected a scene, got \(part)", sourceLocation: sourceLocation)
            throw CancellationError()
        }
        return scene
    }

    // MARK: Comments and marks

    @Test func aCommentWhoseQuoteIsFixedTakesEffect() throws {
        let broken = "- c1 | purple | \(Self.created) | c12-18 | \"lettre\" | Too early?"
        let (book, ref) = try onlyEntry(file(scene: "\(Self.body)\n\n### Comments\n\(broken)"))
        #expect(ref.entry == ErrorEntry(.comments, broken))
        #expect(BookFormat.reason(for: ref, in: book) == .comment(.quoteMismatch))

        let fixed = broken.replacingOccurrences(of: "lettre", with: "letter")
        let scene = try scene(try repaired(BookFormat.repair(ref, as: fixed, in: book)))
        let c1 = CommentID(rawValue: "c1")
        #expect(scene.errors.isEmpty)
        #expect(scene.comments.map(\.id) == [c1])
        #expect(scene.comments.first?.text == "Too early?")
        #expect(scene.body == [[Run("He read the "), Run("letter", comments: [c1]), Run(" twice.")]])
        #expect(scene.id == book.scenes[0].id && scene.modified == book.scenes[0].modified)
    }

    /// A repair can't put a comment in the notes (ADR 0035): its notes range is E11, the entry
    /// stays, and the scene's comments are as they were.
    @Test func aRepairWithANotesRangeIsKeptAsE11() throws {
        let broken = "- c1 | purple | \(Self.created) | c12-18 | \"lettre\" | Too early?"
        let (book, ref) = try onlyEntry(
            file(scene: "\(Self.body)\n\n### Notes\nCheck the tides.\n\n### Comments\n\(broken)"))
        let before = book.scenes[0]
        let inTheNotes = "- c1 | purple | \(Self.created) | notes c6-15 | \"the tides\" | Too early?"
        guard case .kept(.scene(let scene), let reason)? = BookFormat.repair(ref, as: inTheNotes, in: book)
        else {
            Issue.record("expected the entry to be kept")
            return
        }
        #expect(reason == .comment(.notesRange))
        #expect(scene.comments == before.comments)
        #expect(scene.notes == before.notes)
        #expect(scene.errors == [ErrorEntry(.comments, inTheNotes)])
    }

    @Test func aMarkWhoseRangeIsFixedTakesEffect() throws {
        let broken = "- color red | c12-19 | \"letter\""
        let (book, ref) = try onlyEntry(file(scene: "\(Self.body)\n\n### Marks\n\(broken)"))
        #expect(BookFormat.reason(for: ref, in: book) == .mark(.quoteMismatch))
        let scene = try scene(
            try repaired(BookFormat.repair(ref, as: "- color red | c12-18 | \"letter\"", in: book)))
        #expect(scene.errors.isEmpty)
        #expect(scene.body == [[Run("He read the "), Run("letter", color: .red), Run(" twice.")]])
    }

    @Test func aRepairedCommentJoinsTheOthersAndKeepsTheirFormatting() throws {
        let text = file(
            scene: "He read the **letter** twice.\n\n### Comments\n"
                + "- c1 | blue | \(Self.created) | c0-2 | \"He\" | First\n"
                + "- c2 | red | \(Self.created) | c3-7 | \"rade\" | Second\n\n### Marks\n"
                + "- color green | c19-24 | \"twice\"")
        let (book, ref) = try onlyEntry(text)
        let fixed = "- c2 | red | \(Self.created) | c3-7 | \"read\" | Second"
        let scene = try scene(try repaired(BookFormat.repair(ref, as: fixed, in: book)))
        #expect(scene.comments.map(\.id.rawValue) == ["c1", "c2"])
        #expect(
            scene.body == [
                [
                    Run("He", comments: [CommentID(rawValue: "c1")]), Run(" "),
                    Run("read", comments: [CommentID(rawValue: "c2")]), Run(" the "),
                    Run("letter", styles: [.bold]), Run(" "), Run("twice", color: .green), Run("."),
                ]
            ])
    }

    @Test func anEditThatStillBreaksARuleIsKeptWithTheEditedPayload() throws {
        let broken = "- c1 | purple | \(Self.created) | c12-18 | \"lettre\" | Too early?"
        let (book, ref) = try onlyEntry(file(scene: "\(Self.body)\n\n### Comments\n\(broken)"))
        let edited = broken.replacingOccurrences(of: "purple", with: "mauve")
        guard case .kept(.scene(let scene), let reason)? = BookFormat.repair(ref, as: edited, in: book) else {
            Issue.record("expected the entry to stay")
            return
        }
        #expect(reason == .comment(.paletteName))
        #expect(scene.errors == [ErrorEntry(.comments, edited)])
        #expect(scene.comments.isEmpty && scene.body == book.scenes[0].body)
    }

    @Test(arguments: [
        ("c1 | purple | \(created) | c12-18 | \"letter\" |", ErrorReason.comment(.strayLine)),
        ("### Notes", .comment(.strayLine)),
        ("## A new scene", .comment(.strayLine)),
        ("- c1 | purple | \(created) | c12-18 | \"letter\"", .comment(.fields)),
        ("- dup | purple | \(created) | c12-18 | \"letter\" |", .comment(.commentID)),
        ("- c1 | purple | \(created) | c12-99 | \"letter\" |", .comment(.rangeBounds)),
    ])
    func aCommentEditIsCheckedInItsScene(edited: String, reason: ErrorReason) throws {
        let text = file(
            scene: "\(Self.body)\n\n### Comments\n- dup | red | \(Self.created) | c0-2 | \"He\" |\n\n"
                + "- c1 | purple | \(Self.created) | c12-18 | \"lettre\" |")
        let (book, ref) = try onlyEntry(text)
        guard case .kept(.scene(let scene), let got)? = BookFormat.repair(ref, as: edited, in: book) else {
            Issue.record("expected the entry to stay")
            return
        }
        #expect(got == reason)
        #expect(scene.body == book.scenes[0].body && scene.notes.isEmpty, "nothing else changed")
        #expect(scene.comments.map(\.id.rawValue) == ["dup"])
    }

    @Test func anEntryThatReadsAgainSaysSo() throws {
        let entry = "- color red | c12-18 | \"letter\""
        let text = file(scene: "\(Self.body)\n\n### Unparsed\n- [marks] \(entry)")
        let (book, ref) = try onlyEntry(text)
        #expect(BookFormat.reason(for: ref, in: book) == .readsNow)
        let scene = try scene(try repaired(BookFormat.repair(ref, as: ref.entry.payload, in: book)))
        #expect(scene.body[0].runs.contains(Run("letter", color: .red)))
    }

    // MARK: Metadata

    @Test func aMetadataLineReplacesTheValueItRepairs() throws {
        let text = "---\ntitle: T\nformat: 2\n---\n\n## S\nid: s1\nmodified: 2026-01-01 00:00\n\nText.\n"
        let book = parse(text).book
        let ref = try #require(book.errorGroups.first?.refs.first)
        #expect(ref.entry == ErrorEntry(.metadata, "modified: 2026-01-01 00:00"))
        #expect(BookFormat.reason(for: ref, in: book) == .metadata(.badDate))
        let part = try repaired(BookFormat.repair(ref, as: "modified: 2026-01-01T00:00:00+00:00", in: book))
        let scene = try scene(part)
        #expect(scene.modified == Timestamp("2026-01-01T00:00:00+00:00"))
        #expect(scene.errors.count == 1, "the notice about the default stays until it's deleted")
        #expect(scene.errors.first?.tag == .notice)
        #expect(scene.body == book.scenes[0].body)
    }

    /// A repair is the writer's edit, so a line break in a tag becomes a space without a notice,
    /// as typing does (ADR 0028, 0033).
    @Test func aTagsEntryWithALineBreakReadsNowAsSpaces() throws {
        let text =
            "---\ntitle: T\nformat: 2\n---\n\n## S\nid: s1\nmodified: \(Self.created)\ntags: old\n"
            + "tags: red\\ndoor, b\n\nText.\n"
        let (book, ref) = try onlyEntry(text)
        #expect(ref.entry == ErrorEntry(.metadata, "tags: red\\ndoor, b"), "precondition: a repeated key")
        #expect(book.scenes[0].tags == ["old"])
        #expect(BookFormat.reason(for: ref, in: book) == .readsNow)
        let scene = try scene(try repaired(BookFormat.repair(ref, as: ref.entry.payload, in: book)))
        #expect(scene.tags == ["red door", "b"])
        #expect(scene.errors.isEmpty, "no notice for the writer's own edit")
    }

    @Test func aTagLineBreakNoticeAlreadyHeldIsKept() throws {
        let notice = RepairNotice.lineBreaksInTags(.scene).entry
        let text =
            "---\ntitle: T\nformat: 2\n---\n\n## S\nid: s1\nmodified: \(Self.created)\ntags: old\n"
            + "tags: a\\nb\n\nText.\n\n### Unparsed\n- [notice] \(notice.payload)\n"
        let book = parse(text).book
        let ref = try #require(book.errorGroups.flatMap(\.refs).first { $0.entry.tag == .metadata })
        #expect(book.scenes[0].errors.contains(notice), "precondition: the file held the notice")
        let scene = try scene(try repaired(BookFormat.repair(ref, as: ref.entry.payload, in: book)))
        #expect(scene.tags == ["a b"])
        #expect(scene.errors == [notice])
    }

    @Test func aRepairedIDMustBeUnusedInTheWholeBook() throws {
        let text =
            "---\ntitle: T\nformat: 2\n---\n\n## One\nid: one\nmodified: \(Self.created)\n\n"
            + "# Boneyard\n\n## Two\nid: two\nmodified: \(Self.created)\ntags: x\n\n"
            + "## Three\nid: bad id\nmodified: \(Self.created)\n"
        let book = parse(text).book
        let ref = try #require(book.errorGroups.flatMap(\.refs).first { $0.entry.tag == .metadata })
        #expect(BookFormat.reason(for: ref, in: book) == .metadata(.badID))
        for used in ["one", "two"] {
            guard case .kept(_, let reason)? = BookFormat.repair(ref, as: "id: \(used)", in: book) else {
                Issue.record("expected \(used) to be refused")
                continue
            }
            #expect(reason == .metadata(.idInUse))
        }
        let scene = try scene(try repaired(BookFormat.repair(ref, as: "id: three", in: book)))
        #expect(scene.id == SceneID(rawValue: "three"))
        #expect(scene.title == "Three" && scene.tags.isEmpty)
    }

    @Test func aMetadataEditMustBeAField() throws {
        let text =
            "---\ntitle: T\nformat: 2\n---\n\n## S\nid: s1\nmodified: \(Self.created)\ncolour: red\n\nText.\n"
        let (book, ref) = try onlyEntry(text)
        #expect(BookFormat.reason(for: ref, in: book) == .metadata(.unknownKey))
        guard case .kept(.scene(let kept), let reason)? = BookFormat.repair(ref, as: "red", in: book) else {
            Issue.record("expected the entry to stay")
            return
        }
        #expect(reason == .metadata(.notAField))
        #expect(kept.body == book.scenes[0].body, "it didn't become a paragraph")
        let tagged = try scene(try repaired(BookFormat.repair(ref, as: "tags: red", in: book)))
        #expect(tagged.tags == ["red"])
    }

    // MARK: Front matter

    @Test func aFrontMatterLineReplacesTheValueItRepairs() throws {
        let (book, ref) = try onlyEntry("---\ntitle: Old\nformat: 2\ncolour: blue\n---\n")
        #expect(BookFormat.reason(for: ref, in: book) == .frontMatter(.unknownKey))
        #expect(
            try repaired(BookFormat.repair(ref, as: "title: New", in: book))
                == .header(title: "New", errors: []))
        guard case .kept(_, let reason)? = BookFormat.repair(ref, as: "format: 3", in: book) else {
            Issue.record("a newer format can't be repaired in")
            return
        }
        #expect(reason == .frontMatter(.otherFormat))
    }

    // MARK: What can't be repaired

    @Test func linesAndNoticesHaveFixedReasonsAndCantBeRepaired() throws {
        let book = parse("---\ntitle: T\n---\n\nRemember to back this up!\n").book
        let refs = book.errorGroups.flatMap(\.refs)
        #expect(refs.map(\.entry.tag) == [.line, .notice])
        #expect(refs.map { BookFormat.reason(for: $0, in: book) } == [.line, .notice])
        for ref in refs {
            #expect(BookFormat.repair(ref, as: "format: 2", in: book) == nil)
        }
    }

    @Test func aRefTheBookNoLongerHoldsIsRefused() throws {
        let broken = "- color red | c12-19 | \"letter\""
        let (book, ref) = try onlyEntry(file(scene: "\(Self.body)\n\n### Marks\n\(broken)"))
        let moved = ErrorRef(owner: ref.owner, index: ref.index + 1, entry: ref.entry)
        let other = ErrorRef(owner: ref.owner, index: ref.index, entry: ErrorEntry(.marks, "something else"))
        #expect(BookFormat.repair(moved, as: broken, in: book) == nil)
        #expect(BookFormat.repair(other, as: broken, in: book) == nil)
    }

    // MARK: Grouping

    @Test func anEntryKeepsItsIdentityWhileItsNeighboursChange() throws {
        var book = parse(try SpecExampleTests.damagedBytes()).book
        let refs = book.errorGroups.flatMap(\.refs)
        let last = try #require(refs.last)
        let identity = book.identity(of: last)
        let first = try #require(book.errorGroups.first { $0.owner == last.owner }?.refs.first)
        try #require(first != last, "precondition: a neighbour in the same scene")
        var errors = try #require(book.errors(of: first.owner))
        errors.remove(at: first.index)
        let part = try #require(book.part(first.owner)).with(errors: errors)
        book.replace(first.owner, with: part)
        let moved = try #require(book.errorRef(last.owner, at: last.index - 1))
        #expect(moved.entry == last.entry)
        #expect(book.identity(of: moved) == identity)

        var twins = Book(title: "T", errors: [ErrorEntry(.line, "x"), ErrorEntry(.line, "x")])
        let ids = twins.errorGroups[0].refs.map(twins.identity)
        #expect(Set(ids).count == 2, "equal entries are told apart")
        twins.errors.remove(at: 0)
        #expect(twins.identity(of: twins.errorGroups[0].refs[0]) == ids[0])
    }

    @Test func theDamagedExamplesRowsAndReasons() throws {
        let book = parse(try SpecExampleTests.damagedBytes()).book
        let groups = book.errorGroups
        let scenesWithEntries = (book.scenes + book.boneyard).filter { !$0.errors.isEmpty }
        #expect(groups.map(\.owner) == [.book] + scenesWithEntries.map { .scene($0.id) })
        #expect(groups.flatMap(\.refs).map(\.entry) == Array(book.errorEntries.joined()))
        #expect(book.errorCount == 12, "book format §9.2's twelve rows")
        let reasons = groups.flatMap(\.refs).map { BookFormat.reason(for: $0, in: book) }
        #expect(
            reasons == [
                .frontMatter(.unknownKey), .line, .notice,
                .comment(.paletteName), .comment(.quoteMismatch), .notice,
                .notice,
                .line, .notice, .notice,
                .comment(.quoteSyntax), .notice,
            ])
    }
}
