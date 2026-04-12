import Foundation

enum DictionaryEntrySource: String, Codable, CaseIterable {
    case manual
    case autoLearned
}

struct DictionaryEntry: Identifiable, Codable, Equatable {
    let id: UUID
    var text: String
    var isEnabled: Bool
    var source: DictionaryEntrySource
    let createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        text: String,
        isEnabled: Bool = true,
        source: DictionaryEntrySource = .manual,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.isEnabled = isEnabled
        self.source = source
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    var normalizedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
