/// How text that isn't printable ASCII is spelled in it (ADR 0028), as data. Book format §1.2's
/// transliteration table is the source of truth; `TransliterationTableTests` checks that this is
/// the same table. A character with no entry becomes `CharacterPolicy.placeholder`.
public enum Transliteration {
    /// Raised with every change to the table: the same file can read differently under two
    /// versions.
    public static let version = 1

    public static let table: [Unicode.Scalar: String] = [
        "\u{00A0}": " ", "\u{00A1}": "", "\u{00A6}": "|", "\u{00A9}": "(c)", "\u{00AA}": "a",
        "\u{00AB}": "\"", "\u{00AD}": "", "\u{00AE}": "(R)", "\u{00B1}": "+/-", "\u{00B4}": "'",
        "\u{00BA}": "o", "\u{00BB}": "\"", "\u{00BF}": "", "\u{00C0}": "A", "\u{00C1}": "A", "\u{00C2}": "A",
        "\u{00C3}": "A", "\u{00C4}": "A", "\u{00C5}": "A", "\u{00C6}": "AE", "\u{00C7}": "C", "\u{00C8}": "E",
        "\u{00C9}": "E", "\u{00CA}": "E", "\u{00CB}": "E", "\u{00CC}": "I", "\u{00CD}": "I", "\u{00CE}": "I",
        "\u{00CF}": "I", "\u{00D0}": "D", "\u{00D1}": "N", "\u{00D2}": "O", "\u{00D3}": "O", "\u{00D4}": "O",
        "\u{00D5}": "O", "\u{00D6}": "O", "\u{00D7}": "x", "\u{00D8}": "O", "\u{00D9}": "U", "\u{00DA}": "U",
        "\u{00DB}": "U", "\u{00DC}": "U", "\u{00DD}": "Y", "\u{00DE}": "TH", "\u{00DF}": "ss",
        "\u{00E0}": "a", "\u{00E1}": "a", "\u{00E2}": "a", "\u{00E3}": "a", "\u{00E4}": "a", "\u{00E5}": "a",
        "\u{00E6}": "ae", "\u{00E7}": "c", "\u{00E8}": "e", "\u{00E9}": "e", "\u{00EA}": "e", "\u{00EB}": "e",
        "\u{00EC}": "i", "\u{00ED}": "i", "\u{00EE}": "i", "\u{00EF}": "i", "\u{00F0}": "d", "\u{00F1}": "n",
        "\u{00F2}": "o", "\u{00F3}": "o", "\u{00F4}": "o", "\u{00F5}": "o", "\u{00F6}": "o", "\u{00F7}": "/",
        "\u{00F8}": "o", "\u{00F9}": "u", "\u{00FA}": "u", "\u{00FB}": "u", "\u{00FC}": "u", "\u{00FD}": "y",
        "\u{00FE}": "th", "\u{00FF}": "y", "\u{0152}": "OE", "\u{0153}": "oe", "\u{0160}": "S",
        "\u{0161}": "s", "\u{0178}": "Y", "\u{017D}": "Z", "\u{017E}": "z", "\u{0192}": "f", "\u{02C6}": "^",
        "\u{02DC}": "~", "\u{0300}": "", "\u{0301}": "", "\u{0302}": "", "\u{0303}": "", "\u{0308}": "",
        "\u{030A}": "", "\u{030C}": "", "\u{0327}": "", "\u{2013}": "-", "\u{2014}": "--", "\u{2018}": "'",
        "\u{2019}": "'", "\u{201A}": "'", "\u{201C}": "\"", "\u{201D}": "\"", "\u{201E}": "\"",
        "\u{2022}": "*", "\u{2026}": "...", "\u{2039}": "'", "\u{203A}": "'", "\u{2122}": "(TM)",
    ]
}
