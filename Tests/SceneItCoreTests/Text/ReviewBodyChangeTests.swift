import AppKit
import Testing

@testable import SceneItCore

/// From the adversarial review of #72: batched edits and lone surrogates.
@MainActor @Suite struct ReviewBodyChangeTests {
    private static let pieces = [
        "a", "word ", "é", "\n", "\r\n", "\r", "\u{2028}", "\u{2029}", "\u{85}", "\u{0B}", "\u{0C}",
        "\u{FFFC}", "\u{1F30A}", "", "\n\n", "x\ny",
    ]

    private static func random(_ count: Int, using random: inout SplitMix64) -> String {
        (0..<count).map { _ in pieces[Int(random.next() % UInt64(pieces.count))] }.joined()
    }

    /// Several replacements in one editing batch (as `ManuscriptTextView.replace` and Replace
    /// All do): the storage reports the union of the edits as the edited range.
    @Test func batchedEditsUnionRange() throws {
        var random = SplitMix64(seed: 72)
        for round in 0..<20000 {
            let before = Self.random(Int(random.next() % 14), using: &random)
            let text = NSTextStorage(string: before, attributes: ParagraphRole.body.typingAttributes)
            let body = RunCodec.body(from: text)
            var ranges: [NSRange] = []
            var cursor = 0
            for _ in 0..<Int(1 + random.next() % 3) {
                guard cursor <= text.length else { break }
                let start = cursor + Int(random.next() % UInt64(text.length - cursor + 1))
                let end = start + Int(random.next() % UInt64(text.length - start + 1))
                ranges.append(NSRange(location: start, length: end - start))
                cursor = end + 1
            }
            var lo = Int.max
            var hi = 0
            var shift = 0
            var finalRanges: [NSRange] = []
            text.beginEditing()
            var inserted: [String] = []
            for _ in ranges { inserted.append(Self.random(Int(random.next() % 3), using: &random)) }
            for (range, s) in zip(ranges, inserted).reversed() {
                text.replaceCharacters(
                    in: range,
                    with: NSAttributedString(string: s, attributes: ParagraphRole.body.typingAttributes))
            }
            for (range, s) in zip(ranges, inserted) {
                let loc = range.location + shift
                finalRanges.append(NSRange(location: loc, length: (s as NSString).length))
                shift += (s as NSString).length - range.length
            }
            text.endEditing()
            for r in finalRanges {
                lo = min(lo, r.location)
                hi = max(hi, r.upperBound)
            }
            let edited = NSRange(location: lo, length: hi - lo)
            let change = try #require(
                RunCodec.bodyChange(edited: edited, in: text, linesBefore: BodyChange.lineCount(of: body)),
                "round \(round)")
            #expect(
                change.applied(to: body) == RunCodec.body(from: text),
                "round \(round) \(before.debugDescription) \(ranges) \(inserted)")
        }
    }

    @Test func loneSurrogateThenBreaks() throws {
        var unit: unichar = 0xD800
        let lone = NSString(characters: &unit, length: 1) as String
        for prefix in ["", "a\n", "a\r"] {
            for suffix in ["", "\nb", "\r\nb", "\u{2028}b"] {
                let text = NSTextStorage(
                    string: prefix + lone + suffix, attributes: ParagraphRole.body.typingAttributes)
                let body = RunCodec.body(from: text)
                for position in 0...text.length {
                    for insert in ["\n", "x", "\r\n", ""] {
                        let copy = NSTextStorage(attributedString: text)
                        copy.replaceCharacters(
                            in: NSRange(location: position, length: 0),
                            with: NSAttributedString(
                                string: insert, attributes: ParagraphRole.body.typingAttributes))
                        let edited = NSRange(location: position, length: (insert as NSString).length)
                        if let change = RunCodec.bodyChange(
                            edited: edited, in: copy, linesBefore: BodyChange.lineCount(of: body))
                        {
                            #expect(
                                change.applied(to: body) == RunCodec.body(from: copy),
                                "\(prefix.debugDescription) \(suffix.debugDescription) at \(position) insert \(insert.debugDescription)"
                            )
                        }
                    }
                }
            }
        }
    }
}
