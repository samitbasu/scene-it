import SceneItCore
import UniformTypeIdentifiers

extension UTType {
    static let sceneItBook = UTType(exportedAs: SceneItCore.bookTypeIdentifier)
    /// What Review Book… offers: a review copy or a review file, both Markdown (ADR 0029).
    static let reviewCopy = UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
}
