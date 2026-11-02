/// Which characters manuscript text treats specially, decided once for the model and the
/// editors.
extension Character {
    /// A line or paragraph separator (`\n`, `\r`, `\r\n`, U+000B, U+000C, U+0085, U+2028,
    /// U+2029). It ends a paragraph, and is invalid inside a run or a title.
    public var isLineBreak: Bool {
        isNewline
    }

    /// U+FFFC OBJECT REPLACEMENT CHARACTER, an attachment's placeholder. Text is stripped of
    /// it, since manuscripts are text only (decision 0016).
    public var isObjectReplacement: Bool {
        unicodeScalars.contains("\u{FFFC}")
    }
}
