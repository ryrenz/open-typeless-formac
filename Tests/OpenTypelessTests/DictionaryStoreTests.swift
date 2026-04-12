import XCTest
@testable import OpenTypeless

final class DictionaryStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: DictionaryStore!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "DictionaryStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = DictionaryStore(
            defaults: defaults,
            entriesKey: "test.dictionary.entries",
            autoLearnEnabledKey: "test.dictionary.autoLearn"
        )
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        store = nil
        suiteName = nil
        super.tearDown()
    }

    func testAddAndLoadActiveEntries() {
        XCTAssertEqual(store.add("Claude Code"), .added)
        XCTAssertEqual(store.add("Anthropic"), .added)

        let entries = store.activeEntries()
        XCTAssertEqual(entries.map(\.text), ["Claude Code", "Anthropic"])
    }

    func testAddRejectsEmptyAndDuplicateValues() {
        XCTAssertEqual(store.add("   "), .empty)
        XCTAssertEqual(store.add("Claude"), .added)
        XCTAssertEqual(store.add(" claude "), .duplicate)

        XCTAssertEqual(store.loadAll().count, 1)
    }

    func testUpdateAndDisablePersist() {
        XCTAssertEqual(store.add("Claude"), .added)
        guard let entry = store.loadAll().first else {
            XCTFail("Missing entry")
            return
        }

        XCTAssertEqual(store.update(id: entry.id, text: "Claude Code"), .updated)
        store.setEnabled(id: entry.id, isEnabled: false)

        let all = store.loadAll()
        XCTAssertEqual(all.first?.text, "Claude Code")
        XCTAssertEqual(all.first?.isEnabled, false)
        XCTAssertTrue(store.activeEntries().isEmpty)
    }

    func testAutoLearnFlagPersists() {
        XCTAssertFalse(store.autoLearnEnabled())
        store.setAutoLearnEnabled(true)
        XCTAssertTrue(store.autoLearnEnabled())
    }
}
