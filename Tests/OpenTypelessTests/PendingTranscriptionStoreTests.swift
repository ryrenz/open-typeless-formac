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

    private func permissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }
}
