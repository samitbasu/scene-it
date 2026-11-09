import Foundation

/// The exported document's `word/styles.xml` (ADR 0045, 0047): the body's style, which is the
/// default, and Word's built-in Heading 1 for the title, both in the page's fonts and sizes (PLAN
/// §10.2). The body is double-spaced with the page's first-line indent; the title is single-spaced,
/// not indented and black, where Word's own Heading 1 is blue. With comments (ADR 0048), also
/// Word's style for their text.
enum WordStyles {
    /// Word recognises its built-in heading by this id and the name "heading 1".
    static let headingID = "Heading1"
    static let bodyID = "Normal"

    /// WordprocessingML's measures: half-points for type, twentieths of a point for indents, and
    /// 240ths of a line for "auto" line spacing.
    static func halfPoints(_ role: ParagraphRole) -> Int {
        Int(role.pointSize * 2)
    }

    static let firstLineIndent = Int(ParagraphRole.firstLineIndent * 20)
    static let singleSpacing = 240
    static let doubleSpacing = 2 * singleSpacing

    /// Word recognises its built-in style for comments' text by this id and the name
    /// "annotation text".
    static let commentID = "CommentText"
    /// Word's own size for comments' text, 10 pt.
    static let commentHalfPoints = 20

    /// The styles, with the comments' when the document has comments.
    static func xml(for parts: [WordDocument.Part]) -> String {
        parts.contains(.comments) ? withComments : plain
    }

    private static let plain = xml(addingStyles: "")

    /// The comments' paragraphs are Word's "annotation text": single-spaced, not indented, 10 pt.
    private static let withComments = xml(
        addingStyles:
            #"<w:style w:type="paragraph" w:styleId="\#(commentID)"><w:name w:val="annotation text"/>"#
            + #"<w:basedOn w:val="\#(bodyID)"/><w:uiPriority w:val="99"/>"#
            + #"<w:pPr>\#(spacing(singleSpacing))<w:ind w:firstLine="0"/></w:pPr>"#
            + #"<w:rPr><w:sz w:val="\#(commentHalfPoints)"/><w:szCs w:val="\#(commentHalfPoints)"/></w:rPr>"#
            + "</w:style>")

    private static func spacing(_ line: Int) -> String {
        #"<w:spacing w:before="0" w:after="0" w:line="\#(line)" w:lineRule="auto"/>"#
    }

    private static func xml(addingStyles extra: String) -> String {
        let font = ParagraphRole.fontFamily
        let fonts =
            #"<w:rFonts w:ascii="\#(font)" w:hAnsi="\#(font)" w:eastAsia="\#(font)" w:cs="\#(font)"/>"#
        func size(_ role: ParagraphRole) -> String {
            #"<w:sz w:val="\#(halfPoints(role))"/><w:szCs w:val="\#(halfPoints(role))"/>"#
        }
        return #"""
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <w:styles xmlns:w="\#(WordDocument.Namespace.word)">\#
            <w:docDefaults><w:rPrDefault><w:rPr>\#(fonts)\#(size(.body))</w:rPr></w:rPrDefault>\#
            <w:pPrDefault><w:pPr>\#(spacing(singleSpacing))</w:pPr></w:pPrDefault></w:docDefaults>\#
            <w:style w:type="paragraph" w:default="1" w:styleId="\#(bodyID)"><w:name w:val="Normal"/><w:qFormat/>\#
            <w:pPr>\#(spacing(doubleSpacing))<w:ind w:firstLine="\#(firstLineIndent)"/></w:pPr>\#
            <w:rPr>\#(fonts)\#(size(.body))</w:rPr></w:style>\#
            <w:style w:type="paragraph" w:styleId="\#(headingID)"><w:name w:val="heading 1"/>\#
            <w:basedOn w:val="\#(bodyID)"/><w:next w:val="\#(bodyID)"/><w:uiPriority w:val="9"/><w:qFormat/>\#
            <w:pPr><w:keepNext/><w:keepLines/>\#(spacing(singleSpacing))<w:ind w:firstLine="0"/>\#
            <w:outlineLvl w:val="0"/></w:pPr>\#
            <w:rPr>\#(fonts)<w:b/><w:bCs/><w:color w:val="000000"/>\#(size(.title))</w:rPr></w:style>\#
            \#(extra)</w:styles>
            """#
    }
}
