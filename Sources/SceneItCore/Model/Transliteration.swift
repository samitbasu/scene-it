/// How text that isn't printable ASCII is spelled in it (ADR 0028), as data. Book format §1.2's
/// transliteration table is the source of truth; `TransliterationTableTests` checks that this is
/// the same table. A character with no entry becomes `CharacterPolicy.placeholder`.
public enum Transliteration {
    /// Raised with every change to the table: the same file can read differently under two
    /// versions.
    public static let version = 1

    /// A character's ASCII spelling, and whether reading it in a file is a repair the writer
    /// is told of (book format §5.3). Typing and pasting are never noticed.
    public enum Spelling: Hashable, Sendable {
        /// Typographic punctuation and the no-break space, which other editors write freely.
        case silent(String)
        case noticed(String)

        public var ascii: String {
            switch self {
            case .silent(let ascii), .noticed(let ascii): ascii
            }
        }
    }

    public static let table: [Unicode.Scalar: Spelling] = [
        "\u{00A0}": .silent(" "), "\u{00A1}": .noticed(""), "\u{00A6}": .noticed("|"),
        "\u{00A9}": .noticed("(c)"), "\u{00AA}": .noticed("a"), "\u{00AB}": .noticed("\""),
        "\u{00AD}": .noticed(""), "\u{00AE}": .noticed("(R)"), "\u{00B1}": .noticed("+/-"),
        "\u{00B4}": .noticed("'"), "\u{00BA}": .noticed("o"), "\u{00BB}": .noticed("\""),
        "\u{00BF}": .noticed(""), "\u{00C0}": .noticed("A"), "\u{00C1}": .noticed("A"),
        "\u{00C2}": .noticed("A"), "\u{00C3}": .noticed("A"), "\u{00C4}": .noticed("A"),
        "\u{00C5}": .noticed("A"), "\u{00C6}": .noticed("AE"), "\u{00C7}": .noticed("C"),
        "\u{00C8}": .noticed("E"), "\u{00C9}": .noticed("E"), "\u{00CA}": .noticed("E"),
        "\u{00CB}": .noticed("E"), "\u{00CC}": .noticed("I"), "\u{00CD}": .noticed("I"),
        "\u{00CE}": .noticed("I"), "\u{00CF}": .noticed("I"), "\u{00D0}": .noticed("D"),
        "\u{00D1}": .noticed("N"), "\u{00D2}": .noticed("O"), "\u{00D3}": .noticed("O"),
        "\u{00D4}": .noticed("O"), "\u{00D5}": .noticed("O"), "\u{00D6}": .noticed("O"),
        "\u{00D7}": .noticed("x"), "\u{00D8}": .noticed("O"), "\u{00D9}": .noticed("U"),
        "\u{00DA}": .noticed("U"), "\u{00DB}": .noticed("U"), "\u{00DC}": .noticed("U"),
        "\u{00DD}": .noticed("Y"), "\u{00DE}": .noticed("TH"), "\u{00DF}": .noticed("ss"),
        "\u{00E0}": .noticed("a"), "\u{00E1}": .noticed("a"), "\u{00E2}": .noticed("a"),
        "\u{00E3}": .noticed("a"), "\u{00E4}": .noticed("a"), "\u{00E5}": .noticed("a"),
        "\u{00E6}": .noticed("ae"), "\u{00E7}": .noticed("c"), "\u{00E8}": .noticed("e"),
        "\u{00E9}": .noticed("e"), "\u{00EA}": .noticed("e"), "\u{00EB}": .noticed("e"),
        "\u{00EC}": .noticed("i"), "\u{00ED}": .noticed("i"), "\u{00EE}": .noticed("i"),
        "\u{00EF}": .noticed("i"), "\u{00F0}": .noticed("d"), "\u{00F1}": .noticed("n"),
        "\u{00F2}": .noticed("o"), "\u{00F3}": .noticed("o"), "\u{00F4}": .noticed("o"),
        "\u{00F5}": .noticed("o"), "\u{00F6}": .noticed("o"), "\u{00F7}": .noticed("/"),
        "\u{00F8}": .noticed("o"), "\u{00F9}": .noticed("u"), "\u{00FA}": .noticed("u"),
        "\u{00FB}": .noticed("u"), "\u{00FC}": .noticed("u"), "\u{00FD}": .noticed("y"),
        "\u{00FE}": .noticed("th"), "\u{00FF}": .noticed("y"), "\u{0152}": .noticed("OE"),
        "\u{0153}": .noticed("oe"), "\u{0160}": .noticed("S"), "\u{0161}": .noticed("s"),
        "\u{0178}": .noticed("Y"), "\u{017D}": .noticed("Z"), "\u{017E}": .noticed("z"),
        "\u{0192}": .noticed("f"), "\u{02C6}": .noticed("^"), "\u{02DC}": .noticed("~"),
        "\u{0300}": .noticed(""), "\u{0301}": .noticed(""), "\u{0302}": .noticed(""),
        "\u{0303}": .noticed(""), "\u{0308}": .noticed(""), "\u{030A}": .noticed(""),
        "\u{030C}": .noticed(""), "\u{0327}": .noticed(""), "\u{2013}": .silent("-"),
        "\u{2014}": .silent("--"), "\u{2018}": .silent("'"), "\u{2019}": .silent("'"),
        "\u{201A}": .silent("'"), "\u{201C}": .silent("\""), "\u{201D}": .silent("\""),
        "\u{201E}": .silent("\""), "\u{2022}": .noticed("*"), "\u{2026}": .silent("..."),
        "\u{2039}": .silent("'"), "\u{203A}": .silent("'"), "\u{2122}": .noticed("(TM)"),
    ]
}
