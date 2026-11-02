import Foundation
import Testing

@testable import SceneItCore

@Suite @MainActor
struct ErrorsWordingTests {
    @Test func theBannerIsForTheReasonsAboutTheBooksContent() throws {
        try withTemporaryDirectory { directory in
            let url = try package(holding: damaged(try draft(1)), in: directory)
            guard case .readOnly(_, let repaired) = try BookPackage.open(at: url, defaults: fixedDefaults)
            else {
                Issue.record("precondition: the damaged book opens read-only")
                return
            }
            #expect(ErrorsWording.banner(for: repaired)?.offersMakeEditable == true)
        }
        #expect(ErrorsWording.banner(for: .newerFormat(FormatVersion(3)))?.offersMakeEditable == false)
        #expect(ErrorsWording.banner(for: .openElsewhere) == nil)
    }

    @Test func everyReasonHasASentence() {
        let fields: [FieldProblem] = [
            .notAField, .unknownKey, .repeatedKey, .badID, .idInUse, .badDate, .badFormat, .otherFormat,
        ]
        let reasons: [ErrorReason] =
            EntryProblem.allCases.flatMap { [.comment($0), .mark($0)] }
            + fields.flatMap { [.metadata($0), .frontMatter($0)] } + [.line, .notice, .readsNow]
        #expect(reasons.map(ErrorsWording.reason).allSatisfy { !$0.isEmpty && $0.hasSuffix(".") })
    }
}
