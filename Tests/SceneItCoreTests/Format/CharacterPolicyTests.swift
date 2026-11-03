import Foundation
import Testing

@testable import SceneItCore

/// Book format §1.2, and `CharacterPolicy.admit` as the editor will use it. Whole files are
/// corpus cases (Tests/Corpus/book/s1.2-*).
@Suite struct CharacterPolicyTests {
    // MARK: Step 1, decoding

    @Test func validUTF8DecodesAsItself() {
        let decoded = BookTextDecoder.decode(Data("café 😀 \u{0}".utf8))
        #expect(decoded.text == "café 😀 \u{0}")
        #expect(decoded.windows1252ByteCount == 0)
    }

    /// Every byte 0x80–0x9F alone, as Windows-1252, and the five undefined ones as C1 controls.
    @Test func bytes0x80To0x9FAreWindows1252() {
        let expected: [UInt32] = [
            0x20AC, 0x81, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039,
            0x0152,
            0x8D, 0x017D, 0x8F, 0x90, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122,
            0x0161, 0x203A, 0x0153, 0x9D, 0x017E, 0x0178,
        ]
        for byte in UInt8(0x80)...0x9F {
            let decoded = BookTextDecoder.decode(Data([UInt8(ascii: "a"), byte]))
            #expect(
                decoded.text.unicodeScalars.map(\.value) == [0x61, expected[Int(byte - 0x80)]], "\(byte)")
            #expect(decoded.windows1252ByteCount == 1)
        }
    }

    @Test func bytes0xA0To0xFFAloneAreLatin1() {
        for byte in UInt8(0xA0)...0xFF {
            let decoded = BookTextDecoder.decode(Data([byte, UInt8(ascii: " ")]))
            #expect(decoded.text.unicodeScalars.first?.value == UInt32(byte))
            #expect(decoded.windows1252ByteCount == 1)
        }
    }

    /// Unicode Table 3-7: overlong forms, surrogates, values above U+10FFFF and truncated
    /// sequences are not well-formed, so each of their bytes falls back on its own.
    @Test(arguments: [
        ([0xC0, 0x80], 2), ([0xC1, 0xBF], 2), ([0xE0, 0x80, 0x80], 3), ([0xED, 0xA0, 0x80], 3),
        ([0xF0, 0x80, 0x80, 0x80], 4), ([0xF4, 0x90, 0x80, 0x80], 4), ([0xF5, 0x80, 0x80, 0x80], 4),
        ([0xE2, 0x82], 2), ([0xF0, 0x9F, 0x8C], 3), ([0x80], 1), ([0xFF], 1),
    ])
    func illFormedSequencesFallBackBytewise(bytes: [UInt8], fallbacks: Int) {
        let decoded = BookTextDecoder.decode(Data(bytes + Array("ok".utf8)))
        #expect(decoded.windows1252ByteCount == fallbacks)
        #expect(decoded.text.unicodeScalars.count == fallbacks + 2)
        #expect(decoded.text.hasSuffix("ok"))
    }

    @Test func wellFormedSequencesAmongBadBytesSurvive() {
        let decoded = BookTextDecoder.decode(Data([0x93] + Array("é😀".utf8) + [0x94]))
        #expect(decoded.text == "\u{201C}é😀\u{201D}")
        #expect(decoded.windows1252ByteCount == 2)
    }

    // MARK: Step 2, the byte-order mark

    @Test func aLeadingByteOrderMarkIsRemovedSilently() {
        let decoded = BookTextDecoder.decode(Data([0xEF, 0xBB, 0xBF] + Array("---".utf8)))
        #expect(decoded.text == "---")
        let parsed = parse(Data([0xEF, 0xBB, 0xBF]) + BookFormat.serialize(Book(title: "T")))
        #expect(parsed.book == Book(title: "T"))
    }

    @Test func aByteOrderMarkElsewhereIsADisallowedCharacter() {
        let admitted = CharacterPolicy.admit("a\u{FEFF}b")
        #expect(admitted.text == "a[?]b")
        #expect(admitted.replaced == ["\u{FEFF}"])
    }

    // MARK: Steps 3–5

    @Test func lineEndingsBecomeNewlines() {
        #expect(CharacterPolicy.admit("a\r\nb\rc\nd\r\r\ne").text == "a\nb\nc\nd\n\ne")
    }

    @Test func aTabIsASpaceSilently() {
        let admitted = CharacterPolicy.admit("\ta\tb")
        #expect(admitted.text == " a b")
        #expect(admitted.notices.isEmpty)
    }

    @Test func composedAndDecomposedAccentsBothBecomeThePlainLetter() {
        let composed = CharacterPolicy.admit("caf\u{E9} \u{C5}")
        let decomposed = CharacterPolicy.admit("cafe\u{301} A\u{30A}")
        #expect(
            Array("cafe\u{301}".unicodeScalars).count == 5 && Array("caf\u{E9}".unicodeScalars).count == 4,
            "precondition: one is decomposed, the other isn't")
        #expect(composed.text == "cafe A")
        #expect(decomposed.text == "cafe A")
        #expect(composed.transliterated == ["\u{E9}", "\u{C5}"])
        #expect(decomposed.transliterated == ["\u{301}", "\u{30A}"])
        #expect(composed.replaced.isEmpty && decomposed.replaced.isEmpty)
    }

    @Test func aCombiningMarkOutsideTheTableIsReplaced() {
        #expect(CharacterPolicy.admit("a\u{304}").text == "a[?]", "a macron isn't in the table")
        #expect(CharacterPolicy.admit("x\u{301}").text == "x", "an acute accent is, whatever it's on")
    }

    @Test(arguments: [
        ("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{2014}", "--"),
        ("\u{2013}", "-"), ("\u{2026}", "..."), ("\u{A0}", " "), ("\u{F1}", "n"), ("\u{E6}", "ae"),
        ("\u{C6}", "AE"), ("\u{DF}", "ss"), ("\u{F8}", "o"), ("\u{FE}", "th"), ("\u{F0}", "d"),
        ("\u{BF}", ""), ("\u{AD}", ""),
    ])
    func theTableSpellsCharactersInASCII(typed: String, stored: String) {
        let admitted = CharacterPolicy.admit("a\(typed)b")
        #expect(admitted.text == "a\(stored)b")
        #expect(admitted.transliterated == Array(typed.unicodeScalars))
        #expect(admitted.replaced.isEmpty)
    }

    /// Every scalar of the Basic Multilingual Plane, and samples beyond it: each comes out as
    /// printable ASCII, from the table if it has an entry and as `[?]` if it hasn't, and the
    /// table's every entry is reached.
    @Test func everyCharacterBecomesPrintableASCII() {
        let astral: [UInt32] = [
            0x1_0000, 0x1_F30A, 0x1_F44D, 0x1_F3FD, 0x2_0000, 0xE_0001, 0xF_FFFD, 0x10_FFFF,
        ]
        var reached: Set<Unicode.Scalar> = []
        var wrong: [String] = []
        var checked = 0
        for value in Array(UInt32(0)...0xFFFF) + astral {
            guard let scalar = Unicode.Scalar(value), !["\n", "\r", "\t"].contains(scalar) else { continue }
            checked += 1
            let admitted = CharacterPolicy.admit(String(scalar))
            let isPrintableASCII = admitted.text.utf8.allSatisfy { (0x20...0x7E).contains($0) }
            let isRight: Bool
            if CharacterPolicy.isAllowed(scalar) {
                isRight = admitted.text == String(scalar) && admitted.notices.isEmpty
            } else if let spelling = Transliteration.table[scalar] {
                reached.insert(scalar)
                isRight =
                    admitted.text == spelling && admitted.transliterated == [scalar]
                    && admitted.replaced.isEmpty
            } else {
                isRight =
                    admitted.text == CharacterPolicy.placeholder && admitted.replaced == [scalar]
                    && admitted.transliterated.isEmpty
            }
            if !(isPrintableASCII && isRight) {
                wrong.append("U+\(String(value, radix: 16, uppercase: true))")
            }
        }
        #expect(
            checked == 0x10000 - 0x800 - 3 + astral.count, "precondition: every scalar but the surrogates")
        #expect(wrong.isEmpty, "\(wrong.prefix(20))")
        #expect(reached == Set(Transliteration.table.keys), "every entry is exercised")
    }

    @Test func noTableEntryIsAllowedOrSpelledOutsidePrintableASCII() {
        for (scalar, spelling) in Transliteration.table {
            #expect(!CharacterPolicy.isAdmitted(scalar))
            #expect(spelling.utf8.allSatisfy { (0x20...0x7E).contains($0) })
            #expect(spelling.count <= 4)
        }
    }

    @Test func changedCharactersAreListedOnceInOrderOfFirstAppearance() {
        let admitted = CharacterPolicy.admit("🌊 α é 🌊 \u{0} “ \u{2028} é")
        #expect(admitted.text == "[?] [?] e [?] [?] \" [?] e")
        #expect(admitted.replaced == ["🌊", "α", "\u{0}", "\u{2028}"])
        #expect(admitted.transliterated == ["é", "“"])
        #expect(
            admitted.notices.map(\.payload) == [
                "Characters outside plain ASCII were changed to their nearest ASCII: U+00E9, U+201C.",
                "Characters with no ASCII form were replaced with [?]: U+1F30A, U+03B1, U+0000, U+2028.",
            ])
        #expect(CharacterPolicy.admit("plain").notices.isEmpty)
    }

    @Test func changesRecordTheirLineAndKind() {
        let admitted = CharacterPolicy.admitASCII("a\r\nb🌊\rc\né")
        #expect(
            admitted.changes == [
                CharacterChange(line: 1, scalar: "🌊", kind: .replaced),
                CharacterChange(line: 3, scalar: "é", kind: .transliterated),
            ])
    }

    @Test func surrogatesFromAppKitAreReplaced() {
        var unit: unichar = 0xD800
        let lone = NSString(characters: &unit, length: 1) as String
        #expect(CharacterPolicy.admittedInput("a\(lone)b") == "a[?]b")
    }

    @Test func linesAndInputFieldsAreAdmittedToo() {
        #expect(CharacterPolicy.admittedLine("Ren\u{E9}e\u{2028}\u{201C}x\u{201D}") == "Renee \"x\"")
        #expect(CharacterPolicy.admitted("Zo\u{EB}\u{2029}Na\u{EF}ve") == "Zoe\nNaive")
        #expect(CharacterPolicy.admittedInput("\u{FFFC}Jos\u{E9}") == "Jose")
    }
}

/// Admitted text is printable ASCII and admitting it again changes nothing, for random text
/// over every kind of input the policy sees.
@Suite struct CharacterPolicyPropertyTests {
    private static let pieces: [String] = [
        "a", "Z", " ", "\n", "\r\n", "\r", "\t", "\u{2028}", "\u{85}", "\u{0}", "\u{7F}", "\u{9D}", "\u{A0}",
        "\u{E9}", "e\u{301}", "A\u{30A}", "x\u{304}", "\u{201C}", "\u{2014}", "\u{2026}", "\u{1F30A}",
        "\u{1F44D}\u{1F3FD}", "\u{65E5}", "\u{3A9}", "\u{FEFF}", "\u{FFFC}", "[?]", "\\", "*", "--",
    ]

    @Test(arguments: 1...20)
    func admittedTextIsASCIIAndAFixedPoint(seed: UInt64) {
        var rng = SplitMix64(seed: seed)
        var wrong: [String] = []
        for _ in 0..<200 {
            let text = (0..<Int.random(in: 0...12, using: &rng)).map { _ in
                Self.pieces.randomElement(using: &rng)!
            }.joined()
            for admit in [
                CharacterPolicy.admitted, CharacterPolicy.admittedLine, CharacterPolicy.admittedInput,
            ] {
                let once = admit(text)
                let isASCII = once.utf8.allSatisfy { $0 == 0x0A || (0x20...0x7E).contains($0) }
                if !isASCII || admit(once) != once || !CharacterPolicy.admit(once).notices.isEmpty {
                    wrong.append(text.debugDescription)
                }
            }
            if CharacterPolicy.admittedLine(text).contains("\n") { wrong.append(text.debugDescription) }
        }
        #expect(wrong.isEmpty, "\(wrong.prefix(10))")
    }
}
