import Foundation

/// The characters manuscript text may hold, and how any other text is made to fit
/// (ADR 0022, book format §1.2). The parser applies it to a whole file; the editor applies
/// the same `admit` to typing and pasting.
///
/// Admitted text holds only printable Latin-1 (U+0020–U+007E, U+00A0–U+00FF) and `\n`, so
/// every character is one Unicode scalar, one `Character` and one byte of Latin-1.
public enum CharacterPolicy {
    /// What stands in for a character Scene It can't store.
    public static let placeholder = "[?]"

    /// Typographic punctuation that's straightened rather than stored.
    public static let straightened: [Unicode.Scalar: String] = [
        "\u{201C}": "\"", "\u{201D}": "\"",
        "\u{2018}": "'", "\u{2019}": "'",
        "\u{2014}": "--", "\u{2013}": "-",
        "\u{2026}": "...",
    ]

    /// Whether text may hold `scalar`. `\n` separates lines and paragraphs, so it's
    /// admitted, but it isn't allowed inside a line.
    public static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        (0x20...0x7E).contains(scalar.value) || (0xA0...0xFF).contains(scalar.value)
    }

    /// Whether admitted text may hold `scalar`: an allowed character, or the `\n` between
    /// lines.
    public static func isAdmitted(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\n" || isAllowed(scalar)
    }

    /// `text` with §1.2's steps 3–7 applied: `\r\n` and `\r` become `\n`, then NFC, then the
    /// punctuation table, then a tab becomes a space, then every other disallowed character
    /// becomes `[?]`.
    public static func admit(_ text: String) -> AdmittedText {
        let admitted = admitLatin1(text)
        return AdmittedText(
            text: Latin1.string(admitted.bytes[...]),
            replaced: distinct(admitted.replacements.map(\.scalar)))
    }

    /// `text` admitted, for a field that may hold line breaks (written `\n`): tags,
    /// comment text, the book's title. Each line break (`Character.isLineBreak`) becomes
    /// `\n` first.
    public static func admitted(_ text: String) -> String {
        guard !text.unicodeScalars.allSatisfy(isAdmitted) else { return text }
        return admit(String(text.map { $0.isLineBreak ? "\n" : $0 })).text
    }

    /// What an editor keeps of text typed or pasted into it: `admitted`, without the object
    /// replacement characters attachments sit on (decision 0016).
    public static func admittedInput(_ text: String) -> String {
        admitted(text.contains(where: \.isObjectReplacement) ? text.filter { !$0.isObjectReplacement } : text)
    }

    /// `text` admitted as one line: each line break (`Character.isLineBreak`) becomes a
    /// space first. For run text and scene titles.
    public static func admittedLine(_ text: String) -> String {
        guard !text.unicodeScalars.allSatisfy(isAllowed) else { return text }
        return admit(String(text.map { $0.isLineBreak ? " " : $0 })).text
    }

    /// `text` in NFC. Text whose UTF-8 has no byte from 0xCC up holds no combining mark
    /// (U+0300 onwards) and is returned as it is, without the cost of normalizing.
    public static func normalized(_ text: String) -> String {
        text.utf8.allSatisfy { $0 < 0xCC } ? text : text.precomposedStringWithCanonicalMapping
    }

    /// `admit`, as Latin-1 bytes, recording the line each replaced character was on.
    static func admitLatin1(_ text: String) -> Latin1Text {
        let normalized = normalized(text)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(normalized.utf8.count)
        var replacements: [Replacement] = []
        var line = 0
        var afterCarriageReturn = false
        for scalar in normalized.unicodeScalars {
            if afterCarriageReturn {
                afterCarriageReturn = false
                if scalar == "\n" { continue }
            }
            switch scalar {
            case "\r", "\n":
                bytes.append(Latin1.newline)
                line += 1
                afterCarriageReturn = scalar == "\r"
            case "\t":
                bytes.append(Latin1.space)
            case _ where isAllowed(scalar):
                bytes.append(UInt8(scalar.value))
            case _ where straightened[scalar] != nil:
                bytes += straightened[scalar, default: ""].utf8
            default:
                bytes += placeholder.utf8
                replacements.append(Replacement(line: line, scalar: scalar))
            }
        }
        return Latin1Text(bytes: bytes, replacements: replacements)
    }

    /// `scalars` without repeats, in order of first appearance.
    static func distinct(_ scalars: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var seen: Set<Unicode.Scalar> = []
        return scalars.filter { seen.insert($0).inserted }
    }
}

/// Text as `CharacterPolicy.admit` leaves it.
public struct AdmittedText: Hashable, Sendable {
    public let text: String
    /// The characters that became `[?]`, each once, in order of first appearance.
    public let replaced: [Unicode.Scalar]

    /// The notice the parser records for these replacements; `nil` when there were none.
    public var notice: RepairNotice? {
        replaced.isEmpty ? nil : .replacedCharacters(replaced)
    }
}

/// Admitted text as Latin-1 code units, which is how the parser reads it.
struct Latin1Text {
    var bytes: [UInt8]
    /// In text order.
    var replacements: [Replacement]
}

/// A character `CharacterPolicy` replaced with `[?]`, and the line (counted from 0) it was on.
struct Replacement: Hashable {
    let line: Int
    let scalar: Unicode.Scalar
}

/// Bytes to text, before `CharacterPolicy` (book format §1.2, steps 1 and 2).
public enum BookTextDecoder {
    /// Decodes UTF-8. A byte that isn't part of a well-formed sequence decodes on its own as
    /// its Windows-1252 character, and a byte-order mark at the very start is removed.
    public static func decode(_ bytes: Data) -> DecodedText {
        var text: String
        var fallbackBytes = 0
        if let valid = String(validating: bytes, as: UTF8.self) {
            text = valid
        } else {
            (text, fallbackBytes) = decodeTolerantly(Array(bytes))
        }
        if text.unicodeScalars.first == "\u{FEFF}" {
            text.unicodeScalars.removeFirst()
        }
        return DecodedText(text: text, windows1252ByteCount: fallbackBytes)
    }

    private static func decodeTolerantly(_ bytes: [UInt8]) -> (String, Int) {
        var scalars = String.UnicodeScalarView()
        var fallbackBytes = 0
        var index = 0
        while index < bytes.count {
            let length = wellFormedLength(bytes, at: index)
            if length == 0 {
                scalars.append(windows1252(bytes[index]))
                fallbackBytes += 1
                index += 1
            } else {
                if let scalar = String(decoding: bytes[index..<index + length], as: UTF8.self).unicodeScalars
                    .first
                {
                    scalars.append(scalar)
                }
                index += length
            }
        }
        return (String(scalars), fallbackBytes)
    }

    /// The length of the well-formed UTF-8 sequence starting at `index` (Unicode Table 3-7),
    /// or 0 if there isn't one.
    static func wellFormedLength(_ bytes: [UInt8], at index: Int) -> Int {
        let lead = bytes[index]
        let second: ClosedRange<UInt8>
        let length: Int
        switch lead {
        case 0x00...0x7F: return 1
        case 0xC2...0xDF: (second, length) = (0x80...0xBF, 2)
        case 0xE0: (second, length) = (0xA0...0xBF, 3)
        case 0xE1...0xEC, 0xEE...0xEF: (second, length) = (0x80...0xBF, 3)
        case 0xED: (second, length) = (0x80...0x9F, 3)
        case 0xF0: (second, length) = (0x90...0xBF, 4)
        case 0xF1...0xF3: (second, length) = (0x80...0xBF, 4)
        case 0xF4: (second, length) = (0x80...0x8F, 4)
        default: return 0
        }
        guard index + length <= bytes.count, second.contains(bytes[index + 1]) else { return 0 }
        for offset in 2..<length where !(0x80...0xBF).contains(bytes[index + offset]) {
            return 0
        }
        return length
    }

    /// Windows-1252's character for `byte`. The five bytes 1252 leaves undefined decode as
    /// the C1 control of the same value.
    static func windows1252(_ byte: UInt8) -> Unicode.Scalar {
        guard (0x80...0x9F).contains(byte) else { return Unicode.Scalar(byte) }
        return Unicode.Scalar(windows1252High[Int(byte - 0x80)]) ?? Unicode.Scalar(byte)
    }

    private static let windows1252High: [UInt32] = [
        0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021,
        0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
        0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
        0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
    ]
}

public struct DecodedText: Hashable, Sendable {
    public let text: String
    /// How many bytes weren't valid UTF-8; each was read as a Windows-1252 character.
    public let windows1252ByteCount: Int
}

/// A repair the parser made with nothing left to keep verbatim (book format §5.3). It's
/// stored as a `[notice]` error entry until the writer dismisses it.
public enum RepairNotice: Hashable, Sendable {
    case invalidUTF8(byteCount: Int)
    case replacedCharacters([Unicode.Scalar])
    case missingTitle
    case missingFormat
    case otherFormat(Int)
    case missingSceneID(given: SceneID)
    case duplicateSceneID(SceneID, given: SceneID)
    case missingModified(setTo: Timestamp)
    /// A filed copy's section in `Archive/index.md` (book format §8).
    case missingFiledDate(setTo: CalendarDay)

    public var entry: ErrorEntry {
        ErrorEntry(.notice, payload)
    }

    public var payload: String {
        switch self {
        case .invalidUTF8(let count):
            "Some of this file wasn't valid UTF-8: \(count) byte(s) were read as Windows-1252 characters."
        case .replacedCharacters(let scalars):
            "Characters Scene It can't store were replaced with [?]: "
                + scalars.map(Self.codePoint).joined(separator: ", ") + "."
        case .missingTitle: "The book had no title, so it was called \"\(BookFormat.untitled)\"."
        case .missingFormat: "The file had no format line; it was read as format 2."
        case .otherFormat(let number):
            "The file says format \(number); this version of Scene It reads format \(FormatVersion.current)."
        case .missingSceneID(let given): "This scene had no id, so it was given \(given)."
        case .duplicateSceneID(let old, let given):
            "This scene's id \(old) was already used by an earlier scene, so it was given \(given)."
        case .missingModified(let timestamp):
            "This scene had no modified date, so it was set to \(timestamp)."
        case .missingFiledDate(let day):
            "This filed copy had no filed date, so it was set to \(day)."
        }
    }

    private static func codePoint(_ scalar: Unicode.Scalar) -> String {
        let hex = String(scalar.value, radix: 16, uppercase: true)
        return "U+" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
    }
}

/// Latin-1 code units: what admitted text is made of.
enum Latin1 {
    static let newline = UInt8(ascii: "\n")
    static let space = UInt8(ascii: " ")
    static let backslash = UInt8(ascii: "\\")

    /// The code units of text `CharacterPolicy` admitted, every scalar of which is Latin-1.
    static func bytes(_ admitted: String) -> [UInt8] {
        admitted.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }
    }

    static func string(_ bytes: ArraySlice<UInt8>) -> String {
        if bytes.allSatisfy({ $0 < 0x80 }) {
            return String(decoding: bytes, as: UTF8.self)
        }
        var scalars = String.UnicodeScalarView()
        for byte in bytes {
            scalars.append(Unicode.Scalar(byte))
        }
        return String(scalars)
    }
}
