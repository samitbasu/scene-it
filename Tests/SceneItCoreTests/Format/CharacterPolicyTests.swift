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

    // MARK: Steps 3–7

    @Test func lineEndingsBecomeNewlines() {
        #expect(CharacterPolicy.admit("a\r\nb\rc\nd\r\r\ne").text == "a\nb\nc\nd\n\ne")
    }

    @Test func decomposedAccentsAreComposed() {
        #expect(CharacterPolicy.admit("cafe\u{301}").text == "café")
        #expect(CharacterPolicy.admit("cafe\u{301}").replaced.isEmpty)
        #expect(CharacterPolicy.admit("A\u{30A}").text == "\u{C5}")
        #expect(
            CharacterPolicy.admit("x\u{301}").text == "x[?]", "no precomposed form: the accent is replaced")
    }

    @Test(arguments: [
        ("\u{201C}", "\""), ("\u{201D}", "\""), ("\u{2018}", "'"), ("\u{2019}", "'"), ("\u{2014}", "--"),
        ("\u{2013}", "-"), ("\u{2026}", "..."),
    ])
    func typographicPunctuationIsStraightened(typed: String, stored: String) {
        let admitted = CharacterPolicy.admit("a\(typed)b")
        #expect(admitted.text == "a\(stored)b")
        #expect(admitted.replaced.isEmpty, "no notice: this is normal")
    }

    @Test func aTabIsASpace() {
        #expect(CharacterPolicy.admit("\ta\tb").text == " a b")
    }

    @Test func everyAllowedCharacterIsKeptAndEveryOtherIsReplaced() {
        for value in UInt32(0)...0x2FF {
            guard let scalar = Unicode.Scalar(value), !["\n", "\r", "\t"].contains(scalar) else { continue }
            let admitted = CharacterPolicy.admit(String(scalar))
            let allowed = (0x20...0x7E).contains(value) || (0xA0...0xFF).contains(value)
            #expect(admitted.text == (allowed ? String(scalar) : "[?]"), "U+\(String(value, radix: 16))")
            #expect(admitted.replaced == (allowed ? [] : [scalar]))
        }
    }

    @Test func replacedCharactersAreListedOnceInOrderOfFirstAppearance() {
        let admitted = CharacterPolicy.admit("🌊 α 🌊 \u{0} \u{2028}")
        #expect(admitted.text == "[?] [?] [?] [?] [?]")
        #expect(admitted.replaced == ["🌊", "α", "\u{0}", "\u{2028}"])
        #expect(
            admitted.notice?.payload
                == "Characters Scene It can't store were replaced with [?]: U+1F30A, U+03B1, U+0000, U+2028.")
        #expect(CharacterPolicy.admit("plain").notice == nil)
    }

    @Test func replacementsRecordTheirLine() {
        let admitted = CharacterPolicy.admitLatin1("a\r\nb🌊\rc\nα")
        #expect(
            admitted.replacements == [Replacement(line: 1, scalar: "🌊"), Replacement(line: 3, scalar: "α")])
    }

    @Test func admittedTextIsAFixedPoint() {
        let messy = "“Wait—” 🌊\t cafe\u{301}…\r\n"
        let once = CharacterPolicy.admit(messy).text
        #expect(CharacterPolicy.admit(once).text == once)
        #expect(once.unicodeScalars.allSatisfy { $0 == "\n" || CharacterPolicy.isAllowed($0) })
    }
}
