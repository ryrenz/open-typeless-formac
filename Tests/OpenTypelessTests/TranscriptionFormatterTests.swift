import XCTest
@testable import OpenTypeless

final class TranscriptionFormatterTests: XCTestCase {
    func testResolvedTextRejectsLengthTruncatedOutput() {
        XCTAssertEqual(
            TranscriptionFormatter.resolvedText(
                original: "Complete raw transcript",
                candidate: "Truncated transcript",
                finishReason: "length"
            ),
            "Complete raw transcript"
        )
    }

    func testResolvedTextAcceptsCompleteNonEmptyOutput() {
        XCTAssertEqual(
            TranscriptionFormatter.resolvedText(
                original: "raw",
                candidate: "  formatted  ",
                finishReason: "stop"
            ),
            "formatted"
        )
    }

    func testResolvedTextRejectsEmptyOrFilteredOutput() {
        XCTAssertEqual(
            TranscriptionFormatter.resolvedText(
                original: "raw",
                candidate: " ",
                finishReason: "stop"
            ),
            "raw"
        )
        XCTAssertEqual(
            TranscriptionFormatter.resolvedText(
                original: "raw",
                candidate: "candidate",
                finishReason: "content_filter"
            ),
            "raw"
        )
    }
}
