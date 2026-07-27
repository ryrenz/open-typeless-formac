import Foundation

@MainActor
final class DictationSessionCoordinator: ObservableObject {
    private let audioRecorder = AudioRecorder()
    let transcriptionService = TranscriptionService()
    private let dictionaryStore: DictionaryStore
    private let historyStore: HistoryStore
    private let pendingTranscriptionStore: PendingTranscriptionStore
    private let popupController = ResultPopupController()
    private let overlay = ProgressOverlayController.shared
    private var outputSnapshot: OutputTargetSnapshot?
    private var lastToggleTime: Date?
    private let doubleTapThreshold: TimeInterval = 0.4

    /// The last transcription result (for test UI in settings)
    @Published var lastTestResult: String = ""

    @Published var appState: AppState

    init(
        appState: AppState,
        dictionaryStore: DictionaryStore = .shared,
        historyStore: HistoryStore = .shared,
        pendingTranscriptionStore: PendingTranscriptionStore = .shared
    ) {
        self.appState = appState
        self.dictionaryStore = dictionaryStore
        self.historyStore = historyStore
        self.pendingTranscriptionStore = pendingTranscriptionStore
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
            await processRecording()
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

        var shouldCleanUpAudio = true
        defer {
            if shouldCleanUpAudio {
                AudioRecorder.cleanUp(url: audioURL)
            }
        }

        if audioRecorder.shouldSkipTranscriptionForSilence() {
            handleNoResult()
            return
        }

        let transcribedText: String
        do {
            transcribedText = try await transcriptionService.transcribe(
                audioURL: audioURL,
                prompt: makeTranscriptionPrompt(),
                silenceRanges: audioRecorder.observedSilenceRanges(),
                onProgress: { [weak self] current, total in
                    self?.overlay.updateTranscriptionProgress(
                        current: current,
                        total: total
                    )
                }
            )
        } catch {
            shouldCleanUpAudio = false
            if case TranscriptionError.partialResult(let text, _, _, _) = error {
                handlePartialResult(
                    text,
                    audioURL: audioURL,
                    error: error
                )
            } else {
                handleRecoverableFailure(
                    audioURL: audioURL,
                    partialText: nil,
                    error: error
                )
            }
            return
        }

        let activeEntries = dictionaryStore.activeEntries()
        let correctedText = DictionaryCorrectionEngine.apply(
            to: transcribedText,
            entries: activeEntries
        )
        if DictionaryHallucinationFilter.shouldSuppress(
            transcribedText: transcribedText,
            correctedText: correctedText,
            peakLevel: audioRecorder.observedPeakLevel(),
            entries: activeEntries
        ) {
            handleNoResult()
            return
        }
        recordHistory(finalText: correctedText)

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

    func recordHistory(finalText: String) {
        historyStore.append(text: finalText)
    }

    private func handleNoResult() {
        overlay.dismiss()
        appState.status = .idle
        outputSnapshot = nil
    }

    private func handlePartialResult(
        _ partialText: String,
        audioURL: URL,
        error: Error
    ) {
        let correctedText = DictionaryCorrectionEngine.apply(
            to: partialText,
            entries: dictionaryStore.activeEntries()
        )
        recordHistory(finalText: correctedText)
        lastTestResult = correctedText
        InsertionStrategy.copyToClipboard(correctedText)

        handleRecoverableFailure(
            audioURL: audioURL,
            partialText: correctedText,
            error: error
        )
    }

    private func handleRecoverableFailure(
        audioURL: URL,
        partialText: String?,
        error: Error
    ) {
        let recoveryURL: URL
        let isPersisted: Bool
        do {
            recoveryURL = try pendingTranscriptionStore.preserve(
                audioURL: audioURL,
                partialText: partialText,
                failureReason: error.localizedDescription
            ).audioURL
            isPersisted = true
        } catch {
            // Leave the original temporary file untouched if preservation fails.
            recoveryURL = audioURL
            isPersisted = false
        }

        overlay.flashError()
        appState.flashError()
        outputSnapshot = nil

        let message: String
        if let partialText, !partialText.isEmpty {
            if isPersisted {
                message = """
                Transcription was only partially completed. The recovered text is in your clipboard and history.

                The original recording was saved for retry:
                \(recoveryURL.path)
                """
            } else {
                message = """
                Transcription was only partially completed. The recovered text is in your clipboard and history.

                The recording could not be moved to persistent storage. Copy it from this temporary path before macOS removes it:
                \(recoveryURL.path)
                """
            }
            popupController.show(text: message, copyText: partialText)
        } else {
            if isPersisted {
                message = """
                Transcription failed, but the original recording was preserved:
                \(recoveryURL.path)

                \(error.localizedDescription)
                """
            } else {
                message = """
                Transcription failed, and the recording could not be moved to persistent storage. Copy it from this temporary path before macOS removes it:
                \(recoveryURL.path)

                \(error.localizedDescription)
                """
            }
            popupController.show(text: message, copyText: recoveryURL.path)
        }
    }

    // MARK: - Error handling

    private func showError(_ message: String) {
        overlay.flashError()
        appState.flashError()
        popupController.show(text: "Error: \(message)")
    }
}
