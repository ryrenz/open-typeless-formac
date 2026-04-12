import Foundation

final class DictionaryStore {
    static let shared = DictionaryStore()

    private let defaults: UserDefaults
    private let entriesKey: String
    private let autoLearnEnabledKey: String
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(
        defaults: UserDefaults = .standard,
        entriesKey: String = "dictionaryEntries",
        autoLearnEnabledKey: String = "dictionaryAutoLearnEnabled"
    ) {
        self.defaults = defaults
        self.entriesKey = entriesKey
        self.autoLearnEnabledKey = autoLearnEnabledKey
    }

    func loadAll() -> [DictionaryEntry] {
        guard let data = defaults.data(forKey: entriesKey),
              let entries = try? decoder.decode([DictionaryEntry].self, from: data)
        else {
            return []
        }

        return entries
            .map { entry in
                var cleaned = entry
                cleaned.text = entry.normalizedText
                return cleaned
            }
            .filter { !$0.text.isEmpty }
    }

    func save(entries: [DictionaryEntry]) {
        let cleaned = deduplicate(entries: entries)
        guard let data = try? encoder.encode(cleaned) else { return }
        defaults.set(data, forKey: entriesKey)
    }

    func activeEntries() -> [DictionaryEntry] {
        loadAll()
            .filter { $0.isEnabled }
            .sorted {
                if $0.createdAt != $1.createdAt {
                    return $0.createdAt < $1.createdAt
                }
                return $0.normalizedText.localizedCaseInsensitiveCompare($1.normalizedText) == .orderedAscending
            }
    }

    func autoLearnEnabled() -> Bool {
        defaults.bool(forKey: autoLearnEnabledKey)
    }

    func setAutoLearnEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: autoLearnEnabledKey)
    }

    func add(_ text: String, source: DictionaryEntrySource = .manual) -> AddResult {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return .empty }

        var entries = loadAll()
        guard !containsDuplicate(normalized, in: entries) else { return .duplicate }

        entries.append(DictionaryEntry(text: normalized, source: source))
        save(entries: entries)
        return .added
    }

    func update(id: UUID, text: String) -> UpdateResult {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return .empty }

        var entries = loadAll()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return .missing }
        guard !containsDuplicate(normalized, in: entries, excludingID: id) else { return .duplicate }

        entries[index].text = normalized
        entries[index].updatedAt = Date()
        save(entries: entries)
        return .updated
    }

    func setEnabled(id: UUID, isEnabled: Bool) {
        var entries = loadAll()
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isEnabled = isEnabled
        entries[index].updatedAt = Date()
        save(entries: entries)
    }

    func delete(id: UUID) {
        let entries = loadAll().filter { $0.id != id }
        save(entries: entries)
    }

    private func containsDuplicate(_ text: String, in entries: [DictionaryEntry], excludingID: UUID? = nil) -> Bool {
        entries.contains {
            $0.id != excludingID && $0.normalizedText.compare(text, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    private func deduplicate(entries: [DictionaryEntry]) -> [DictionaryEntry] {
        var seen = Set<String>()
        var result: [DictionaryEntry] = []

        for entry in entries {
            let normalized = entry.normalizedText
            guard !normalized.isEmpty else { continue }

            let key = normalized.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            guard !seen.contains(key) else { continue }
            seen.insert(key)

            var cleaned = entry
            cleaned.text = normalized
            result.append(cleaned)
        }

        return result.sorted {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt < $1.createdAt
            }
            return $0.normalizedText.localizedCaseInsensitiveCompare($1.normalizedText) == .orderedAscending
        }
    }
}

enum AddResult {
    case added
    case empty
    case duplicate
}

enum UpdateResult {
    case updated
    case empty
    case duplicate
    case missing
}
