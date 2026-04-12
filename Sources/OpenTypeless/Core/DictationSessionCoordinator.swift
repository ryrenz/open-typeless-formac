import Foundation

@MainActor
final class DictationSessionCoordinator: ObservableObject {
    private let audioRecorder = AudioRecorder()
    let transcriptionService = TranscriptionService()
    private let dictionaryStore: DictionaryStore
    private let popupController = ResultPopupController()
    private let overlay = ProgressOverlayController.shared
    private var outputSnapshot: OutputTargetSnapshot?
    private var lastToggleTime: Date?
    private let doubleTapThreshold: TimeInterval = 0.4

    /// The last transcription result (for test UI in settings)
    @Published var lastTestResult: String = ""

    @Published var appState: AppState

    init(appState: AppState, dictionaryStore: DictionaryStore = .shared) {
        self.appState = appState
        self.dictionaryStore = dictionaryStore
    }

    func preloadModel() {
        transcriptionService.preload()
    }

    // MARK: - Toggle mode

    func handleToggle(action: HotkeyAction) {
        let now = Date()
        defer { lastToggleTime = now }

        switch appState.status {
        case .idle:
            startRecording()
        case .recording:
            if let last = lastToggleTime, now.timeIntervalSince(last) < doubleTapThreshold {
                cancelRecording()
            } else {
                stopAndProcess()
            }
        case .processing, .error:
            break
        }
    }

    func cancelRecording() {
        guard appState.status == .recording else { return }
        audioRecorder.cancel()
        appState.status = .idle
        overlay.dismiss()
    }

    // MARK: - Recording

    func startRecording() {
        guard appState.status == .idle else { return }

        do {
            try audioRecorder.startRecording()
            appState.status = .recording
            overlay.audioLevelProvider = { [weak self] in
                self?.audioRecorder.currentLevel() ?? 0
            }
            overlay.show(state: .recording)
        } catch {
            appState.status = .idle
            showError("Failed to start recording: \(error.localizedDescription)")
        }
    }

    func stopAndProcess() {
        guard appState.status == .recording else { return }

        outputSnapshot = OutputTargetSnapshot.capture()
        appState.status = .processing
        overlay.update(state: .transcribing)

        Task {
            do {
                await processRecording()
            } catch {
                appState.status = .idle
                overlay.dismiss()
            }
        }
    }

    // MARK: - Processing pipeline

    private func processRecording() async {
        let audioURL: URL
        do {
            audioURL = try audioRecorder.stopRecording()
        } catch {
            appState.status = .idle
            showError("Recording failed: \(error.localizedDescription)")
            return
        }

        defer { AudioRecorder.cleanUp(url: audioURL) }

        let transcribedText: String
        do {
            transcribedText = try await transcriptionService.transcribe(
                audioURL: audioURL,
                prompt: makeTranscriptionPrompt()
            )
        } catch {
            appState.status = .idle
            showError("Transcription failed: \(error.localizedDescription)")
            return
        }

        let correctedText = DictionaryCorrectionEngine.apply(
            to: transcribedText,
            entries: dictionaryStore.activeEntries()
        )

        // Deliver result
        overlay.dismiss()
        lastTestResult = correctedText

        // Skip insertion if focused app is ourselves (settings test area)
        let myPID = ProcessInfo.processInfo.processIdentifier
        guard let snapshot = outputSnapshot, snapshot.appPID != myPID else {
            appState.status = .idle
            if outputSnapshot == nil { popupController.show(text: correctedText) }
            return
        }

        let result = await InsertionStrategy.insert(text: correctedText, snapshot: snapshot)

        switch result {
        case .insertedViaAX, .insertedViaClipboard:
            handlePostInsertionObservation(originalText: correctedText)
            break
        case .showPopup(let text):
            popupController.show(text: text)
        }

        appState.status = .idle
        outputSnapshot = nil
    }

    func makeTranscriptionPrompt() -> String? {
        HotwordPromptBuilder.buildPrompt(from: dictionaryStore.activeEntries())
    }

    func handlePostInsertionObservation(originalText: String) {
        _ = originalText
        // Reserved for future auto-learn hooks.
    }

    // MARK: - Error handling

    private func showError(_ message: String) {
        overlay.flashError()
        appState.flashError()
        popupController.show(text: "Error: \(message)")
    }
}
