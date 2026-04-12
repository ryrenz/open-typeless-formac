import XCTest
@testable import OpenTypeless

final class HotwordPromptBuilderTests: XCTestCase {
    func testSanitizedFiltersDisabledBlankAndDuplicateEntries() {
        let entries = [
            DictionaryEntry(text: "Claude Code"),
            DictionaryEntry(text: " claude code "),
            DictionaryEntry(text: "Anthropic", isEnabled: false),
            DictionaryEntry(text: " "),
            DictionaryEntry(text: "Cursor")
        ]

        XCTAssertEqual(HotwordPromptBuilder.sanitized(entries: entries), ["Claude Code", "Cursor"])
    }

    func testBuildPromptPrefersLongerTermsFirst() {
        let entries = [
            DictionaryEntry(text: "Claude"),
            DictionaryEntry(text: "Claude Code"),
            DictionaryEntry(text: "Anthropic")
        ]

        let prompt = HotwordPromptBuilder.buildPrompt(from: entries)
        XCTAssertEqual(
            prompt,
            "Prefer these spellings when they match the audio: Claude Code, Anthropic, Claude."
        )
    }

    func testBuildPromptReturnsNilWhenNoUsableEntries() {
        let entries = [
            DictionaryEntry(text: " ", isEnabled: true),
            DictionaryEntry(text: String(repeating: "a", count: 81), isEnabled: true)
        ]

        XCTAssertNil(HotwordPromptBuilder.buildPrompt(from: entries))
    }
}
