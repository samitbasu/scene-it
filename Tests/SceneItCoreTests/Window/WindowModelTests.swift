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
        ("— . , ! ?", 0),
        ("The ferry left at dawn.", 5),
        ("don't", 1),
        ("1,409 words", 2),
        ("well-known", 2),
        ("dawn—and", 2),
        ("“Quoted,” she said.", 3),
        ("  leading and trailing  ", 3),
    ])
    func wordsInOneParagraph(text: String, words: Int) {
        #expect(WordCount([[Run(text)]]) == WordCount(words: words))
    }

    @Test func runsJoinWithinAParagraph() {
        #expect(WordCount([[Run("Hel", styles: [.bold]), Run("lo there")]]).words == 2)
    }

    @Test func paragraphBreaksSeparateWords() {
        let joined = "endstart"
        #expect(WordCount([[Run(joined)]]).words == 1, "precondition: joined, it's one word")
        #expect(WordCount([[Run("end")], [Run("start")]]).words == 2)
        #expect(WordCount([[Run("one")], [], [Run("two")]]).words == 2)
    }

    @Test func theManuscriptCountsStoryBodiesOnly() throws {
        let book = try sampleBook()
        #expect(book.scenes[0].wordCount.words == 8, "the title isn't counted")
        #expect(book.boneyard[0].wordCount.words == 6)
        #expect(book.manuscriptWordCount.words == 9, "the Boneyard isn't counted")
    }
}

@Suite struct SceneLocationTests {
    @Test func locations() throws {
        let book = try sampleBook()
        #expect(SceneLocation(of: nil, in: book) == .noScene)
        #expect(SceneLocation(of: SceneID(rawValue: "s1"), in: book) == .story(number: 1, of: 2))
        #expect(SceneLocation(of: SceneID(rawValue: "s2"), in: book) == .story(number: 2, of: 2))
        #expect(SceneLocation(of: SceneID(rawValue: "b1"), in: book) == .boneyard)
        #expect(SceneLocation(of: SceneID(rawValue: "deleted"), in: book) == .noScene)
    }

    @Test func theCurrentSceneMarkIsTheNumberOrBOrGrayedWithNoBadge() {
        #expect(CurrentSceneMark(.story(number: 12, of: 24)) == .badge("12"))
        #expect(CurrentSceneMark(.boneyard) == .badge("B"))
        #expect(CurrentSceneMark(.noScene) == .unavailable)
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
    @Test func breadcrumb() throws {
        let book = try sampleBook()
        #expect(
            WindowWording.breadcrumb(book: book, openScene: SceneID(rawValue: "s1")) == [
                "My Novel", "1. The ferry",
            ])
        #expect(
            WindowWording.breadcrumb(book: book, openScene: SceneID(rawValue: "s2")) == [
                "My Novel", "2. Untitled scene",
            ]
        )
        #expect(
            WindowWording.breadcrumb(book: book, openScene: SceneID(rawValue: "b1")) == [
                "My Novel", "Boneyard", "The brother",
            ])
        #expect(WindowWording.breadcrumb(book: book, openScene: nil) == ["My Novel"])
    }

    @Test func statusParts() throws {
        let book = try sampleBook()
        #expect(
            WindowWording.statusParts(book: book, openScene: SceneID(rawValue: "s1")) == [
                "Scene 1 of 2 · 8 words", "Book · 9 words",
            ])
        #expect(
            WindowWording.statusParts(book: book, openScene: SceneID(rawValue: "s2")) == [
                "Scene 2 of 2 · 1 word", "Book · 9 words",
            ])
        #expect(
            WindowWording.statusParts(book: book, openScene: SceneID(rawValue: "b1")) == [
                "In the Boneyard (not in the manuscript)", "Book · 9 words",
            ])
        #expect(WindowWording.statusParts(book: book, openScene: nil) == ["Book · 9 words"])
    }

    @Test func tooltips() throws {
        let book = try sampleBook()
        #expect(
            WindowWording.currentSceneTooltip(book: book, openScene: SceneID(rawValue: "s1"))
                == "Scene 1: The ferry")
        #expect(WindowWording.currentSceneTooltip(book: book, openScene: nil) == "No scene open")
    }
}
