import Foundation

enum HotwordPromptBuilder {
    private static let maxPromptLength = 500
    private static let maxTermLength = 80

    static func buildPrompt(from entries: [DictionaryEntry]) -> String? {
        let hotwords = sanitized(entries: entries)
        guard !hotwords.isEmpty else { return nil }

        let prefix = "Prefer these spellings when they match the audio: "
        var prompt = prefix

        for (index, word) in hotwords.enumerated() {
            let candidateSuffix = index == hotwords.count - 1 ? "\(word)." : "\(word), "
            if prompt.count + candidateSuffix.count > maxPromptLength {
                break
            }
            prompt += candidateSuffix
        }

        return prompt == prefix ? nil : prompt
    }

    static func sanitized(entries: [DictionaryEntry]) -> [String] {
        var seen = Set<String>()

        return entries
            .filter(\.isEnabled)
            .map(\.normalizedText)
            .filter { !$0.isEmpty && $0.count <= maxTermLength }
            .sorted {
                if $0.count != $1.count {
                    return $0.count > $1.count
                }
                return $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
            }
            .filter { word in
                let key = word.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                if seen.contains(key) { return false }
                seen.insert(key)
                return true
            }
    }
}
