import XCTest
@testable import OpenTypeless

final class DictionaryCorrectionEngineTests: XCTestCase {
    func testCorrectsMultiWordNearMatchFromDictionary() {
        let entries = [DictionaryEntry(text: "Claude Code")]

        let corrected = DictionaryCorrectionEngine.apply(
            to: "please open cloud code and keep going",
            entries: entries
        )

        XCTAssertEqual(corrected, "please open Claude Code and keep going")
    }

    func testCorrectsConcatenatedNearMatchFromDictionary() {
        let entries = [DictionaryEntry(text: "Claude Code")]

        let corrected = DictionaryCorrectionEngine.apply(
            to: "please open cloudcode and keep going",
            entries: entries
        )

        XCTAssertEqual(corrected, "please open Claude Code and keep going")
    }

    func testCorrectsSingleWordNearMatchForProperNoun() {
        let entries = [DictionaryEntry(text: "Cursor")]

        let corrected = DictionaryCorrectionEngine.apply(
            to: "i am using curser today",
            entries: entries
        )

        XCTAssertEqual(corrected, "i am using Cursor today")
    }

    func testDoesNotRewriteUnrelatedText() {
        let entries = [DictionaryEntry(text: "Claude Code")]

        let corrected = DictionaryCorrectionEngine.apply(
            to: "the cloud cover is heavy today",
            entries: entries
        )

        XCTAssertEqual(corrected, "the cloud cover is heavy today")
    }

    func testDisabledEntriesAreIgnored() {
        let entries = [DictionaryEntry(text: "Claude Code", isEnabled: false)]

        let corrected = DictionaryCorrectionEngine.apply(
            to: "cloud code",
            entries: entries
        )

        XCTAssertEqual(corrected, "cloud code")
    }
}
