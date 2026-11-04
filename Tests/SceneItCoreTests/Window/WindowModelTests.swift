import Foundation
import Testing

@testable import SceneItCore

private func scene(_ id: String, _ title: SceneTitle = "", body: [Paragraph] = []) throws -> BookScene {
    BookScene(
        id: SceneID(rawValue: id), modified: try timestamp("2026-01-01T00:00:00+00:00"), title: title,
        body: body)
}

private func sampleBook() throws -> Book {
    Book(
        title: "My Novel",
        scenes: [
            try scene("s1", "The ferry", body: [[Run("The ferry left at dawn.")], [Run("She had packed.")]]),
            try scene("s2", body: [[Run("Arrival")]]),
        ],
        boneyard: [try scene("b1", "The brother", body: [[Run("Cut words here, five of them.")]])])
}

@Suite struct WordCountTests {
    @Test(arguments: [
        ("", 0),
        ("   ", 0),
        ("--", 0),
        ("...", 0),
        ("-", 0),
        ("— . , ! ?", 0),
        ("The ferry left at dawn.", 5),
        ("don't", 1),
        ("1,409 words", 2),
        ("well-known", 1),
        ("dawn--and", 1),
        ("dawn—and", 1),
        ("dawn -- and", 2),
        ("She paused ... then went on.", 5),
        ("“Quoted,” she said.", 3),
        ("(aside)", 1),
        ("one    two\tthree", 3),
        ("  leading and trailing  ", 3),
    ])
    func wordsInOneParagraph(text: String, words: Int) {
        #expect(WordCount([[Run(text)]]) == WordCount(words: words))
    }

    @Test func runsJoinWithinAParagraph() {
        #expect(WordCount([[Run("Hel", styles: [.bold]), Run("lo there")]]).words == 2)
        #expect(WordCount([[Run("--"), Run("x")]]).words == 1, "punctuation joined to a word is part of it")
    }

    @Test func paragraphBreaksSeparateWords() {
        #expect(WordCount([[Run("endstart")]]).words == 1, "precondition: joined, it's one word")
        #expect(WordCount([[Run("end")], [Run("start")]]).words == 2)
        #expect(WordCount([[Run("one")], [], [Run("two")]]).words == 2)
    }

    @Test func theTitleIsNotCounted() throws {
        #expect(try sampleBook().scenes[0].wordCount.words == 8)
    }
}

@Suite struct SceneWordCountsTests {
    @Test func theManuscriptIsTheStoryAndNotTheBoneyard() throws {
        let book = try sampleBook()
        let counts = SceneWordCounts(book)
        #expect(counts[SceneID(rawValue: "b1")].words == 6)
        #expect(counts.manuscript(of: book).words == 9)
    }

    @Test func reorderingAndCuttingNeedNoRecount() throws {
        var book = try sampleBook()
        let counts = SceneWordCounts(book)
        let made = counts.countsMade
        book.scenes.reverse()
        #expect(counts.manuscript(of: book).words == 9)
        book.boneyard.insert(book.scenes.removeFirst(), at: 0)
        #expect(counts.manuscript(of: book).words == 8, "cutting s2 (1 word) leaves s1")
        book.scenes.append(book.boneyard.removeLast())
        #expect(counts.manuscript(of: book).words == 14, "restoring b1 (6 words)")
        #expect(counts.countsMade == made)
    }
}

@Suite struct SceneLocationTests {
    @Test func locations() throws {
        let book = try sampleBook()
        #expect(SceneLocation(of: nil, in: book) == .noScene)
        #expect(
            SceneLocation(of: SceneID(rawValue: "s1"), in: book) == .story(book.scenes[0], number: 1, of: 2))
        #expect(
            SceneLocation(of: SceneID(rawValue: "s2"), in: book) == .story(book.scenes[1], number: 2, of: 2))
        #expect(SceneLocation(of: SceneID(rawValue: "b1"), in: book) == .boneyard(book.boneyard[0]))
        #expect(SceneLocation(of: SceneID(rawValue: "deleted"), in: book) == .noScene)
    }

    @Test func theCurrentSceneMarkIsTheNumberOrBOrGrayedWithNoBadge() throws {
        let book = try sampleBook()
        #expect(CurrentSceneMark(.story(book.scenes[0], number: 12, of: 24)) == .badge("12"))
        #expect(CurrentSceneMark(.boneyard(book.boneyard[0])) == .badge("B"))
        #expect(CurrentSceneMark(.noScene) == .unavailable)
    }

    @Test func previousAndNextWalkTheStoryOnly() throws {
        let book = try sampleBook()
        let (s1, s2, b1) = (SceneID(rawValue: "s1"), SceneID(rawValue: "s2"), SceneID(rawValue: "b1"))
        #expect(book.scene(.next, from: s1) == s2)
        #expect(book.scene(.previous, from: s2) == s1)
        #expect(book.scene(.previous, from: s1) == nil, "the story's first scene")
        #expect(book.scene(.next, from: s2) == nil, "the story's last scene, with the Boneyard after it")
        for step in SceneStep.allCases {
            #expect(book.scene(step, from: b1) == nil, "a Boneyard scene")
            #expect(book.scene(step, from: nil) == nil, "no scene open")
            #expect(book.scene(step, from: SceneID(rawValue: "deleted")) == nil)
        }
    }
}

@Suite struct UndoRoutingTests {
    @Test func whileTheScenesSheetIsOpenUndoActsOnTheStructure() {
        for focus in [UndoFocus.text, .errorsTab, .elsewhere] {
            #expect(UndoStack(mode: .scenes, focus: focus, dialog: .none) == .structure, "\(focus)")
        }
    }

    /// File a Copy's sheet keeps the page as the window's first responder behind it.
    @Test func whileADialogIsAttachedOnlyItsTextFieldCanBeUndone() {
        for mode in WindowMode.allCases {
            #expect(UndoStack(mode: mode, focus: .text, dialog: .attached) == .focusedText, "\(mode)")
            #expect(UndoStack(mode: mode, focus: .errorsTab, dialog: .attached) == UndoStack.none, "\(mode)")
            #expect(UndoStack(mode: mode, focus: .elsewhere, dialog: .attached) == UndoStack.none, "\(mode)")
        }
    }

    @Test func otherwiseTheFocusDecides() {
        for mode in WindowMode.allCases where mode != .scenes {
            #expect(UndoStack(mode: mode, focus: .text, dialog: .none) == .focusedText, "\(mode)")
            #expect(UndoStack(mode: mode, focus: .errorsTab, dialog: .none) == .errors, "\(mode)")
            #expect(UndoStack(mode: mode, focus: .elsewhere, dialog: .none) == UndoStack.none, "\(mode)")
        }
    }
}

@Suite struct WindowModeTests {
    @Test func aSheetIconOpensItsSheetAndClosesItAgain() {
        for sheet in WindowMode.allCases where sheet.isSheet {
            #expect(WindowMode.page.choosing(sheet) == sheet)
            #expect(sheet.choosing(sheet) == .page)
        }
    }

    @Test func anotherSheetIconSwitchesSheets() {
        #expect(WindowMode.scenes.choosing(.search) == .search)
        #expect(WindowMode.search.choosing(.fileCabinet) == .fileCabinet)
    }

    @Test func currentSceneShowsThePage() {
        for mode in WindowMode.allCases {
            #expect(mode.choosing(.page) == .page)
            #expect(mode.closingSheet == .page)
        }
    }

    @Test func theRailHighlightsExactlyOneItem() {
        for mode in WindowMode.allCases {
            #expect(WindowMode.allCases.filter(mode.highlights) == [mode])
        }
        #expect(WindowMode.allCases.filter(\.isSheet) == [.scenes, .search, .fileCabinet])
    }
}

@Suite struct WindowWordingTests {
    private func location(_ id: String?, in book: Book) -> SceneLocation {
        SceneLocation(of: id.map(SceneID.init(rawValue:)), in: book)
    }

    @Test func breadcrumb() throws {
        let book = try sampleBook()
        let crumb = { WindowWording.breadcrumb(bookTitle: book.title, location($0, in: book)) }
        #expect(crumb("s1") == ["My Novel", "1. The ferry"])
        #expect(crumb("s2") == ["My Novel", "2. Untitled scene"])
        #expect(crumb("b1") == ["My Novel", "Boneyard", "The brother"])
        #expect(crumb(nil) == ["My Novel"])
    }

    @Test func statusParts() throws {
        let book = try sampleBook()
        let parts = { (id: String?, scene: Int) in
            WindowWording.statusParts(
                location(id, in: book), sceneWords: WordCount(words: scene), bookWords: WordCount(words: 409))
        }
        #expect(parts("s1", 8) == ["Scene 1 of 2 · 8 words", "Book · 409 words"])
        #expect(parts("s2", 1) == ["Scene 2 of 2 · 1 word", "Book · 409 words"])
        #expect(parts("b1", 6) == ["In the Boneyard (not in the manuscript)", "Book · 409 words"])
        #expect(parts(nil, 0) == ["Book · 409 words"])
    }

    @Test func tooltips() throws {
        let book = try sampleBook()
        #expect(WindowWording.currentSceneTooltip(location("s1", in: book)) == "Scene 1: The ferry")
        #expect(WindowWording.currentSceneTooltip(location("b1", in: book)) == "Boneyard: The brother")
        #expect(WindowWording.currentSceneTooltip(.noScene) == "No scene open")
    }
}
