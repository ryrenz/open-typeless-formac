import XCTest
@testable import OpenTypeless

final class PendingTranscriptionStoreTests: XCTestCase {
    private var rootURL: URL!
    private var store: PendingTranscriptionStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PendingTranscriptionStoreTests-\(UUID().uuidString)",
                isDirectory: true
            )
        store = PendingTranscriptionStore(directoryURL: rootURL)
    }

    override func tearDownWithError() throws {
        if let rootURL {
            try? FileManager.default.removeItem(at: rootURL)
        }
        store = nil
        rootURL = nil
        try super.tearDownWithError()
    }

    func testPreserveMovesAudioAndWritesManifest() throws {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("failed-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        let audioData = Data([1, 2, 3, 4])
        try audioData.write(to: sourceURL)
        defer { try? FileManager.default.removeItem(at: sourceURL) }

        let preserved = try store.preserve(
            audioURL: sourceURL,
            partialText: "  recovered text  ",
            failureReason: "network timeout",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(try Data(contentsOf: preserved.audioURL), audioData)
        XCTAssertEqual(preserved.record.partialText, "recovered text")
        XCTAssertEqual(preserved.record.failureReason, "network timeout")

        let manifestURL = try XCTUnwrap(preserved.manifestURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            PendingTranscriptionRecord.self,
            from: Data(contentsOf: manifestURL)
        )
        XCTAssertEqual(decoded, preserved.record)

        XCTAssertEqual(try permissions(at: rootURL), 0o700)
        XCTAssertEqual(try permissions(at: preserved.audioURL), 0o600)
        XCTAssertEqual(try permissions(at: manifestURL), 0o600)
    }

    func testPreserveRejectsMissingSource() {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString)")
            .appendingPathExtension("m4a")

        XCTAssertThrowsError(
            try store.preserve(
                audioURL: missingURL,
                partialText: nil,
                failureReason: "failure"
            )
        ) { error in
            guard case PendingTranscriptionStoreError.sourceMissing = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testLoadAllReturnsPreservedItemAndAudioMetadata() throws {
        let sourceURL = try makeAudioFile()
        let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
        let preserved = try store.preserve(
            audioURL: sourceURL,
            partialText: "partial",
            failureReason: "timeout",
            createdAt: createdAt
        )

        let item = try XCTUnwrap(store.loadAll().first)
        XCTAssertEqual(item.record, preserved.record)
        XCTAssertEqual(
            item.audioURL?.resolvingSymlinksInPath(),
            preserved.audioURL.resolvingSymlinksInPath()
        )
        XCTAssertEqual(item.audioByteCount, 4)
    }

    func testLoadAllIncludesOrphanedAudioWithoutManifest() throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let id = UUID()
        let audioURL = rootURL
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension("m4a")
        try Data([1, 2]).write(to: audioURL)

        let item = try XCTUnwrap(store.loadAll().first)
        XCTAssertEqual(item.id, id)
        XCTAssertEqual(
            item.audioURL?.resolvingSymlinksInPath(),
            audioURL.resolvingSymlinksInPath()
        )
        XCTAssertNil(item.manifestURL)
    }

    func testTraversalManifestNeverDeletesExternalFile() throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let id = UUID()
        let externalURL = rootURL.deletingLastPathComponent()
            .appendingPathComponent("\(id.uuidString).m4a")
        try Data([9]).write(to: externalURL)
        defer { try? FileManager.default.removeItem(at: externalURL) }

        let record = PendingTranscriptionRecord(
            id: id,
            createdAt: Date(),
            audioFilename: "../\(id.uuidString).m4a",
            partialText: nil,
            failureReason: "invalid metadata"
        )
        let manifestURL = rootURL
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension("json")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(record).write(to: manifestURL)

        XCTAssertNil(store.loadAll().first?.audioURL)
        XCTAssertEqual(try store.delete(id: id), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: externalURL.path))
    }

    func testLoadAllIncludesCorruptManifestSoUserCanDeleteIt() throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        let id = UUID()
        let manifestURL = rootURL
            .appendingPathComponent(id.uuidString)
            .appendingPathExtension("json")
        try Data("not-json".utf8).write(to: manifestURL)

        let item = try XCTUnwrap(store.loadAll().first)
        XCTAssertEqual(item.id, id)
        XCTAssertEqual(
            item.manifestURL?.resolvingSymlinksInPath(),
            manifestURL.resolvingSymlinksInPath()
        )
        XCTAssertNil(item.audioURL)
        XCTAssertEqual(try store.delete(id: id), 1)
        XCTAssertTrue(store.loadAll().isEmpty)
    }

    func testDeleteAllRemovesOnlyOwnedArtifacts() throws {
        let first = try store.preserve(
            audioURL: makeAudioFile(),
            partialText: nil,
            failureReason: "first"
        )
        _ = try store.preserve(
            audioURL: makeAudioFile(),
            partialText: nil,
            failureReason: "second"
        )
        let unrelatedURL = rootURL.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: unrelatedURL)

        XCTAssertEqual(try store.delete(id: first.record.id), 2)
        XCTAssertEqual(store.loadAll().count, 1)
        XCTAssertEqual(try store.deleteAll(), 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedURL.path))
    }

    private func makeAudioFile() throws -> URL {
        let sourceURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("failed-\(UUID().uuidString)")
            .appendingPathExtension("m4a")
        try Data([1, 2, 3, 4]).write(to: sourceURL)
        return sourceURL
    }

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }
}
