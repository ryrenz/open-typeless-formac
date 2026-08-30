import AppKit
import SwiftUI

struct HistoryTabView: View {
    let store: HistoryStore

    @State private var entries: [HistoryEntry] = []
    @State private var retentionPolicy: HistoryRetentionPolicy = .keepForever
    @State private var copiedEntryID: UUID?
    @State private var entryPendingDeletion: HistoryEntry?
    @State private var showsClearConfirmation = false
    @State private var errorMessage: String?

    init(store: HistoryStore = .shared) {
        self.store = store
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox(historyTitle) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(historyDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Picker(retentionTitle, selection: $retentionPolicy) {
                        ForEach(HistoryRetentionPolicy.allCases, id: \.self) { policy in
                            Text(retentionLabel(for: policy)).tag(policy)
                        }
                    }
                    .pickerStyle(.menu)
                    .onChange(of: retentionPolicy) { _, newValue in
                        store.setRetentionPolicy(newValue)
                        reload()
                    }

                    if !entries.isEmpty {
                        HStack {
                            Text(entryCountLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(clearAllLabel, role: .destructive) {
                                showsClearConfirmation = true
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    if entries.isEmpty {
                        Text(emptyState)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    } else {
                        List(entries) { entry in
                            row(for: entry)
                        }
                        .frame(minHeight: 260)
                    }
                }
                .padding(8)
            }

            Spacer()
        }
        .padding(20)
        .onAppear { reload() }
        .onReceive(NotificationCenter.default.publisher(for: HistoryStore.didChangeNotification)) { _ in
            reload()
        }
        .confirmationDialog(
            deleteLabel,
            isPresented: Binding(
                get: { entryPendingDeletion != nil },
                set: { if !$0 { entryPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(deleteLabel, role: .destructive) {
                deletePendingEntry()
            }
            Button(cancelLabel, role: .cancel) {
                entryPendingDeletion = nil
            }
        } message: {
            Text(deleteConfirmation)
        }
        .confirmationDialog(
            clearAllLabel,
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button(clearAllLabel, role: .destructive) {
                clearAll()
            }
            Button(cancelLabel, role: .cancel) {}
        } message: {
            Text(clearAllConfirmation)
        }
    }

    @ViewBuilder
    private func row(for entry: HistoryEntry) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.text)
                    .textSelection(.enabled)
                Text(Self.dateFormatter.string(from: entry.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button(copiedEntryID == entry.id ? copiedLabel : copyLabel) {
                NSPasteboard.general.clearContents()
                if NSPasteboard.general.setString(entry.text, forType: .string) {
                    copiedEntryID = entry.id
                }
            }
            .buttonStyle(.bordered)

            Button(deleteLabel, role: .destructive) {
                entryPendingDeletion = entry
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)
    }

    private func reload() {
        retentionPolicy = store.retentionPolicy()
        entries = store.loadAll()
        if let copiedEntryID, !entries.contains(where: { $0.id == copiedEntryID }) {
            self.copiedEntryID = nil
        }
    }

    private func deletePendingEntry() {
        guard let entryPendingDeletion else { return }
        do {
            try store.delete(id: entryPendingDeletion.id)
            self.entryPendingDeletion = nil
            errorMessage = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
            reload()
        }
    }

    private func clearAll() {
        do {
            try store.deleteAll()
            errorMessage = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
            reload()
        }
    }

    private func retentionLabel(for policy: HistoryRetentionPolicy) -> String {
        switch policy {
        case .keepForever:
            return "Keep forever"
        case .keepMonth:
            return "Keep a month"
        case .keepWeek:
            return "Keep a week"
        case .keep24Hours:
            return "Keep 24 hours"
        }
    }

    private var historyTitle: String { "History" }
    private var historyDescription: String {
        "After each transcription completes, the final text shown or inserted for the user is saved locally."
    }
    private var retentionTitle: String { "Retention" }
    private var emptyState: String {
        "No history yet. Completed transcriptions will appear here automatically."
    }
    private var copyLabel: String { "Copy" }
    private var copiedLabel: String { "Copied" }
    private var deleteLabel: String { "Delete Entry" }
    private var clearAllLabel: String { "Clear All" }
    private var cancelLabel: String { "Cancel" }
    private var entryCountLabel: String {
        "\(entries.count) local entries"
    }
    private var deleteConfirmation: String {
        "This history entry will be permanently deleted from this Mac."
    }
    private var clearAllConfirmation: String {
        "All transcription history will be permanently deleted from this Mac. This cannot be undone."
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}
