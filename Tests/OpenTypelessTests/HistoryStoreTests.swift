import XCTest
@testable import OpenTypeless

final class HistoryStoreTests: XCTestCase {
    private var dbURL: URL!
    private var store: HistoryStore!

    override func setUp() {
        super.setUp()
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HistoryStoreTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("history.sqlite", isDirectory: false)
        store = HistoryStore(dbURL: dbURL)
    }

    override func tearDown() {
        store = nil

        try? FileManager.default.removeItem(at: dbURL)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbURL.path + "-wal"))
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: dbURL.path + "-shm"))
        try? FileManager.default.removeItem(at: dbURL.deletingLastPathComponent())

        dbURL = nil
        super.tearDown()
    }

    func testAppendAndLoadEntriesDescendingByDate() {
        let now = Date()
        store.append(text: "First", createdAt: now.addingTimeInterval(-10))
        store.append(text: "Second", createdAt: now)

        let entries = store.loadAll()
        XCTAssertEqual(entries.map(\.text), ["Second", "First"])
    }

    func testEmptyTextNormalizesToSilentMessage() {
        store.append(text: "   \n")

        XCTAssertEqual(store.loadAll().first?.text, "Audio is silent")
    }

    func testRetentionPolicyPrunesExpiredEntries() {
        let now = Date()
        store.append(text: "Old", createdAt: now.addingTimeInterval(-(25 * 60 * 60)))
        store.append(text: "New", createdAt: now)

        store.setRetentionPolicy(.keep24Hours)
        _ = store.pruneExpiredRecords(referenceDate: now)

        XCTAssertEqual(store.loadAll().map(\.text), ["New"])
    }

    func testEntriesAndRetentionPolicyPersistAcrossStoreReload() {
        store.append(text: "Claude Code")
        store.setRetentionPolicy(.keepWeek)

        let reloadedStore = HistoryStore(dbURL: dbURL)

        XCTAssertEqual(reloadedStore.loadAll().map(\.text), ["Claude Code"])
        XCTAssertEqual(reloadedStore.retentionPolicy(), .keepWeek)
    }

    func testDeleteRemovesOnlyMatchingEntry() throws {
        store.append(text: "Keep")
        store.append(text: "Delete")
        let entries = store.loadAll()
        let deleteID = entries.first { $0.text == "Delete" }!.id

        XCTAssertTrue(try store.delete(id: deleteID))
        XCTAssertEqual(store.loadAll().map(\.text), ["Keep"])
        XCTAssertFalse(try store.delete(id: UUID()))
    }

    func testDeleteAllRemovesEveryEntryAndKeepsRetentionPolicy() throws {
        store.append(text: "First")
        store.append(text: "Second")
        store.setRetentionPolicy(.keepWeek)

        XCTAssertEqual(try store.deleteAll(), 2)
        XCTAssertTrue(store.loadAll().isEmpty)
        XCTAssertEqual(store.retentionPolicy(), .keepWeek)
        XCTAssertEqual(try store.deleteAll(), 0)
    }

    func testDeleteRemovesTranscriptBytesFromDatabaseAndWAL() throws {
        let transcript = "sensitive-transcript-\(UUID().uuidString)"
        store.append(text: transcript)
        let id = try XCTUnwrap(store.loadAll().first?.id)

        XCTAssertTrue(try store.delete(id: id))

        let transcriptData = Data(transcript.utf8)
        for url in [
            dbURL!,
            URL(fileURLWithPath: dbURL.path + "-wal"),
            URL(fileURLWithPath: dbURL.path + "-shm"),
        ] where FileManager.default.fileExists(atPath: url.path) {
            let fileData = try Data(contentsOf: url)
            XCTAssertNil(
                fileData.range(of: transcriptData),
                "Deleted transcript bytes remain in \(url.lastPathComponent)"
            )
        }
    }
}
