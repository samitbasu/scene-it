import Foundation

/// The characters manuscript text may hold, and how any other text is made to fit
/// (ADR 0028, book format §1.2). The parser applies it to a whole file; the editors apply
/// the same `admit` to what's typed and pasted.
///
/// Admitted text holds only printable ASCII (U+0020–U+007E) and `\n`, so every character is
/// one byte, one UTF-16 unit and one `Character`.
public enum CharacterPolicy {
    /// What stands in for a character that has no entry in the transliteration table.
    public static let placeholder = "[?]"

    /// Whether text may hold `scalar`. `\n` separates lines and paragraphs, so it's
    /// admitted, but it isn't allowed inside a line.
    public static func isAllowed(_ scalar: Unicode.Scalar) -> Bool {
        (0x20...0x7E).contains(scalar.value)
    }

    /// Whether admitted text may hold `scalar`: an allowed character, or the `\n` between
    /// lines.
    public static func isAdmitted(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\n" || isAllowed(scalar)
    }

    /// `text` with §1.2's steps 3, 4 and 7 applied: `\r\n` and `\r` become `\n`, a tab becomes a
    /// space, a character in the transliteration table becomes its ASCII, and every other
    /// disallowed character becomes `[?]`.
    public static func admit(_ text: String) -> AdmittedText {
        let scanned = scan(text, .inPlace)
        return AdmittedText(text: ASCII.string(scanned.bytes[...]), changes: scanned.changes)
    }

    /// `text` admitted, for a field that may hold line breaks (written `\n`): comment text,
    /// the book's title. Each line break (`Character.isLineBreak`) becomes
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

    /// `tags` each admitted as one line (a line break becomes a space, as in a title), without
    /// the empty ones. Search joins a scene's tags with `\n`, so that stays an exact separator.
    public static func admittedTags(_ tags: [String]) -> [String] {
        tags.map(admittedLine).filter { !$0.isEmpty }
    }

    /// A whole file with §1.2's steps 3–5 applied, as UTF-8: the change step 7 will
    /// make to each other disallowed character is recorded with its line. Step 7 itself waits
    /// for `transliterated`, token by token once the lines are read, so what the table writes
    /// is always literal text and never markup.
    static func fileText(_ text: String) -> ScannedText {
        scan(text, .perToken)
    }

    /// §1.2 step 7 on one token of a file (`fileText`), whose `\n`s are kept.
    static func transliterated(_ bytes: some Collection<UInt8>) -> [UInt8] {
        if bytes.allSatisfy({ $0 == ASCII.newline || (0x20...0x7E).contains($0) }) { return Array(bytes) }
        return ASCII.bytes(admit(String(decoding: bytes, as: UTF8.self)).text)
    }

    private enum Transliterating {
        case inPlace
        /// Each character the table changes is left as its UTF-8.
        case perToken
    }

    /// Reads scalar by scalar, so a decomposed `é` is an `e` and a combining accent, and the
    /// table removes the accent.
    private static func scan(_ text: String, _ transliterating: Transliterating) -> ScannedText {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)
        var changes: [CharacterChange] = []
        var line = 0
        var afterCarriageReturn = false
        for scalar in text.unicodeScalars {
            if afterCarriageReturn {
                afterCarriageReturn = false
                if scalar == "\n" { continue }
            }
            switch scalar {
            case "\r", "\n":
                bytes.append(ASCII.newline)
                line += 1
                afterCarriageReturn = scalar == "\r"
            case "\t":
                bytes.append(ASCII.space)
            case _ where isAllowed(scalar):
                bytes.append(UInt8(scalar.value))
            default:
                let (spelling, kind) = change(of: scalar)
                switch transliterating {
                case .inPlace: bytes += spelling.utf8
                case .perToken: bytes += scalar.utf8
                }
                changes.append(CharacterChange(line: line, scalar: scalar, kind: kind))
            }
        }
        return ScannedText(bytes: bytes, changes: changes)
    }

    private static func change(of scalar: Unicode.Scalar) -> (String, CharacterChange.Kind) {
        switch Transliteration.table[scalar] {
        case .silent(let ascii): (ascii, .straightened)
        case .noticed(let ascii): (ascii, .transliterated)
        case nil: (placeholder, .replaced)
        }
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
    /// The characters the transliteration table spelled in ASCII silently (typographic
    /// punctuation), each once, in order of first appearance.
    public let straightened: [Unicode.Scalar]
    /// The characters the table spelled in ASCII with a notice, likewise.
    public let transliterated: [Unicode.Scalar]
    /// The characters that became `[?]`, likewise.
    public let replaced: [Unicode.Scalar]

    init(text: String, changes: [CharacterChange]) {
        self.text = text
        straightened = CharacterChange.distinct(changes, .straightened)
        transliterated = CharacterChange.distinct(changes, .transliterated)
        replaced = CharacterChange.distinct(changes, .replaced)
    }

    /// The notices the parser records for these changes: one per noticed kind.
    public var notices: [RepairNotice] {
        RepairNotice.characters(transliterated: transliterated, replaced: replaced)
    }
}

/// A file's text as `CharacterPolicy.fileText` leaves it, as UTF-8, which is how the parser
/// reads it.
struct ScannedText {
    var bytes: [UInt8]
    /// In text order.
    var changes: [CharacterChange]
}

/// A character `CharacterPolicy` changed, how, and the line (counted from 0) it was on.
struct CharacterChange: Hashable {
    enum Kind: Hashable {
        /// Spelled in ASCII by the transliteration table, silently.
        case straightened
        /// Spelled in ASCII by the table, with a notice.
        case transliterated
        /// Replaced with `[?]`.
        case replaced
    }

    let line: Int
    let scalar: Unicode.Scalar
    let kind: Kind

    /// The characters of `changes` changed as `kind`, each once, in order of first appearance.
    static func distinct(_ changes: [CharacterChange], _ kind: Kind) -> [Unicode.Scalar] {
        CharacterPolicy.distinct(changes.filter { $0.kind == kind }.map(\.scalar))
    }
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
    /// Characters the transliteration table spelled in ASCII.
    case transliteratedCharacters([Unicode.Scalar])
    /// Characters with no entry in the table, which became `[?]`.
    case replacedCharacters([Unicode.Scalar])
    case missingTitle
    case missingFormat
    case otherFormat(Int)
    case missingSceneID(given: SceneID)
    case duplicateSceneID(SceneID, given: SceneID)
    case missingModified(setTo: Timestamp)
    /// A filed copy's section in `Archive/index.md` (book format §8).
    case missingFiledDate(setTo: CalendarDay)
    /// A tag held a line break (an escaped `\n`), which became a space (ADR 0033).
    case lineBreaksInTags(TagOwner)

    public enum TagOwner: Hashable, Sendable {
        case scene
        case filedCopy
    }

    public var entry: ErrorEntry {
        ErrorEntry(.notice, payload)
    }

    public var payload: String {
        switch self {
        case .invalidUTF8(let count):
            "Some of this file wasn't valid UTF-8: \(count) byte(s) were read as Windows-1252 characters."
        case .transliteratedCharacters(let scalars):
            "Characters outside plain ASCII were changed to their nearest ASCII: "
                + scalars.map(Self.codePoint).joined(separator: ", ") + "."
        case .replacedCharacters(let scalars):
            "Characters with no ASCII form were replaced with [?]: "
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
        case .lineBreaksInTags(.scene): "This scene's tags had line breaks, so they were changed to spaces."
        case .lineBreaksInTags(.filedCopy):
            "This filed copy's tags had line breaks, so they were changed to spaces."
        }
    }

    private static func codePoint(_ scalar: Unicode.Scalar) -> String {
        let hex = String(scalar.value, radix: 16, uppercase: true)
        return "U+" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex
    }
}

extension RepairNotice {
    /// One notice per kind of change `CharacterPolicy` made, if it made any.
    static func characters(transliterated: [Unicode.Scalar], replaced: [Unicode.Scalar]) -> [RepairNotice] {
        (transliterated.isEmpty ? [] : [.transliteratedCharacters(transliterated)])
            + (replaced.isEmpty ? [] : [.replacedCharacters(replaced)])
    }

    /// The notice for `tags` as the file spelled them, if storing them changes them. The
    /// file's characters are already admitted, so only a line break can.
    static func lineBreaks(in tags: [String], of owner: TagOwner) -> [RepairNotice] {
        CharacterPolicy.admittedTags(tags) != tags ? [.lineBreaksInTags(owner)] : []
    }

    /// The notices for the characters one part of the file had changed, if any.
    static func characters(_ changes: [CharacterChange]) -> [RepairNotice] {
        characters(
            transliterated: CharacterChange.distinct(changes, .transliterated),
            replaced: CharacterChange.distinct(changes, .replaced))
    }
}

/// ASCII code units: what admitted text is made of.
enum ASCII {
    static let newline = UInt8(ascii: "\n")
    static let space = UInt8(ascii: " ")
    static let backslash = UInt8(ascii: "\\")

    /// The code units of text `CharacterPolicy` admitted.
    static func bytes(_ admitted: String) -> [UInt8] {
        Array(admitted.utf8)
    }

    static func string(_ bytes: ArraySlice<UInt8>) -> String {
        String(decoding: bytes, as: UTF8.self)
    }
}
