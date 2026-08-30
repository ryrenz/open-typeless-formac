import XCTest
@testable import OpenTypeless

final class TranscriptionTextMergerTests: XCTestCase {
    func testRemovesPunctuationInsensitiveOverlap() {
        XCTAssertEqual(
            TranscriptionTextMerger.removingOverlap(
                previous: "We shipped OpenTypeless.",
                next: "OpenTypeless, and users tested it."
            ),
            "and users tested it."
        )
    }

    func testRemovesOverlapBeforeFullWidthPunctuation() {
        XCTAssertEqual(
            TranscriptionTextMerger.removingOverlap(
                previous: "This is the end of the previous segment",
                next: "the end of the previous segment，then continue"
            ),
            "，then continue"
        )
    }

    func testRemovesCJKOverlap() {
        let previous = "\u{8FD9}\u{662F}\u{4E0A}\u{4E00}\u{6BB5}\u{7684}\u{7ED3}\u{5C3E}"
        let next = "\u{4E0A}\u{4E00}\u{6BB5}\u{7684}\u{7ED3}\u{5C3E}\u{FF0C}\u{7136}\u{540E}\u{7EE7}\u{7EED}"

        XCTAssertEqual(
            TranscriptionTextMerger.removingOverlap(previous: previous, next: next),
            "\u{FF0C}\u{7136}\u{540E}\u{7EE7}\u{7EED}"
        )
    }

    func testKeepsUnrelatedText() {
        XCTAssertEqual(
            TranscriptionTextMerger.removingOverlap(
                previous: "First topic",
                next: "Second topic"
            ),
            "Second topic"
        )
    }
}
