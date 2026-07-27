import Foundation

struct PendingTranscriptionRecord: Codable, Equatable {
    let id: UUID
    let createdAt: Date
    let audioFilename: String
    let partialText: String?
    let failureReason: String
}

struct PreservedTranscription {
    let record: PendingTranscriptionRecord
    let audioURL: URL
    let manifestURL: URL?
}

enum PendingTranscriptionStoreError: Error, LocalizedError {
    case sourceMissing
    case unableToPreserveAudio(Error)

    var errorDescription: String? {
        switch self {
        case .sourceMissing:
            return "The failed recording no longer exists"
        case .unableToPreserveAudio(let error):
            return "Unable to preserve the failed recording: \(error.localizedDescription)"
        }
    }
}

final class PendingTranscriptionStore {
    static let shared = PendingTranscriptionStore()

    private let fileManager: FileManager
    let directoryURL: URL

    init(
        directoryURL: URL = PendingTranscriptionStore.defaultDirectoryURL(),
        fileManager: FileManager = .default
    ) {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
    }

    func preserve(
        audioURL: URL,
        partialText: String?,
        failureReason: String,
        createdAt: Date = Date()
    ) throws -> PreservedTranscription {
        guard fileManager.fileExists(atPath: audioURL.path) else {
            throw PendingTranscriptionStoreError.sourceMissing
        }

        try fileManager.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )

        let id = UUID()
        let audioFilename = "\(id.uuidString).\(audioURL.pathExtension.isEmpty ? "m4a" : audioURL.pathExtension)"
        let destinationURL = directoryURL.appendingPathComponent(audioFilename)

        do {
            try moveOrCopyItem(from: audioURL, to: destinationURL)
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: destinationURL.path
            )
        } catch {
            throw PendingTranscriptionStoreError.unableToPreserveAudio(error)
        }

        let normalizedPartial = partialText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let record = PendingTranscriptionRecord(
            id: id,
            createdAt: createdAt,
            audioFilename: audioFilename,
            partialText: normalizedPartial?.isEmpty == false ? normalizedPartial : nil,
            failureReason: failureReason
        )
        let manifestURL = directoryURL
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension("json")

        let writtenManifestURL: URL?
        do {
            let data = try JSONEncoder.pendingTranscriptionEncoder.encode(record)
            try data.write(to: manifestURL, options: .atomic)
            try? fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: manifestURL.path
            )
            writtenManifestURL = manifestURL
        } catch {
            // The audio file is the primary recovery artifact. Keep it even if
            // metadata serialization fails, and surface the audio path to the user.
            print("[PendingTranscriptionStore] Manifest write failed: \(error.localizedDescription)")
            writtenManifestURL = nil
        }

        return PreservedTranscription(
            record: record,
            audioURL: destinationURL,
            manifestURL: writtenManifestURL
        )
    }

    private func moveOrCopyItem(from sourceURL: URL, to destinationURL: URL) throws {
        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            try fileManager.removeItem(at: sourceURL)
        }
    }

    private static func defaultDirectoryURL() -> URL {
        let baseURL = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return baseURL
            .appendingPathComponent("OpenTypeless", isDirectory: true)
            .appendingPathComponent("PendingTranscriptions", isDirectory: true)
    }
}

private extension JSONEncoder {
    static var pendingTranscriptionEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
