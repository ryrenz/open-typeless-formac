import Foundation

enum TranscriptionTextMerger {
    static func removingOverlap(
        previous: String,
        next: String,
        minimumOverlap: Int = 4,
        maximumOverlap: Int = 200
    ) -> String {
        let trimmedNext = next.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !previous.isEmpty, !trimmedNext.isEmpty else { return trimmedNext }

        let normalizedPrevious = normalized(previous)
        let normalizedNext = normalized(trimmedNext)
        let upperBound = min(
            maximumOverlap,
            normalizedPrevious.characters.count,
            normalizedNext.characters.count
        )
        guard upperBound >= minimumOverlap else { return trimmedNext }

        for overlapLength in stride(from: upperBound, through: minimumOverlap, by: -1) {
            if normalizedPrevious.characters.suffix(overlapLength)
                == normalizedNext.characters.prefix(overlapLength) {
                let cutIndex = normalizedNext.originalEndIndices[overlapLength - 1]
                return cleanOverlapBoundary(
                    String(trimmedNext[cutIndex...])
                )
            }
        }

        return trimmedNext
    }

    private static func cleanOverlapBoundary(_ text: String) -> String {
        var result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = result.first,
              let scalar = first.unicodeScalars.first,
              CharacterSet(charactersIn: ",.;:").contains(scalar)
        else {
            return result
        }

        let afterPunctuation = result.dropFirst()
        guard afterPunctuation.first?.isWhitespace == true else {
            return result
        }

        result = String(afterPunctuation)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return result
    }

    private struct NormalizedText {
        let characters: [Character]
        let originalEndIndices: [String.Index]
    }

    private static func normalized(_ text: String) -> NormalizedText {
        var characters: [Character] = []
        var endIndices: [String.Index] = []

        for index in text.indices {
            let nextIndex = text.index(after: index)
            let folded = String(text[index])
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased()

            for character in folded where character.isLetter || character.isNumber {
                characters.append(character)
                endIndices.append(nextIndex)
            }
        }

        return NormalizedText(
            characters: characters,
            originalEndIndices: endIndices
        )
    }
}
