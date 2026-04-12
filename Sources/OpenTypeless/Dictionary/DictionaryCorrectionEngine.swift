import Foundation

enum DictionaryCorrectionEngine {
    private static let tokenPattern = #"[A-Za-z0-9]+(?:[.'-][A-Za-z0-9]+)*"#

    static func apply(to text: String, entries: [DictionaryEntry]) -> String {
        var result = text

        for entry in candidateEntries(from: entries) {
            result = replaceMatches(in: result, with: entry)
        }

        return result
    }

    private static func candidateEntries(from entries: [DictionaryEntry]) -> [DictionaryEntry] {
        entries
            .filter(\.isEnabled)
            .filter { !$0.normalizedText.isEmpty }
            .sorted {
                let lhsCount = tokenize($0.text).count
                let rhsCount = tokenize($1.text).count
                if lhsCount != rhsCount { return lhsCount > rhsCount }
                if $0.text.count != $1.text.count { return $0.text.count > $1.text.count }
                return $0.text.localizedCaseInsensitiveCompare($1.text) == .orderedAscending
            }
    }

    private static func replaceMatches(in text: String, with entry: DictionaryEntry) -> String {
        let targetTokens = tokenize(entry.text)
        guard !targetTokens.isEmpty else { return text }

        let words = transcriptWords(in: text)
        guard !words.isEmpty else { return text }

        var replacements: [(range: NSRange, replacement: String)] = []

        if words.count >= targetTokens.count {
            for start in 0...(words.count - targetTokens.count) {
                let window = Array(words[start..<(start + targetTokens.count)])
                guard shouldReplace(window: window, with: targetTokens, canonical: entry.text) else { continue }

                let location = window[0].range.location
                let end = NSMaxRange(window[window.count - 1].range)
                replacements.append((NSRange(location: location, length: end - location), entry.text))
            }
        }

        if targetTokens.count > 1 {
            for word in words {
                guard shouldReplaceConcatenated(word: word, canonicalTokens: targetTokens, canonical: entry.text) else {
                    continue
                }
                replacements.append((word.range, entry.text))
            }
        }

        guard !replacements.isEmpty else { return text }

        let mutable = NSMutableString(string: text)
        for replacement in replacements.reversed() {
            mutable.replaceCharacters(in: replacement.range, with: replacement.replacement)
        }
        return mutable as String
    }

    private static func shouldReplace(
        window: [TranscriptWord],
        with canonicalTokens: [String],
        canonical: String
    ) -> Bool {
        let windowText = window.map(\.text).joined(separator: " ")
        if windowText.compare(canonical, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return false
        }

        var exactMatches = 0
        var fuzzyMatches = 0

        for (spoken, canonicalToken) in zip(window, canonicalTokens) {
            let spokenToken = simplify(spoken.text)
            let targetToken = simplify(canonicalToken)
            guard !spokenToken.isEmpty, !targetToken.isEmpty else { return false }

            if spokenToken == targetToken {
                exactMatches += 1
                continue
            }

            guard isFuzzyMatch(spokenToken, targetToken) else { return false }
            fuzzyMatches += 1
        }

        if canonicalTokens.count == 1 {
            return fuzzyMatches == 1 && shouldAllowSingleTokenCorrection(canonical: canonical)
        }

        return exactMatches >= canonicalTokens.count - 1 && fuzzyMatches >= 1
    }

    private static func shouldReplaceConcatenated(
        word: TranscriptWord,
        canonicalTokens: [String],
        canonical: String
    ) -> Bool {
        guard canonicalTokens.count > 1 else { return false }

        let spokenToken = simplify(word.text)
        let joinedCanonical = simplify(canonicalTokens.joined())
        guard !spokenToken.isEmpty, !joinedCanonical.isEmpty else { return false }
        guard spokenToken != joinedCanonical else { return false }
        guard shouldAllowConcatenatedCorrection(canonical: canonical) else { return false }

        return isFuzzyMatch(spokenToken, joinedCanonical)
    }

    private static func shouldAllowSingleTokenCorrection(canonical: String) -> Bool {
        canonical.contains { $0.isUppercase } || canonical.count >= 6
    }

    private static func shouldAllowConcatenatedCorrection(canonical: String) -> Bool {
        canonical.contains(" ") && canonical.count >= 8
    }

    private static func isFuzzyMatch(_ lhs: String, _ rhs: String) -> Bool {
        guard lhs.first == rhs.first else { return false }
        guard abs(lhs.count - rhs.count) <= 2 else { return false }

        let threshold: Int
        switch max(lhs.count, rhs.count) {
        case 0...4:
            threshold = 1
        case 5...8:
            threshold = 2
        default:
            threshold = 3
        }

        return editDistance(lhs, rhs) <= threshold
    }

    private static func transcriptWords(in text: String) -> [TranscriptWord] {
        guard let regex = try? NSRegularExpression(pattern: tokenPattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            return TranscriptWord(text: String(text[swiftRange]), range: match.range)
        }
    }

    private static func tokenize(_ text: String) -> [String] {
        transcriptWords(in: text).map(\.text)
    }

    private static func simplify(_ token: String) -> String {
        String(
            token
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .filter { $0.isLetter || $0.isNumber }
        )
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let lhsChars = Array(lhs)
        let rhsChars = Array(rhs)
        var distances = Array(0...rhsChars.count)

        for (lhsIndex, lhsChar) in lhsChars.enumerated() {
            var previous = distances[0]
            distances[0] = lhsIndex + 1

            for (rhsIndex, rhsChar) in rhsChars.enumerated() {
                let oldValue = distances[rhsIndex + 1]
                if lhsChar == rhsChar {
                    distances[rhsIndex + 1] = previous
                } else {
                    distances[rhsIndex + 1] = min(
                        previous + 1,
                        distances[rhsIndex] + 1,
                        oldValue + 1
                    )
                }
                previous = oldValue
            }
        }

        return distances[rhsChars.count]
    }
}

private struct TranscriptWord {
    let text: String
    let range: NSRange
}
