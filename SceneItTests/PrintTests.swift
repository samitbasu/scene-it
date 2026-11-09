import AppKit
import PDFKit
import SceneItCore
import Testing

@testable import SceneIt

/// Print (PLAN §10.1) through the app's own print view and operation, printed to PDF data in
/// memory, never to a printer and never with the dialog shown: text only is portrait pages of the
/// text; text with comments is landscape, the comments beside the text; the whole manuscript
/// leaves the Boneyard out; and a read-only book prints as it's shown.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct PrintTests {
    static let modified = Timestamp("2026-11-03T10:15:00-08:00")!
    static let letter = CGSize(width: 612, height: 792)

    static let early = comment(1, .purple, "Too early for this reveal?")
    static let late = comment(2, .red, "Check the ferry schedule for the 1950s.")

    static func comment(_ number: Int, _ color: PaletteColor, _ text: String) -> SceneItCore::Comment {
        SceneItCore::Comment(
            id: CommentID(rawValue: "01JC4K0000000000000000C00\(number)"), color: color, text: text,
            created: Timestamp("2026-11-03T10:0\(number):00-08:00")!)
    }

    static let filler = [
        Run(
            "She had packed in the dark, by feel, the way she used to as a girl when the house was asleep and leaving "
                + "still seemed like a game.")
    ]

    static func book() -> Book {
        let ferry = BookScene(
            id: SceneID(rawValue: "ferry"), modified: modified, title: "The ferry",
            body: [
                [
                    Run("The ferry left at "), Run("dawn", comments: [late.id]),
                    Run(", and Mara watched the "),
                    Run("letter", comments: [early.id]), Run(" burn -- \"slowly.\""),
                ]
            ] + Array(repeating: Paragraph(filler), count: 40),
            comments: [early, late])
        let island = BookScene(
            id: SceneID(rawValue: "island"), modified: modified, title: "The island", body: [[Run("Gulls.")]])
        let cut = BookScene(
            id: SceneID(rawValue: "cut"), modified: modified, title: "The brother",
            body: [[Run("Cut words.")]])
        return Book(title: "My Novel", scenes: [ferry, island], boneyard: [cut])
    }

    static func printInfo(_ layout: PrintLayout) -> NSPrintInfo {
        let info = ManuscriptPrinting.printInfo(for: layout)
        info.paperSize = letter
        return info
    }

    /// `view` printed to PDF data with `info`, as Save as PDF writes it.
    /// `NSPrintOperation.pdfOperation` would make the whole view one page, so this saves the job
    /// to a file in a temporary folder, as the dialog's Save as PDF does. It never reaches a printer.
    static func pdf(_ view: ManuscriptPrintView, _ info: NSPrintInfo) throws -> PDFDocument {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "SceneItPrintTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appending(path: "printed.pdf")
        let saving = try #require(info.copy() as? NSPrintInfo)
        saving.jobDisposition = .save
        saving.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        try #require(saving.jobDisposition == .save, "precondition: to a file, not a printer")
        let operation = NSPrintOperation(view: view, printInfo: saving)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        try #require(operation.run(), "the PDF was written")
        return try #require(PDFDocument(url: url))
    }

    static func text(_ document: PDFDocument) -> String {
        (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
    }

    static func view(_ book: Book, layout: PrintLayout, range: PrintRange = .thisScene) -> ManuscriptPrintView
    {
        let open = book.scenes.first?.id
        let choices = PrintChoices(openScene: open, in: book)
        choices.layout = layout
        choices.range = range
        return ManuscriptPrintView(book: book, openScene: open, choices: choices)
    }

    @Test func textOnlyPrintsPortraitPagesOfTheText() throws {
        let view = Self.view(Self.book(), layout: .textOnly)
        let document = try Self.pdf(view, Self.printInfo(.textOnly))
        let pages = try #require(view.pages)
        try #require(pages.pageCount > 1, "precondition: the scene runs over a page")
        #expect(document.pageCount == pages.pageCount)
        for index in 0..<document.pageCount {
            let bounds = try #require(document.page(at: index)?.bounds(for: .mediaBox))
            #expect(bounds.size == Self.letter, "portrait Letter")
        }
        let text = Self.text(document)
        #expect(text.contains("The ferry"))
        #expect(text.contains("The ferry left at dawn"))
        #expect(text.contains("burn \u{2014} \u{201C}slowly.\u{201D}"), "smartened")
        #expect(!text.contains("Too early"), "no comments")
        #expect(!text.contains("The island"), "this scene only")
    }

    @Test func textWithCommentsPrintsLandscapeWithTheCommentsBesideTheText() throws {
        let view = Self.view(Self.book(), layout: .withComments)
        let document = try Self.pdf(view, Self.printInfo(.withComments))
        let pages = try #require(view.pages)
        #expect(document.pageCount == pages.pageCount)
        let first = try #require(document.page(at: 0))
        #expect(first.bounds(for: .mediaBox).size == CGSize(width: 792, height: 612), "landscape")
        #expect((first.string ?? "").contains("The ferry left at dawn"))
        let column = try #require(pages.geometry.comments)
        for start in ["Too early", "Check the ferry"] {
            let found = try #require(document.findString(start, withOptions: []).first, "\(start) is printed")
            #expect(found.bounds(for: first).minX >= column.minX, "\(start) is in the comments' column")
        }
        let boxes = pages.commentBoxes(onPage: 0)
        try #require(boxes.count == 2, "precondition: both comments on the first page")
        #expect(boxes[1].minY >= boxes[0].maxY, "the second, on the same line, is pushed below the first")
    }

    @Test func theWholeManuscriptLeavesTheBoneyardOut() throws {
        let view = Self.view(Self.book(), layout: .textOnly, range: .wholeManuscript)
        let text = Self.text(try Self.pdf(view, Self.printInfo(.textOnly)))
        #expect(text.contains("The ferry"))
        #expect(text.contains("The island"))
        #expect(!text.contains("The brother"))
        #expect(!text.contains("Cut words"))
    }

    /// Choosing a layout in the accessory turns the dialog's paper and tells its preview, and the
    /// dialog's summary names the choices.
    @Test func theAccessoryTurnsThePaperAndRedrawsThePreview() throws {
        let choices = PrintChoices(openScene: SceneID(rawValue: "ferry"), in: Self.book())
        let accessory = PrintAccessoryController(choices: choices)
        let info = Self.printInfo(.textOnly)
        accessory.representedObject = info
        _ = accessory.view
        #expect(accessory.keyPathsForValuesAffectingPreview() == ["revision"])
        var observed = 0
        let observation = accessory.observe(\.revision) { _, _ in MainActor.assumeIsolated { observed += 1 } }
        defer { observation.invalidate() }

        choices.layout = .withComments
        #expect(info.orientation == .landscape)
        choices.range = .wholeManuscript
        #expect(info.orientation == .landscape)
        choices.layout = .textOnly
        #expect(info.orientation == .portrait)
        #expect(observed == 3)
        #expect(
            accessory.localizedSummaryItems() == [
                [.itemName: "Layout", .itemDescription: "Text only"],
                [.itemName: "Range", .itemDescription: "Whole manuscript"],
            ])
    }

    @Test func withNoSceneOpenOnlyTheWholeManuscriptIsOffered() {
        let choices = PrintChoices(openScene: nil, in: Self.book())
        #expect(choices.ranges == [.wholeManuscript])
        #expect(choices.range == .wholeManuscript)
        #expect(PrintChoices(openScene: SceneID(rawValue: "ferry"), in: Self.book()).range == .thisScene)
    }

    @Test func theFileMenuHasPrint() throws {
        let item = try #require(menuItem(titled: PrintWording.menuItem, in: NSApp.mainMenu))
        #expect(item.keyEquivalent == "p")
        #expect(item.keyEquivalentModifierMask == .command)
    }

    /// A book open read-only (open in another copy of Scene It) prints as it's shown, through the
    /// operation the menu and the toolbar run, with the choices as the dialog's accessory.
    @Test func aReadOnlyBookPrints() async throws {
        try await withTemporaryFolder { folder in
            let books = BookController(role: .testHost)
            let url = folder.appending(path: "My Novel.sceneit", directoryHint: .isDirectory)
            let holder = try BookPackage.create(at: url, title: "My Novel")
            _ = try holder.package.save(Self.book())
            #expect(await books.store.open(url) == .openedReadOnly(.openElsewhere))
            let book = try #require(books.store.current)
            try #require(!book.isEditable, "precondition: read-only")
            #expect(ManuscriptPrinting.canPrint(book))

            let operation = ManuscriptPrinting.operation(for: book)
            #expect(operation.printPanel.accessoryControllers.count == 1)
            #expect(operation.jobTitle == "My Novel – The ferry")
            #expect(operation.printInfo.orientation == .portrait)
            let view = try #require(operation.view as? ManuscriptPrintView)
            let info = operation.printInfo
            info.paperSize = Self.letter
            let text = Self.text(try Self.pdf(view, info))
            #expect(text.contains("The ferry left at dawn"))
            #expect(await books.store.closeBook() == .left)
            withExtendedLifetime(holder) {}
        }
    }
}
