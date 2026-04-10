import Foundation

@MainActor
final class DictationSessionCoordinator: ObservableObject {
    private let audioRecorder = AudioRecorder()
    let transcriptionService = TranscriptionService()
    private let popupController = ResultPopupController()
    private let overlay = ProgressOverlayController.shared
    private var outputSnapshot: OutputTargetSnapshot?
    private var lastToggleTime: Date?
    private let doubleTapThreshold: TimeInterval = 0.4

    /// The last transcription result (for test UI in settings)
    @Published var lastTestResult: String = ""

    @Published var appState: AppState

    init(appState: AppState) {
        self.appState = appState
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
            // Temporarily disabled overlay for crash diagnosis
            // overlay.audioLevelProvider = { [weak self] in
            //     self?.audioRecorder.currentLevel() ?? 0
            // }
            // overlay.show(state: .recording)
        } catch {
            appState.status = .idle
            showError("Failed to start recording: \(error.localizedDescription)")
        }
    }

    func stopAndProcess() {
        guard appState.status == .recording else { return }

        outputSnapshot = OutputTargetSnapshot.capture()
        appState.status = .processing
        // overlay.update(state: .transcribing)

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
            transcribedText = try await transcriptionService.transcribe(audioURL: audioURL)
        } catch {
            appState.status = .idle
            showError("Transcription failed: \(error.localizedDescription)")
            return
        }

        // Deliver result
        overlay.dismiss()
        lastTestResult = transcribedText

        guard let snapshot = outputSnapshot else {
            appState.status = .idle
            popupController.show(text: transcribedText)
            return
        }

        let result = await InsertionStrategy.insert(text: transcribedText, snapshot: snapshot)

        switch result {
        case .insertedViaAX, .insertedViaClipboard:
            break
        case .showPopup(let text):
            popupController.show(text: text)
        }

        appState.status = .idle
        outputSnapshot = nil
    }

    // MARK: - Error handling

    private func showError(_ message: String) {
        overlay.flashError()
        appState.flashError()
        popupController.show(text: "Error: \(message)")
    }
}
