import AppKit
import SwiftUI

struct PendingTranscriptionsTabView: View {
    let store: PendingTranscriptionStore

    @State private var items: [PendingTranscriptionItem] = []
    @State private var itemPendingDeletion: PendingTranscriptionItem?
    @State private var showsClearConfirmation = false
    @State private var errorMessage: String?

    init(store: PendingTranscriptionStore = .shared) {
        self.store = store
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox(title) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if let errorMessage {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    if items.isEmpty {
                        Text(emptyState)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 8)
                    } else {
                        HStack {
                            Text(itemCountLabel)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button(clearAllLabel, role: .destructive) {
                                showsClearConfirmation = true
                            }
                            .buttonStyle(.bordered)
                        }

                        List(items) { item in
                            row(for: item)
                        }
                        .frame(minHeight: 300)
                    }
                }
                .padding(8)
            }
            Spacer()
        }
        .padding(20)
        .onAppear { reload() }
        .onReceive(
            NotificationCenter.default.publisher(
                for: PendingTranscriptionStore.didChangeNotification
            )
        ) { _ in
            reload()
        }
        .confirmationDialog(
            deleteLabel,
            isPresented: Binding(
                get: { itemPendingDeletion != nil },
                set: { if !$0 { itemPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(deleteLabel, role: .destructive) { deletePendingItem() }
            Button(cancelLabel, role: .cancel) {
                itemPendingDeletion = nil
            }
        } message: {
            Text(deleteConfirmation)
        }
        .confirmationDialog(
            clearAllLabel,
            isPresented: $showsClearConfirmation,
            titleVisibility: .visible
        ) {
            Button(clearAllLabel, role: .destructive) { clearAll() }
            Button(cancelLabel, role: .cancel) {}
        } message: {
            Text(clearAllConfirmation)
        }
    }

    @ViewBuilder
    private func row(for item: PendingTranscriptionItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(Self.dateFormatter.string(from: item.record.createdAt))
                    .font(.headline)
                Text(item.record.failureReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let partialText = item.record.partialText {
                    Text(partialText)
                        .font(.caption)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
                Text(fileDetails(for: item))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                Button(revealLabel) { reveal(item) }
                    .buttonStyle(.bordered)
                    .disabled(item.audioURL == nil && item.manifestURL == nil)
                Button(deleteLabel, role: .destructive) {
                    itemPendingDeletion = item
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(.vertical, 4)
    }

    private func reload() {
        items = store.loadAll()
        errorMessage = nil
    }

    private func reveal(_ item: PendingTranscriptionItem) {
        if let url = item.audioURL ?? item.manifestURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    private func deletePendingItem() {
        guard let item = itemPendingDeletion else { return }
        do {
            try store.delete(id: item.id)
            itemPendingDeletion = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
            reloadPreservingError()
        }
    }

    private func clearAll() {
        do {
            try store.deleteAll()
            reload()
        } catch {
            errorMessage = error.localizedDescription
            reloadPreservingError()
        }
    }

    private func reloadPreservingError() {
        items = store.loadAll()
    }

    private func fileDetails(for item: PendingTranscriptionItem) -> String {
        let filename = item.audioURL?.lastPathComponent
            ?? item.manifestURL?.lastPathComponent
            ?? item.record.audioFilename
        guard let audioByteCount = item.audioByteCount else {
            return filename
        }
        return "\(filename) · \(ByteCountFormatter.string(fromByteCount: audioByteCount, countStyle: .file))"
    }

    private var title: String { "Failed Recordings" }
    private var description: String {
        "If transcription fails after a request starts, the original recording is kept on this Mac. Reveal it in Finder or permanently delete it here."
    }
    private var emptyState: String {
        "No failed recordings are pending."
    }
    private var itemCountLabel: String {
        "\(items.count) local recordings"
    }
    private var revealLabel: String { "Reveal in Finder" }
    private var deleteLabel: String { "Delete Recording" }
    private var clearAllLabel: String { "Delete All" }
    private var cancelLabel: String { "Cancel" }
    private var deleteConfirmation: String {
        "This recording and its recovery metadata will be permanently deleted from this Mac."
    }
    private var clearAllConfirmation: String {
        "All failed recordings and recovery metadata will be permanently deleted from this Mac. This cannot be undone."
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        return formatter
    }()
}
