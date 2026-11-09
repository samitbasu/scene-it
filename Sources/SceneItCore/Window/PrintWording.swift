/// Every string Print shows (PLAN §10.1, §11), in one place so the owner can review the wording
/// as a whole. Chosen by default while the owner was away (#35): see the PR.
public enum PrintWording {
    public static let menuItem = "Print…"

    // MARK: The print dialog's accessory

    public static let layoutLabel = "Layout"
    public static let rangeLabel = "Range"

    public static func title(_ layout: PrintLayout) -> String {
        switch layout {
        case .textOnly: "Text only"
        case .withComments: "Text with comments"
        }
    }

    public static func detail(_ layout: PrintLayout) -> String {
        switch layout {
        case .textOnly: "Portrait · manuscript format"
        case .withComments: "Landscape · comments in a margin column beside the lines they refer to"
        }
    }

    public static func title(_ range: PrintRange) -> String {
        switch range {
        case .thisScene: "This scene"
        case .wholeManuscript: "Whole manuscript"
        }
    }

    /// The print job's name, which Save as PDF also offers as the file's: the book's title, and
    /// the scene's when printing one.
    public static func jobTitle(book: String, scene: BookScene?) -> String {
        ([book] + (scene.map { [WindowWording.sceneName($0)] } ?? [])).filter { !$0.isEmpty }
            .joined(separator: " – ")
    }
}
