import XCTest
@testable import OpenTypeless

final class TranscriptionFormatterTests: XCTestCase {
    func testMistralFormattingUsesLegacyMaxTokensField() throws {
        let query = TranscriptionFormatter.makeQuery(
            text: String(repeating: "raw ", count: 10),
            model: "mistral-small-latest",
            estimatedOutputTokens: 256,
            tokenLimitPolicy: .maxTokens
        )
        let data = try JSONEncoder().encode(query)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["max_tokens"] as? Int, 256)
        XCTAssertNil(object["max_completion_tokens"])
    }

    func testOpenAIFormattingUsesMaxCompletionTokensField() throws {
        let query = TranscriptionFormatter.makeQuery(
            text: String(repeating: "raw ", count: 10),
            model: "gpt-4o-mini",
            estimatedOutputTokens: 256,
            tokenLimitPolicy: .maxCompletionTokens
        )
        let data = try JSONEncoder().encode(query)
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )

        XCTAssertEqual(object["max_completion_tokens"] as? Int, 256)
        XCTAssertNil(object["max_tokens"])
    }

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
