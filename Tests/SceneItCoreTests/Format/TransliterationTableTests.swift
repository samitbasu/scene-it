import Foundation
import Testing

@testable import SceneItCore

/// Book format §1.2's transliteration table is the source of truth; `Transliteration.table` must
/// hold exactly its entries.
@Suite struct TransliterationTableTests {
    private static let specURL = URL(filePath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "docs/format/book-format.md")

    /// The section from its heading to the next heading.
    private static func section() throws -> [Substring] {
        let spec = try String(contentsOf: specURL, encoding: .utf8)
        let lines = spec.split(separator: "\n", omittingEmptySubsequences: false)
        let heading = "#### The transliteration table (version \(Transliteration.version))"
        let start = try #require(
            lines.firstIndex { $0 == heading }, "the spec has the table, at this version")
        let end = lines[(start + 1)...].firstIndex { $0.hasPrefix("#") } ?? lines.endIndex
        return Array(lines[(start + 1)..<end])
    }

    /// `| U+00E9 | é | `e` | noticed |` rows: the code point, what it becomes, and whether
    /// a file holding it gets a notice.
    private static func specTable() throws -> [Unicode.Scalar: Transliteration.Spelling] {
        var table: [Unicode.Scalar: Transliteration.Spelling] = [:]
        for line in try section() where line.hasPrefix("| U+") {
            let cells = line.replacing("\\|", with: "\u{0}").split(separator: "|").map {
                $0.trimmingCharacters(in: .whitespaces).replacing("\u{0}", with: "|")
            }
            try #require(cells.count == 4, "a row has four cells: \(line)")
            let value = try #require(UInt32(cells[0].dropFirst(2), radix: 16), "\(line)")
            let scalar = try #require(Unicode.Scalar(value))
            #expect(table[scalar] == nil, "U+\(cells[0]) is listed once")
            let ascii = try becomes(cells[2])
            switch cells[3] {
            case "silent": table[scalar] = .silent(ascii)
            case "noticed": table[scalar] = .noticed(ascii)
            default: Issue.record("a notice cell is silent or noticed: \(line)")
            }
        }
        return table
    }

    private static func becomes(_ cell: String) throws -> String {
        switch cell {
        case "*(removed)*": return ""
        case "␠": return " "
        default:
            try #require(cell.hasPrefix("`") && cell.hasSuffix("`") && cell.count > 2, "a code span: \(cell)")
            return String(cell.dropFirst().dropLast())
        }
    }

    /// The characters the section says are deliberately left out: `(U+00A2)` and so on.
    private static func specUnmapped() throws -> Set<Unicode.Scalar> {
        let line = try #require(try section().first { $0.contains("deliberately not in the table") })
        let values = line.matches(of: /\(U\+([0-9A-F]{4})\)/).compactMap { UInt32($0.output.1, radix: 16) }
        return Set(values.compactMap(Unicode.Scalar.init))
    }

    @Test func theCodeHoldsTheSpecsTable() throws {
        let spec = try Self.specTable()
        #expect(spec.count > 100, "precondition: the whole table was read")
        #expect(Transliteration.table == spec)
        for scalar in Set(spec.keys).symmetricDifference(Transliteration.table.keys) {
            Issue.record("U+\(String(scalar.value, radix: 16, uppercase: true)) is in one table only")
        }
    }

    /// Every character of Latin-1 and Windows-1252 beyond ASCII is either in the table or
    /// listed as deliberately left out, never both and never neither.
    @Test func everyLatin1AndWindows1252CharacterIsDecidedOnce() throws {
        let unmapped = try Self.specUnmapped()
        #expect(unmapped.count > 10, "precondition: the list was read")
        let latin1 = (UInt32(0xA0)...0xFF).compactMap(Unicode.Scalar.init)
        let windows1252 = (UInt8(0x80)...0x9F).map(BookTextDecoder.windows1252).filter { $0.value > 0xFF }
        #expect(windows1252.count == 27, "precondition: 1252 defines 27 of the 32")
        for scalar in latin1 + windows1252 {
            let label = "U+\(String(scalar.value, radix: 16, uppercase: true))"
            #expect((Transliteration.table[scalar] != nil) != unmapped.contains(scalar), "\(label)")
        }
        #expect(unmapped.allSatisfy { latin1.contains($0) || windows1252.contains($0) })
    }
}
