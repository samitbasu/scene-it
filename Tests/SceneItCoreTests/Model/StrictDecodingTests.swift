import Foundation
import Testing

@testable import SceneItCore

/// Each case corrupts the rich fixture in one place and checks the error names that place.
@Suite struct StrictDecodingTests {
    private func corrupt(_ target: String, _ replacement: String) throws -> BookDecodingError {
        try decodingError(try Fixture.text("rich-book").replacingFirst(target, with: replacement))
    }

    @Test func unknownColorIsRejected() throws {
        let error = try corrupt(#""color" : "purple""#, #""color" : "purpel""#)
        #expect(
            error.description
                == #"scenes[0].body[0][3].color: unknown value "purpel"; "#
                + "expected one of: black, purple, red, blue, green, gray, pink")
    }

    @Test func unknownHighlightIsRejected() throws {
        let error = try corrupt(#""highlight" : "green""#, #""highlight" : "black""#)
        #expect(
            error.description
                == #"scenes[0].body[2][1].highlight: unknown value "black"; "#
                + "expected one of: purple, red, blue, green, gray, pink")
    }

    @Test func unknownSettingsEnumValueIsRejected() throws {
        let error = try corrupt(#""scenesView" : "lightTable""#, #""scenesView" : "grid""#)
        #expect(
            error.description
                == #"settings.scenesView: unknown value "grid"; expected one of: cards, lightTable"#)
    }

    @Test(arguments: [
        (#""text" : "Rain.""#, #""text" : "Rain.", "underline" : true"#, "scenes[1].body[0][0].underline"),
        (#""tags" : ["#, #""mood" : 1, "tags" : ["#, "boneyard[0].mood"),
        (#""zoom" : 1.25"#, #""zoom" : 1.25, "theme" : "dark""#, "settings.theme"),
        (#""title" : "My Novel""#, #""title" : "My Novel", "author" : "me""#, "author"),
        (#""created" : "2025"#, #""edited" : true, "created" : "2025"#, "boneyard[0].comments[0].edited"),
    ])
    func unknownKeysAreRejectedAtEveryLevel(target: String, replacement: String, location: String) throws {
        let error = try corrupt(target, replacement)
        #expect(error.location == location)
        #expect(error.reason.hasPrefix("unknown key "))
    }

    @Test func unknownKeyMessageListsTheValidKeys() throws {
        let error = try corrupt(#""zoom" : 1.25"#, #""zoom" : 1.25, "theme" : "dark""#)
        #expect(
            error.description
                == #"settings.theme: unknown key "theme"; "#
                + "expected one of: rate, rightPanel, rightPanelOpen, scenesView, voice, zoom")
    }

    @Test func wrongTypeIsRejected() throws {
        let error = try corrupt(#""zoom" : 1.25"#, #""zoom" : "big""#)
        #expect(error.description == "settings.zoom: expected a number")
    }

    @Test func arrayWhereAStringBelongsIsRejected() throws {
        let error = try corrupt(#""title" : "My Novel""#, #""title" : ["My Novel"]"#)
        #expect(error.description == "title: expected a string")
    }

    @Test func documentThatIsNotAnObjectIsRejected() throws {
        #expect(try decodingError("[]").description == "expected an object")
    }

    @Test func stringWhereAFlagBelongsIsRejected() throws {
        let error = try corrupt(#""bold" : true"#, #""bold" : "yes""#)
        #expect(error.description == "scenes[0].body[2][0].bold: expected true or false")
    }

    @Test(arguments: [2, 0])
    func unsupportedFormatIsRejected(format: Int) throws {
        let error = try corrupt(#""format" : 1"#, #""format" : \#(format)"#)
        #expect(error.description == "format: format \(format) is not supported; this version reads format 1")
    }

    @Test func unsupportedFormatIsReportedBeforeUnknownKeys() throws {
        let error = try corrupt(#""format" : 1"#, #""format" : 2, "chapters" : []"#)
        #expect(error.location == "format")
    }

    @Test func missingRequiredKeyIsRejected() throws {
        let error = try corrupt(#""rate" : 0.5,"#, "")
        #expect(error.description == "settings.rate: missing")
    }

    @Test func nullIsNotAnAbsentAttribute() throws {
        let error = try corrupt(#""color" : "gray","#, #""color" : null,"#)
        #expect(error.description == "scenes[0].notes[0][0].color: expected a string, found null")
    }

    @Test func nullVoiceIsRejected() throws {
        let error = try corrupt(#""voice" : "com.apple.voice.premium.en-US.Zoe""#, #""voice" : null"#)
        #expect(error.location == "settings.voice")
    }

    @Test func falseFlagIsRejected() throws {
        let error = try corrupt(#""bold" : true"#, #""bold" : false"#)
        #expect(
            error.description
                == "scenes[0].body[2][0].bold: must be true when present; omit it instead of false")
    }

    @Test func emptyCommentListIsRejected() throws {
        let error = try corrupt(
            """
            "comments" : [
                          "01JC4K0000000000000000C003"
                        ],
            """, #""comments" : [],"#)
        #expect(
            error.description
                == "boneyard[0].body[0][0].comments: must not be empty when present; omit it instead")
    }

    @Test func repeatedCommentIDInARunIsRejected() throws {
        let error = try corrupt(
            #""01JC4K0000000000000000C003""#, #""01JC4K0000000000000000C003", "01JC4K0000000000000000C003""#)
        #expect(
            error.description == "boneyard[0].body[0][0].comments: lists the same comment id more than once")
    }

    @Test(arguments: [3.5, 0.25])
    func zoomOutOfRangeIsRejected(zoom: Double) throws {
        let error = try corrupt(#""zoom" : 1.25"#, #""zoom" : \#(zoom)"#)
        #expect(error.description == "settings.zoom: \(zoom) is outside the allowed range 0.5...3.0")
    }

    @Test(arguments: [
        "2026-10-31T20:54:00Z",
        "2026-10-31T20:54:00.250-07:00",
        "2026-10-31 20:54:00-07:00",
        "2026-02-29T20:54:00-07:00",
        "2026-10-31T24:00:00-07:00",
        "2026-10-31T20:54:00-24:00",
    ])
    func malformedDateIsRejected(date: String) throws {
        let error = try corrupt(#""modified" : "2026-10-31T20:54:00-07:00""#, #""modified" : "\#(date)""#)
        #expect(
            error.description
                == #"scenes[0].modified: "\#(date)" is not a date of the form 2026-10-31T20:54:00-07:00 "#
                + "(whole seconds, numeric UTC offset)")
    }

    @Test func invalidJSONIsRejected() throws {
        let error = try decodingError(#"{"format": 1,"#)
        #expect(error.path.isEmpty)
        #expect(!error.reason.isEmpty)
    }
}
