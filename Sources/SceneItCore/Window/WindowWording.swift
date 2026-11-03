import Foundation

/// Every string the main window shows, in one place so the owner can review the wording as a
/// whole.
public enum WindowWording {
    // MARK: Start state (ADR 0021)

    public static let noBookOpen = "No book is open."
    public static let recentBooks = "Recent Books"
    public static let noRecentBooks = "No recent books"

    // MARK: Toolbar (PLAN §4.1)

    public static let undo = "Undo"
    public static let redo = "Redo"
    public static let zoomOut = "Zoom Out"
    public static let zoomIn = "Zoom In"
    public static let print = "Print"
    public static let exportToWord = "Export to Word"
    public static let fileACopy = "File a copy…"

    public static func zoom(_ zoom: Zoom) -> String {
        (Double(zoom)).formatted(.percent.precision(.fractionLength(0)))
    }

    public static let boneyard = "Boneyard"
    public static let untitledScene = "Untitled scene"

    /// The breadcrumb's parts, left to right: "My Novel › 1. The ferry", "My Novel › Boneyard ›
    /// Title" for a scene in the Boneyard, or just the book's title with no scene open.
    public static func breadcrumb(bookTitle: String, _ location: SceneLocation) -> [String] {
        switch location {
        case .story(let scene, let number, _): [bookTitle, "\(number). \(sceneName(scene))"]
        case .boneyard(let scene): [bookTitle, boneyard, sceneName(scene)]
        case .noScene: [bookTitle]
        }
    }

    public static func sceneName(_ scene: BookScene) -> String {
        scene.title.text.isEmpty ? untitledScene : scene.title.text
    }

    // MARK: Rail (PLAN §4.2)

    public static let boneyardBadge = "B"

    public static func railName(_ item: WindowMode) -> String {
        switch item {
        case .page: "Current scene"
        case .scenes: "Scenes"
        case .search: "Search"
        case .fileCabinet: "File Cabinet"
        }
    }

    /// The Current scene icon's tooltip: the scene's number and title.
    public static func currentSceneTooltip(_ location: SceneLocation) -> String {
        switch location {
        case .story(let scene, let number, _): "Scene \(number): \(sceneName(scene))"
        case .boneyard(let scene): "\(boneyard): \(sceneName(scene))"
        case .noScene: noSceneOpen
        }
    }

    public static let closeSheet = "Close"
    public static let sheetComingLater = "Coming in a later version."
    /// The temporary scene list in the Scenes sheet, until #28.
    public static let addScene = "Add Scene"

    // MARK: Page (PLAN §4.3, ADR 0015)

    public static let titleLabel = "Title"
    public static let noSceneOpen = "No scene open"

    // MARK: Formatting (PLAN §6.2, §11)

    public static let formatMenu = "Format"
    public static let textColor = "Text Color"
    public static let highlight = "Highlight"
    public static let noHighlight = "None"
    public static let showPalette = "Show the palette"
    public static let readAloud = "Read aloud"
    /// The bar's tooltip while the page doesn't have the focus.
    public static let clickInThePageToFormat = "Click in the page to format"

    public static func style(_ style: TextStyle) -> String {
        switch style {
        case .bold: "Bold"
        case .italic: "Italic"
        case .strike: "Strikethrough"
        }
    }

    public static func paletteName(_ color: PaletteColor) -> String {
        color.rawValue.capitalized
    }

    /// The command's item in the Format menu: a style, or a color in its submenu.
    public static func menuItem(_ command: FormattingCommand) -> String {
        switch command {
        case .toggle(let style): self.style(style)
        case .textColor(let color): paletteName(color)
        case .highlight(let highlight?): paletteName(PaletteColor(highlight))
        case .highlight(nil): noHighlight
        }
    }

    /// The command's name after Undo and Redo in the Edit menu.
    public static func undoName(_ command: FormattingCommand) -> String {
        switch command {
        case .toggle(let style): self.style(style)
        case .textColor: textColor
        case .highlight: highlight
        }
    }

    // MARK: Right panel (PLAN §4.4)

    public static func tab(_ tab: RightPanelTab) -> String {
        switch tab {
        case .comments: "Comments"
        case .notes: "Notes"
        case .tags: "Tags"
        case .errors: ErrorsWording.tabName
        }
    }

    public static let hidePanel = "Hide the panel"
    public static let showPanel = "Show the panel"
    public static let toggleRightPanel = "Toggle Right Panel"

    // MARK: Status bar (PLAN §4.5)

    /// The status bar's left-hand parts. The save state follows them (`StoreWording.status`).
    public static func statusParts(
        _ location: SceneLocation, sceneWords: WordCount, bookWords: WordCount
    ) -> [String] {
        let bookPart = "Book · \(words(bookWords))"
        switch location {
        case .story(_, let number, let count):
            return ["Scene \(number) of \(count) · \(words(sceneWords))", bookPart]
        case .boneyard:
            return ["In the Boneyard (not in the manuscript)", bookPart]
        case .noScene:
            return [bookPart]
        }
    }

    public static func words(_ count: WordCount) -> String {
        count.words == 1 ? "1 word" : "\(count.words.formatted()) words"
    }
}
