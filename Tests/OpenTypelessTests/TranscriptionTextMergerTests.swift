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

    func testRemovesChineseOverlap() {
        XCTAssertEqual(
            TranscriptionTextMerger.removingOverlap(
                previous: "这是上一段的结尾",
                next: "上一段的结尾，然后继续"
            ),
            "，然后继续"
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
