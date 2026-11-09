/// Typographic smartening for what a review puts out (review format §5.3): straight quotes become
/// curly, `--` a dash and `...` an ellipsis. Stored text is ASCII (ADR 0028), so this runs on
/// output only, and `Transliteration.table` turns any result back into exactly its input.
///
/// A quote's direction is decided on a whole unit (a title, a paragraph, a comment's text), so it
/// doesn't depend on where a piece of the unit starts or ends; dashes and ellipses are replaced
/// within each piece. The lists the rules read are data, defined once, for every output.
public enum Typography {
    /// What a quote opens after, besides a space, a line break, an opening quote or nothing.
    static let openers: Set<Unicode.Scalar> = ["(", "[", "{", "-", "/"]
    /// The words an apostrophe at an opening position elides: `'Tis`, `rock 'n' roll`.
    static let elisions: Set<String> = ["em", "tis", "twas", "til", "cause", "n"]

    static let openingDouble: Unicode.Scalar = "\u{201C}"
    static let closingDouble: Unicode.Scalar = "\u{201D}"
    static let openingSingle: Unicode.Scalar = "\u{2018}"
    static let apostrophe: Unicode.Scalar = "\u{2019}"
    static let dash = "\u{2014}"
    static let ellipsis = "\u{2026}"

    /// `text` smartened as one unit, not split into pieces.
    public static func smartened(_ text: String) -> String {
        let unit = SmartUnit(text)
        return unit.piece(0..<unit.count)
    }
}

/// One unit of output text (review format §5.3) with its quotes turned, ready to be cut into
/// pieces. Offsets count Unicode scalars, which for stored text are its characters.
struct SmartUnit {
    private let scalars: [Unicode.Scalar]

    init(_ text: String) {
        scalars = Self.turningQuotes(Array(text.unicodeScalars))
    }

    var count: Int { scalars.count }

    /// The characters in `range`, with runs of `-` and `.` in it replaced. A run is never joined
    /// across the range's ends, so a `--` split between two pieces stays as it is.
    func piece(_ range: Range<Int>) -> String {
        var result = ""
        var index = range.lowerBound
        while index < range.upperBound {
            let scalar = scalars[index]
            guard scalar == "-" || scalar == "." else {
                result.unicodeScalars.append(scalar)
                index += 1
                continue
            }
            var end = index + 1
            while end < range.upperBound, scalars[end] == scalar { end += 1 }
            result += Self.replacing(run: end - index, of: scalar)
            index = end
        }
        return result
    }

    private static func replacing(run length: Int, of scalar: Unicode.Scalar) -> String {
        if scalar == "-" {
            return length == 2 ? Typography.dash : String(repeating: "-", count: length)
        }
        guard length >= 3 else { return String(repeating: ".", count: length) }
        return String(repeating: Typography.ellipsis, count: length / 3)
            + String(repeating: ".", count: length % 3)
    }

    private static func turningQuotes(_ unit: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var turned = unit
        for index in unit.indices where unit[index] == "\"" || unit[index] == "'" {
            let previous = index > 0 ? turned[index - 1] : nil
            let next = index + 1 < unit.count ? unit[index + 1] : nil
            let opening = opens(after: previous) && next.map { !isSpace($0) } == true
            if unit[index] == "\"" {
                turned[index] = opening ? Typography.openingDouble : Typography.closingDouble
            } else if let previous, let next, isLetterOrDigit(previous), isLetterOrDigit(next) {
                turned[index] = Typography.apostrophe
            } else if opening {
                let elides = next.map(isDigit) == true || elidesWord(in: unit, after: index)
                turned[index] = elides ? Typography.apostrophe : Typography.openingSingle
            } else {
                turned[index] = Typography.apostrophe
            }
        }
        return turned
    }

    private static func opens(after previous: Unicode.Scalar?) -> Bool {
        guard let previous else { return true }
        return isSpace(previous) || Typography.openers.contains(previous)
            || previous == Typography.openingDouble || previous == Typography.openingSingle
    }

    /// Whether the letters right after `index` are one of the elided words, and end there.
    private static func elidesWord(in unit: [Unicode.Scalar], after index: Int) -> Bool {
        var word = ""
        var next = index + 1
        while next < unit.count, isLetter(unit[next]) {
            word.unicodeScalars.append(unit[next])
            next += 1
        }
        return Typography.elisions.contains(word.lowercased())
    }

    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\n"
    }

    private static func isLetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    private static func isDigit(_ scalar: Unicode.Scalar) -> Bool {
        ("0"..."9").contains(scalar)
    }

    private static func isLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        isLetter(scalar) || isDigit(scalar)
    }
}
