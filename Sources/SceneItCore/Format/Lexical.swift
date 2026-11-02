/// The line-level vocabulary of book format §1.3, §1.4 and §4.1, over admitted text (one
/// Latin-1 byte per character).
enum Lexical {
    static let hash = UInt8(ascii: "#")
    static let dash = UInt8(ascii: "-")
    static let star = UInt8(ascii: "*")
    static let tilde = UInt8(ascii: "~")
    static let colon = UInt8(ascii: ":")
    static let pipe = UInt8(ascii: "|")
    static let comma = UInt8(ascii: ",")
    static let quote = UInt8(ascii: "\"")
    static let openBracket = UInt8(ascii: "[")
    static let closeBracket = UInt8(ascii: "]")
    static let space = Latin1.space
    static let backslash = Latin1.backslash
    static let newline = Latin1.newline

    /// §1.3: leading spaces and unescaped trailing spaces removed, and a trailing escape
    /// whose space an editor stripped given back its space.
    static func trim(_ raw: ArraySlice<UInt8>) -> [UInt8] {
        var start = raw.startIndex
        var end = raw.endIndex
        while start < end, raw[start] == space {
            start += 1
        }
        while end > start, raw[end - 1] == space, !isOdd(backslashesBefore(end - 1, in: raw, from: start)) {
            end -= 1
        }
        var line = Array(raw[start..<end])
        if isOdd(backslashesBefore(line.endIndex, in: line[...], from: 0)) {
            line.append(space)
        }
        return line
    }

    private static func backslashesBefore(_ index: Int, in bytes: ArraySlice<UInt8>, from start: Int) -> Int {
        var count = 0
        var position = index
        while position > start, bytes[position - 1] == backslash {
            count += 1
            position -= 1
        }
        return count
    }

    private static func isOdd(_ count: Int) -> Bool {
        count % 2 == 1
    }

    static func isASCIIPunctuation(_ byte: UInt8) -> Bool {
        (0x21...0x2F).contains(byte) || (0x3A...0x40).contains(byte) || (0x5B...0x60).contains(byte)
            || (0x7B...0x7E).contains(byte)
    }

    /// Whether `\` followed by `byte` stands for `byte` itself (§3.3).
    static func isEscapable(_ byte: UInt8) -> Bool {
        isASCIIPunctuation(byte) || byte == space
    }

    static func isLetter(_ byte: UInt8) -> Bool {
        (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }

    static func lowercased(_ bytes: some Sequence<UInt8>) -> [UInt8] {
        bytes.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }
    }

    /// Case-insensitive comparison with an ASCII word.
    static func equalsIgnoringCase(_ bytes: some Collection<UInt8>, _ word: String) -> Bool {
        lowercased(bytes) == Array(word.utf8)
    }

    static func withoutLeadingSpaces(_ bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        bytes.drop { $0 == space }
    }

    /// Spaces removed from both ends, with no regard for escapes: for fields whose valid
    /// values never end in a space.
    static func strippingSpaces(_ bytes: ArraySlice<UInt8>) -> ArraySlice<UInt8> {
        var result = withoutLeadingSpaces(bytes)
        while result.last == space {
            result.removeLast()
        }
        return result
    }

    /// §1.4. A trimmed line is blank, heading-shaped (1–6 `#` then a space or the end), or
    /// anything else.
    static func kind(of line: [UInt8]) -> LineKind {
        guard !line.isEmpty else { return .blank }
        let level = line.prefix { $0 == hash }.count
        guard (1...6).contains(level), level == line.count || line[level] == space else { return .text }
        return .heading(level: level, name: withoutLeadingSpaces(line[level...]))
    }

    /// `key: value` with an ASCII-letter key (§1.5, §2.2), the key lowercased and the value
    /// with its leading spaces removed; `nil` if the line isn't key-shaped.
    static func keyValue(_ line: [UInt8]) -> (key: String, value: ArraySlice<UInt8>)? {
        let key = line.prefix(while: isLetter)
        guard !key.isEmpty, key.count < line.count, line[key.count] == colon else { return nil }
        return (
            String(decoding: lowercased(key), as: UTF8.self), withoutLeadingSpaces(line[(key.count + 1)...])
        )
    }

    /// §4.1, reading: `\n` is a newline, `\` before ASCII punctuation or a space is that
    /// character, and any other `\` is itself.
    static func fieldUnescaped(_ bytes: ArraySlice<UInt8>) -> [UInt8] {
        var result: [UInt8] = []
        result.reserveCapacity(bytes.count)
        var index = bytes.startIndex
        while index < bytes.endIndex {
            let byte = bytes[index]
            if byte == backslash, index + 1 < bytes.endIndex {
                let next = bytes[index + 1]
                if next == UInt8(ascii: "n") {
                    result.append(newline)
                    index += 2
                    continue
                }
                if isEscapable(next) {
                    result.append(next)
                    index += 2
                    continue
                }
            }
            result.append(byte)
            index += 1
        }
        return result
    }

    /// Whether a trimmed line starts an entry: `-` then a space, or `-` alone (§4.1).
    static func isEntryStart(_ line: [UInt8]) -> Bool {
        line.first == dash && (line.count == 1 || line[1] == space)
    }

    /// An entry line's content: what follows its `-` and spaces.
    static func entryContent(_ line: [UInt8]) -> ArraySlice<UInt8> {
        withoutLeadingSpaces(line.dropFirst())
    }

    /// An id as scene and comment ids are written: 1–64 of `A–Z a–z 0–9 _ -` (§2.2).
    static func isValidID(_ bytes: some Collection<UInt8>) -> Bool {
        (1...64).contains(bytes.count)
            && bytes.allSatisfy {
                isLetter($0) || (0x30...0x39).contains($0) || $0 == dash || $0 == UInt8(ascii: "_")
            }
    }

    static func string(_ bytes: some Collection<UInt8>) -> String {
        Latin1.string(ArraySlice(bytes))
    }
}

enum LineKind: Equatable {
    case blank
    case heading(level: Int, name: ArraySlice<UInt8>)
    case text
}

/// How a free-text field is escaped when written (§4.1, §2.2).
struct FieldEscaping: OptionSet {
    let rawValue: Int

    /// `"` as `\"`, inside a quote.
    static let quoteMarks = FieldEscaping(rawValue: 1)
    /// `,` as `\,`, in a tag.
    static let commas = FieldEscaping(rawValue: 2)
    /// A leading `#` as `\#`, in a tag.
    static let leadingHash = FieldEscaping(rawValue: 4)
    /// A space at the first or last position as `\␠`, in an unquoted field.
    static let edgeSpaces = FieldEscaping(rawValue: 8)

    static let freeText: FieldEscaping = [.edgeSpaces]
    static let tag: FieldEscaping = [.edgeSpaces, .commas, .leadingHash]
    static let quoted: FieldEscaping = [.quoteMarks]

    func escape(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        let scalars = Array(text.unicodeScalars)
        for (index, scalar) in scalars.enumerated() {
            switch scalar {
            case "\\": result.append(contentsOf: "\\\\".unicodeScalars)
            case "\n": result.append(contentsOf: "\\n".unicodeScalars)
            case "\"" where contains(.quoteMarks), "," where contains(.commas):
                result.append("\\")
                result.append(scalar)
            case "#" where index == 0 && contains(.leadingHash):
                result.append(contentsOf: "\\#".unicodeScalars)
            case " " where (index == 0 || index == scalars.count - 1) && contains(.edgeSpaces):
                result.append(contentsOf: "\\ ".unicodeScalars)
            default: result.append(scalar)
            }
        }
        return String(result)
    }
}
