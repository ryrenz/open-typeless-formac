import XCTest
@testable import OpenTypeless

@MainActor
final class DictationSessionCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var dictionaryStore: DictionaryStore!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "DictationSessionCoordinatorTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        dictionaryStore = DictionaryStore(
            defaults: defaults,
            entriesKey: "test.dictionary.entries",
            autoLearnEnabledKey: "test.dictionary.autoLearn"
        )
    }

    override func tearDown() {
        if let defaults {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults = nil
        dictionaryStore = nil
        suiteName = nil
        super.tearDown()
    }

    func testInitialStateIsIdle() {
        let appState = AppState()
        let coordinator = DictationSessionCoordinator(appState: appState, dictionaryStore: dictionaryStore)
        XCTAssertEqual(coordinator.appState.status, .idle)
    }

    func testToggleWhileProcessingIsIgnored() {
        let appState = AppState()
        let coordinator = DictationSessionCoordinator(appState: appState, dictionaryStore: dictionaryStore)
        // Manually set processing state
        appState.status = .processing
        // Toggle during processing should be ignored
        coordinator.handleToggle(action: .transcribe)
        XCTAssertEqual(appState.status, .processing)
    }

    func testStopAndProcessWhileIdleIsIgnored() {
        let appState = AppState()
        let coordinator = DictationSessionCoordinator(appState: appState, dictionaryStore: dictionaryStore)
        // stopAndProcess without recording should be ignored
        coordinator.stopAndProcess()
        XCTAssertEqual(appState.status, .idle)
    }

    func testMakeTranscriptionPromptUsesActiveDictionaryEntries() {
        let appState = AppState()
        let coordinator = DictationSessionCoordinator(appState: appState, dictionaryStore: dictionaryStore)
        XCTAssertEqual(dictionaryStore.add("Claude"), .added)
        XCTAssertEqual(dictionaryStore.add("Claude Code"), .added)
        XCTAssertEqual(dictionaryStore.add("Anthropic"), .added)

        guard let claude = dictionaryStore.loadAll().first(where: { $0.text == "Claude" }) else {
            XCTFail("Missing Claude entry")
            return
        }
        dictionaryStore.setEnabled(id: claude.id, isEnabled: false)

        XCTAssertEqual(
            coordinator.makeTranscriptionPrompt(),
            "Prefer these spellings when they match the audio: Claude Code, Anthropic."
        )
    }
}
