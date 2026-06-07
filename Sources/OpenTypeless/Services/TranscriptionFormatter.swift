import Foundation
import OpenAI

enum TranscriptionFormatter {
    private static let systemPrompt = """
    You are a transcription formatter. Format the raw speech transcription below and return only the formatted result — no answers, no explanations, no extra wrappers.
    1. Punctuation: English-only → English (,.!?); Chinese or mixed → Chinese（，。！？：；""）.
    2. Spacing: one space between CJK and adjacent Latin/digits (pangu). No spaces between CJK.
    3. Paragraphs: split at natural topic boundaries.
    4. Lists: any enumeration (first/second, 第一/第二, 另外, also, etc.) → 1. 2. 3. one item per line.
    """

    private static let minFormattingLength = 20

    static func format(_ text: String, client: OpenAI) async -> String {
        guard text.count >= minFormattingLength else { return text }

        let estimatedOutputTokens = min(text.count * 2 + 200, 4096)
        let query = ChatQuery(
            messages: [
                .system(.init(content: .textContent(systemPrompt))),
                .user(.init(content: .string(text)))
            ],
            model: .gpt4_o_mini,
            maxTokens: estimatedOutputTokens
        )
        do {
            let result = try await client.chats(query: query)
            if let formatted = result.choices.first?.message.content,
               !formatted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return formatted.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } catch {
            // Silently fall back to unformatted text
        }
        return text
    }
}
