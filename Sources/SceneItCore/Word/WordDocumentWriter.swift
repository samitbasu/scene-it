import Foundation

/// Writes Export to Word's document where the writer chose, as the export writes a review copy
/// (`ChosenFileWrite`). Only a name ending in `.docx` is written, which nothing of a book's or a
/// review's own is ever named.
public enum WordDocumentWriter {
    public static func write(_ document: Data, to destination: URL, fileSystem: any FileSystem)
        throws(WordExportFailure)
    {
        guard destination.pathExtension.lowercased() == WordExportWording.fileExtension else {
            throw .notAWordDocument
        }
        do throws(ChosenFileFailure) {
            try ChosenFileWrite.write(document, to: destination, fileSystem: fileSystem)
        } catch {
            throw .destination(error)
        }
    }
}
