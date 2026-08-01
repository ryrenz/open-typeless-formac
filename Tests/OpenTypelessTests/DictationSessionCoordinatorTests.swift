import XCTest
@testable import OpenTypeless

@MainActor
final class DictationSessionCoordinatorTests: XCTestCase {
    private var defaults: UserDefaults!
    private var dictionaryStore: DictionaryStore!
    private var historyStore: HistoryStore!
    private var historyDBURL: URL!
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
        historyDBURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("DictationSessionCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("history.sqlite", isDirectory: false)
        historyStore = HistoryStore(dbURL: historyDBURL)
    }

    override func tearDown() {
        if let defaults {
            defaults.removePersistentDomain(forName: suiteName)
        }
        historyStore = nil
        if let historyDBURL {
            try? FileManager.default.removeItem(at: historyDBURL)
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: historyDBURL.path + "-wal"))
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: historyDBURL.path + "-shm"))
            try? FileManager.default.removeItem(at: historyDBURL.deletingLastPathComponent())
        }
        defaults = nil
        dictionaryStore = nil
        historyDBURL = nil
        suiteName = nil
        super.tearDown()
    }

    func testInitialStateIsIdle() {
        let appState = AppState()
        let coordinator = DictationSessionCoordinator(
            appState: appState,
            dictionaryStore: dictionaryStore,
            historyStore: historyStore
        )
        XCTAssertEqual(coordinator.appState.status, .idle)
    }

    func testToggleWhileProcessingIsIgnored() {
        let appState = AppState()
        let coordinator = DictationSessionCoordinator(
            appState: appState,
            dictionaryStore: dictionaryStore,
            historyStore: historyStore
        )
        // Manually set processing state
        appState.status = .processing
        // Toggle during processing should be ignored
        coordinator.handleToggle(action: .transcribe)
        XCTAssertEqual(appState.status, .processing)
    }

    func testStopAndProcessWhileIdleIsIgnored() {
        let appState = AppState()
        let coordinator = DictationSessionCoordinator(
            appState: appState,
            dictionaryStore: dictionaryStore,
            historyStore: historyStore
        )
        // stopAndProcess without recording should be ignored
        coordinator.stopAndProcess()
        XCTAssertEqual(appState.status, .idle)
    }

    func testStartRecordingOpensSetupBeforeRecordingWhenAPIKeyIsMissing() async {
        let appState = AppState()
        let service = TranscriptionService(
            apiKeyProvider: { "" },
            dataProcessingConsentProvider: { _ in true }
        )
        let coordinator = DictationSessionCoordinator(
            appState: appState,
            transcriptionService: service,
            dictionaryStore: dictionaryStore,
            historyStore: historyStore
        )
        var requirement: AppSetupRequirement?
        let setupRequired = expectation(description: "Setup required")
        coordinator.onSetupRequired = {
            requirement = $0
            setupRequired.fulfill()
        }

        coordinator.startRecording()
        await fulfillment(of: [setupRequired], timeout: 1)

        XCTAssertEqual(requirement, .apiKeyMissing)
        XCTAssertEqual(appState.status, .idle)
    }

    func testStartRecordingOpensSetupBeforeRecordingWhenConsentIsMissing() async {
        let appState = AppState()
        let service = TranscriptionService(
            apiKeyProvider: { "test-key" },
            dataProcessingConsentProvider: { _ in false }
        )
        let coordinator = DictationSessionCoordinator(
            appState: appState,
            transcriptionService: service,
            dictionaryStore: dictionaryStore,
            historyStore: historyStore
        )
        var requirement: AppSetupRequirement?
        let setupRequired = expectation(description: "Setup required")
        coordinator.onSetupRequired = {
            requirement = $0
            setupRequired.fulfill()
        }

        coordinator.startRecording()
        await fulfillment(of: [setupRequired], timeout: 1)

        XCTAssertEqual(requirement, .dataProcessingConsentRequired)
        XCTAssertEqual(appState.status, .idle)
    }

    func testSecondToggleCancelsPendingRecordingStart() async {
        let appState = AppState()
        let providerStarted = expectation(description: "API key lookup started")
        let releaseProvider = DispatchSemaphore(value: 0)
        let service = TranscriptionService(
            apiKeyProvider: {
                providerStarted.fulfill()
                releaseProvider.wait()
                return ""
            },
            dataProcessingConsentProvider: { _ in true }
        )
        let coordinator = DictationSessionCoordinator(
            appState: appState,
            transcriptionService: service,
            dictionaryStore: dictionaryStore,
            historyStore: historyStore
        )
        var requirement: AppSetupRequirement?
        coordinator.onSetupRequired = { requirement = $0 }

        coordinator.handleToggle(action: .transcribe)
        await fulfillment(of: [providerStarted], timeout: 1)
        coordinator.handleToggle(action: .transcribe)
        releaseProvider.signal()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertNil(requirement)
        XCTAssertEqual(appState.status, .idle)
    }

    func testConsentIsRevalidatedImmediatelyBeforeRecordingStarts() async {
        let appState = AppState()
        var consentCheckCount = 0
        let service = TranscriptionService(
            apiKeyProvider: { "test-key" },
            dataProcessingConsentProvider: { _ in
                consentCheckCount += 1
                return consentCheckCount == 1
            }
        )
        let coordinator = DictationSessionCoordinator(
            appState: appState,
            transcriptionService: service,
            dictionaryStore: dictionaryStore,
            historyStore: historyStore
        )
        let setupRequired = expectation(description: "Setup required")
        var requirement: AppSetupRequirement?
        coordinator.onSetupRequired = {
            requirement = $0
            setupRequired.fulfill()
        }

        coordinator.startRecording()
        await fulfillment(of: [setupRequired], timeout: 1)

        XCTAssertEqual(requirement, .dataProcessingConsentRequired)
        XCTAssertEqual(appState.status, .idle)
    }

    func testMakeTranscriptionPromptUsesActiveDictionaryEntries() {
        let appState = AppState()
        let coordinator = DictationSessionCoordinator(
            appState: appState,
            dictionaryStore: dictionaryStore,
            historyStore: historyStore
        )
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

    func testRecordHistoryStoresFinalText() {
        let appState = AppState()
        let coordinator = DictationSessionCoordinator(
            appState: appState,
            dictionaryStore: dictionaryStore,
            historyStore: historyStore
        )

        coordinator.recordHistory(finalText: "Claude Code")

        XCTAssertEqual(historyStore.loadAll().first?.text, "Claude Code")
    }
}
