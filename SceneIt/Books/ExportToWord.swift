import SceneItCore

/// Export to Word… (PLAN §10.2) for the open scene, from the File menu. It puts out the scene as it
/// is now, saved or not, and works on a read-only book or review.
extension BookController {
    /// The shown book and its open scene, while there's one to export: a filed copy's, while one
    /// shows over the book (PLAN §7.5).
    var wordExportScene: (book: AppOpenBook, scene: BookScene)? {
        guard let book = store.shown, let scene = book.book.scene(book.openScene) else { return nil }
        return (book, scene)
    }

    /// The save panel asks where, and the store writes the document there. `nil` if the panel was
    /// cancelled or no scene is open.
    @discardableResult
    func exportToWord() async -> WordExportResult? {
        guard let (book, scene) = wordExportScene,
            let url = await wordDestination.choose(
                WordExportWording.defaultFileName(scene: scene, of: book.document))
        else { return nil }
        return await store.exportToWord(of: book, scene: scene.id, to: url)
    }
}

extension SaveDestination {
    static let wordPanel = savePanel(
        title: WordExportWording.panelTitle, prompt: WordExportWording.panelPrompt,
        fileExtension: WordExportWording.fileExtension)
}
