import SwiftUI

struct DictionaryTabView: View {
    let store: DictionaryStore

    @State private var entries: [DictionaryEntry] = []
    @State private var newEntryText = ""
    @State private var validationMessage: String?
    @State private var editingEntryID: UUID?
    @State private var editingText = ""

    init(store: DictionaryStore = .shared) {
        self.store = store
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox(dictionaryTitle) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(dictionaryDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 8) {
                        TextField(addPlaceholder, text: $newEntryText)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { addEntry() }

                        Button(addLabel) { addEntry() }
                            .buttonStyle(.borderedProminent)
                    }

                    if let validationMessage {
                        Text(validationMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if entries.isEmpty {
                        Text(emptyState)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    } else {
                        List {
                            ForEach(entries) { entry in
                                row(for: entry)
                            }
                        }
                        .frame(minHeight: 180)
                    }
                }
                .padding(8)
            }

            GroupBox(autoLearnTitle) {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(autoLearnToggle, isOn: .constant(store.autoLearnEnabled()))
                        .disabled(true)
                    Text(autoLearnDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }

            Spacer()
        }
        .padding(20)
        .onAppear { reloadEntries() }
    }

    @ViewBuilder
    private func row(for entry: DictionaryEntry) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { entry.isEnabled },
                set: { isEnabled in
                    store.setEnabled(id: entry.id, isEnabled: isEnabled)
                    reloadEntries()
                }
            ))
            .labelsHidden()

            if editingEntryID == entry.id {
                TextField(editPlaceholder, text: $editingText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitEdit(for: entry) }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.text)
                    if entry.source == .autoLearned {
                        Text(autoTag)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Spacer()

            if editingEntryID == entry.id {
                Button(saveLabel) { commitEdit(for: entry) }
                    .buttonStyle(.borderedProminent)
                Button(cancelLabel) { cancelEditing() }
                    .buttonStyle(.bordered)
            } else {
                Button(editLabel) { startEditing(entry) }
                    .buttonStyle(.bordered)
                Button(deleteLabel, role: .destructive) {
                    store.delete(id: entry.id)
                    reloadEntries()
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func addEntry() {
        switch store.add(newEntryText) {
        case .added:
            newEntryText = ""
            validationMessage = nil
            reloadEntries()
        case .empty:
            validationMessage = emptyValidation
        case .duplicate:
            validationMessage = duplicateValidation
        }
    }

    private func startEditing(_ entry: DictionaryEntry) {
        editingEntryID = entry.id
        editingText = entry.text
        validationMessage = nil
    }

    private func commitEdit(for entry: DictionaryEntry) {
        switch store.update(id: entry.id, text: editingText) {
        case .updated:
            cancelEditing()
            reloadEntries()
        case .empty:
            validationMessage = emptyValidation
        case .duplicate:
            validationMessage = duplicateValidation
        case .missing:
            cancelEditing()
            reloadEntries()
        }
    }

    private func cancelEditing() {
        editingEntryID = nil
        editingText = ""
    }

    private func reloadEntries() {
        entries = store.loadAll()
        if let editingEntryID, !entries.contains(where: { $0.id == editingEntryID }) {
            cancelEditing()
        }
    }

    private var dictionaryTitle: String { "Dictionary" }
    private var dictionaryDescription: String {
        "Add proper nouns that are often misrecognized. These words are sent as transcription hints so the model prefers the correct spelling."
    }
    private var addPlaceholder: String { "Add dictionary term..." }
    private var addLabel: String { "Add" }
    private var emptyState: String {
        "No entries yet. Add product names, people, or fixed terms such as Claude, Anthropic, or Cursor."
    }
    private var editPlaceholder: String { "Edit entry" }
    private var autoLearnTitle: String { "Auto-learn" }
    private var autoLearnToggle: String { "Enable auto-learn (Coming soon)" }
    private var autoLearnDescription: String {
        "Version one only supports manual dictionary management. Future versions can suggest new entries after you correct transcriptions."
    }
    private var autoTag: String { "Auto" }
    private var saveLabel: String { "Save" }
    private var cancelLabel: String { "Cancel" }
    private var editLabel: String { "Edit" }
    private var deleteLabel: String { "Delete" }
    private var emptyValidation: String { "Entry cannot be empty." }
    private var duplicateValidation: String { "This entry already exists." }
}
