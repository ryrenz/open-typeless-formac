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

struct PendingTranscriptionItem: Identifiable, Equatable {
    let record: PendingTranscriptionRecord
    let audioURL: URL?
    let manifestURL: URL?
    let audioByteCount: Int64?

    var id: UUID { record.id }
}

enum PendingTranscriptionStoreError: Error, LocalizedError {
    case sourceMissing
    case unableToPreserveAudio(Error)
    case unableToDelete(Error)

    var errorDescription: String? {
        switch self {
        case .sourceMissing:
            return "The failed recording no longer exists"
        case .unableToPreserveAudio(let error):
            return "Unable to preserve the failed recording: \(error.localizedDescription)"
        case .unableToDelete(let error):
            return "Unable to delete every selected recovery file: \(error.localizedDescription)"
        }
    }
}

final class PendingTranscriptionStore {
    static let shared = PendingTranscriptionStore()
    static let didChangeNotification = Notification.Name("PendingTranscriptionStoreDidChange")

    private let fileManager: FileManager
    let directoryURL: URL
    private let audioExtensions: Set<String> = [
        "m4a", "mp3", "mp4", "mpeg", "mpga", "wav", "webm",
    ]

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

        postDidChangeNotification()
        return PreservedTranscription(
            record: record,
            audioURL: destinationURL,
            manifestURL: writtenManifestURL
        )
    }

    func loadAll() -> [PendingTranscriptionItem] {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return []
        }

        do {
            let urls = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [
                    .contentModificationDateKey,
                    .fileSizeKey,
                    .isRegularFileKey,
                    .isSymbolicLinkKey,
                ],
                options: [.skipsHiddenFiles]
            )
            let safeFiles = urls.filter(isSafeRegularStoreFile)
            let audioFilesByID = Dictionary(
                safeFiles.compactMap { url -> (UUID, URL)? in
                    guard audioExtensions.contains(url.pathExtension.lowercased()),
                          let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent)
                    else {
                        return nil
                    }
                    return (id, url)
                },
                uniquingKeysWith: { first, _ in first }
            )

            var itemsByID: [UUID: PendingTranscriptionItem] = [:]
            for manifestURL in safeFiles where manifestURL.pathExtension.lowercased() == "json" {
                guard let filenameID = UUID(
                    uuidString: manifestURL.deletingPathExtension().lastPathComponent
                ) else {
                    continue
                }

                guard let data = try? Data(contentsOf: manifestURL),
                      let record = try? JSONDecoder.pendingTranscriptionDecoder.decode(
                        PendingTranscriptionRecord.self,
                        from: data
                    ),
                    record.id == filenameID
                else {
                    let audioURL = audioFilesByID[filenameID]
                    let createdAt = (
                        try? manifestURL.resourceValues(forKeys: [.contentModificationDateKey])
                    )?.contentModificationDate ?? .distantPast
                    itemsByID[filenameID] = PendingTranscriptionItem(
                        record: PendingTranscriptionRecord(
                            id: filenameID,
                            createdAt: createdAt,
                            audioFilename: audioURL?.lastPathComponent
                                ?? manifestURL.lastPathComponent,
                            partialText: nil,
                            failureReason: "Recovery metadata is unavailable."
                        ),
                        audioURL: audioURL,
                        manifestURL: manifestURL,
                        audioByteCount: audioURL.flatMap(fileSize)
                    )
                    continue
                }

                let audioURL = validatedAudioURL(
                    filename: record.audioFilename,
                    expectedID: record.id,
                    candidates: audioFilesByID
                )
                itemsByID[record.id] = PendingTranscriptionItem(
                    record: record,
                    audioURL: audioURL,
                    manifestURL: manifestURL,
                    audioByteCount: audioURL.flatMap(fileSize)
                )
            }

            for (id, audioURL) in audioFilesByID where itemsByID[id] == nil {
                let createdAt = (
                    try? audioURL.resourceValues(forKeys: [.contentModificationDateKey])
                )?.contentModificationDate ?? .distantPast
                let record = PendingTranscriptionRecord(
                    id: id,
                    createdAt: createdAt,
                    audioFilename: audioURL.lastPathComponent,
                    partialText: nil,
                    failureReason: "Recovery metadata is unavailable."
                )
                itemsByID[id] = PendingTranscriptionItem(
                    record: record,
                    audioURL: audioURL,
                    manifestURL: nil,
                    audioByteCount: fileSize(audioURL)
                )
            }

            return itemsByID.values.sorted {
                if $0.record.createdAt == $1.record.createdAt {
                    return $0.id.uuidString > $1.id.uuidString
                }
                return $0.record.createdAt > $1.record.createdAt
            }
        } catch {
            print("[PendingTranscriptionStore] Load failed: \(error.localizedDescription)")
            return []
        }
    }

    @discardableResult
    func delete(id: UUID) throws -> Int {
        try deleteOwnedFiles { url in
            url.deletingPathExtension().lastPathComponent == id.uuidString
        }
    }

    @discardableResult
    func deleteAll() throws -> Int {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return 0
        }

        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        return try deleteFiles(urls.filter { isOwnedArtifact($0) && isSafeRegularStoreFile($0) })
    }

    private func moveOrCopyItem(from sourceURL: URL, to destinationURL: URL) throws {
        do {
            try fileManager.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
            // The durable recovery copy is authoritative. Failure to remove
            // the temporary source must not make a successful preserve look lost.
            try? fileManager.removeItem(at: sourceURL)
        }
    }

    private func deleteOwnedFiles(
        matching predicate: (URL) -> Bool
    ) throws -> Int {
        guard fileManager.fileExists(atPath: directoryURL.path) else {
            return 0
        }

        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        return try deleteFiles(
            urls.filter {
                predicate($0) && isOwnedArtifact($0) && isSafeRegularStoreFile($0)
            }
        )
    }

    private func deleteFiles(_ urls: [URL]) throws -> Int {
        var deletedCount = 0
        var firstError: Error?
        for url in urls {
            do {
                try fileManager.removeItem(at: url)
                deletedCount += 1
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }
        if deletedCount > 0 {
            postDidChangeNotification()
        }
        if let firstError {
            throw PendingTranscriptionStoreError.unableToDelete(firstError)
        }
        return deletedCount
    }

    private func validatedAudioURL(
        filename: String,
        expectedID: UUID,
        candidates: [UUID: URL]
    ) -> URL? {
        guard filename == URL(fileURLWithPath: filename).lastPathComponent,
              let filenameID = UUID(
                uuidString: URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
              ),
              filenameID == expectedID,
              audioExtensions.contains(
                URL(fileURLWithPath: filename).pathExtension.lowercased()
              )
        else {
            return nil
        }
        return candidates[expectedID]
    }

    private func isOwnedArtifact(_ url: URL) -> Bool {
        guard url.deletingLastPathComponent().standardizedFileURL
            == directoryURL.standardizedFileURL,
            UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil
        else {
            return false
        }

        let pathExtension = url.pathExtension.lowercased()
        return pathExtension == "json" || audioExtensions.contains(pathExtension)
    }

    private func isSafeRegularStoreFile(_ url: URL) -> Bool {
        guard url.deletingLastPathComponent().standardizedFileURL
            == directoryURL.standardizedFileURL,
            let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
        else {
            return false
        }
        return values.isRegularFile == true && values.isSymbolicLink != true
    }

    private func fileSize(_ url: URL) -> Int64? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            return nil
        }
        return Int64(size)
    }

    private func postDidChangeNotification() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
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

private extension JSONDecoder {
    static var pendingTranscriptionDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
