import SwiftUI

struct DictionaryTabView: View {
    let l: L
    let store: DictionaryStore

    @State private var entries: [DictionaryEntry] = []
    @State private var newEntryText = ""
    @State private var validationMessage: String?
    @State private var editingEntryID: UUID?
    @State private var editingText = ""

    init(l: L, store: DictionaryStore = .shared) {
        self.l = l
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

    private var dictionaryTitle: String { l.lang == .zh ? "词汇表" : "Dictionary" }
    private var dictionaryDescription: String {
        l.lang == .zh
            ? "添加容易被误识别的专有名词。系统会把这些词作为转写提示发给模型，帮助它优先使用正确拼写。"
            : "Add proper nouns that are often misrecognized. These words are sent as transcription hints so the model prefers the correct spelling."
    }
    private var addPlaceholder: String { l.lang == .zh ? "添加词条..." : "Add dictionary term..." }
    private var addLabel: String { l.lang == .zh ? "添加" : "Add" }
    private var emptyState: String {
        l.lang == .zh
            ? "还没有词条。先添加一些产品名、人名或固定术语，比如 Claude、Anthropic、Cursor。"
            : "No entries yet. Add product names, people, or fixed terms such as Claude, Anthropic, or Cursor."
    }
    private var editPlaceholder: String { l.lang == .zh ? "编辑词条" : "Edit entry" }
    private var autoLearnTitle: String { l.lang == .zh ? "自动学习" : "Auto-learn" }
    private var autoLearnToggle: String { l.lang == .zh ? "启用自动学习（即将推出）" : "Enable auto-learn (Coming soon)" }
    private var autoLearnDescription: String {
        l.lang == .zh
            ? "首版只支持手动维护词汇表。后续版本会在用户修正转写结果后推荐新词条。"
            : "Version one only supports manual dictionary management. Future versions can suggest new entries after you correct transcriptions."
    }
    private var autoTag: String { l.lang == .zh ? "自动学习" : "Auto" }
    private var saveLabel: String { l.lang == .zh ? "保存" : "Save" }
    private var cancelLabel: String { l.lang == .zh ? "取消" : "Cancel" }
    private var editLabel: String { l.lang == .zh ? "编辑" : "Edit" }
    private var deleteLabel: String { l.lang == .zh ? "删除" : "Delete" }
    private var emptyValidation: String {
        l.lang == .zh ? "词条不能为空。" : "Entry cannot be empty."
    }
    private var duplicateValidation: String {
        l.lang == .zh ? "这个词条已经存在。" : "This entry already exists."
    }
}
