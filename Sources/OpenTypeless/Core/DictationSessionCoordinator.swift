import Foundation

@MainActor
final class DictationSessionCoordinator: ObservableObject {
    private let audioRecorder = AudioRecorder()
    let transcriptionService: TranscriptionService
    private let dictionaryStore: DictionaryStore
    private let historyStore: HistoryStore
    private let pendingTranscriptionStore: PendingTranscriptionStore
    private let popupController = ResultPopupController()
    private let overlay = ProgressOverlayController.shared
    private var outputSnapshot: OutputTargetSnapshot?
    private var requestConfiguration: TranscriptionRequestConfiguration?
    private var configurationPreparationTask: Task<Void, Never>?
    private var configurationPreparationID: UUID?
    private var processingTask: Task<Void, Never>?
    private var pendingInvalidationRequirement: AppSetupRequirement?
    private var lastToggleTime: Date?
    private let doubleTapThreshold: TimeInterval = 0.4
    var onSetupRequired: ((AppSetupRequirement) -> Void)?

    /// The last transcription result (for test UI in settings)
    @Published var lastTestResult: String = ""

    @Published var appState: AppState

    init(
        appState: AppState,
        transcriptionService: TranscriptionService = TranscriptionService(),
        dictionaryStore: DictionaryStore = .shared,
        historyStore: HistoryStore = .shared,
        pendingTranscriptionStore: PendingTranscriptionStore = .shared
    ) {
        self.appState = appState
        self.transcriptionService = transcriptionService
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
            if configurationPreparationTask == nil {
                startRecording()
            } else {
                cancelPendingRecordingStart()
            }
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
        requestConfiguration = nil
        appState.status = .idle
        overlay.dismiss()
    }

    // MARK: - Recording

    func startRecording() {
        guard appState.status == .idle, configurationPreparationTask == nil else { return }

        let service = transcriptionService
        let preparationID = UUID()
        configurationPreparationID = preparationID
        configurationPreparationTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try service.prepareRequestConfiguration() }
            }.value
            guard let self, configurationPreparationID == preparationID else { return }
            configurationPreparationID = nil
            configurationPreparationTask = nil
            guard appState.status == .idle else { return }
            finishStartingRecording(with: result)
        }
    }

    private func cancelPendingRecordingStart() {
        configurationPreparationID = nil
        configurationPreparationTask?.cancel()
        configurationPreparationTask = nil
        requestConfiguration = nil
    }

    func configurationDidBecomeInvalid(_ requirement: AppSetupRequirement) {
        cancelPendingRecordingStart()
        switch appState.status {
        case .recording:
            cancelRecording()
        case .processing:
            pendingInvalidationRequirement = requirement
            processingTask?.cancel()
        case .idle, .error:
            break
        }
        onSetupRequired?(requirement)
    }

    func currentSetupRequirement() async -> AppSetupRequirement? {
        let service = transcriptionService
        let result = await Task.detached(priority: .userInitiated) {
            Result { try service.prepareRequestConfiguration() }
        }.value
        switch result {
        case .success:
            return nil
        case .failure(let error):
            return AppSetupRequirement(error: error)
                ?? .credentialStoreUnavailable(error.localizedDescription)
        }
    }

    private func finishStartingRecording(
        with result: Result<TranscriptionRequestConfiguration, Error>
    ) {
        do {
            let configuration = try result.get()
            try transcriptionService.validatePreparedConfiguration(configuration)
            requestConfiguration = configuration
            try audioRecorder.startRecording()
            appState.status = .recording
            overlay.audioLevelProvider = { [weak self] in
                self?.audioRecorder.currentLevel() ?? 0
            }
            overlay.show(state: .recording)
        } catch {
            requestConfiguration = nil
            appState.status = .idle
            if let requirement = AppSetupRequirement(error: error) {
                onSetupRequired?(requirement)
                return
            }
            showError("Failed to start recording: \(error.localizedDescription)")
        }
    }

    func stopAndProcess() {
        guard appState.status == .recording else { return }

        outputSnapshot = OutputTargetSnapshot.capture()
        appState.status = .processing
        overlay.update(state: .transcribing)

        processingTask = Task { [weak self] in
            await self?.processRecording()
            self?.processingTask = nil
        }
    }

    // MARK: - Processing pipeline

    private func processRecording() async {
        defer { pendingInvalidationRequirement = nil }
        let audioURL: URL
        do {
            audioURL = try audioRecorder.stopRecording()
        } catch {
            requestConfiguration = nil
            outputSnapshot = nil
            appState.status = .idle
            showError("Recording failed: \(error.localizedDescription)")
            return
        }

        var shouldCleanUpAudio = true
        defer {
            requestConfiguration = nil
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
                configuration: requestConfiguration,
                onProgress: { [weak self] current, total in
                    self?.overlay.updateTranscriptionProgress(
                        current: current,
                        total: total
                    )
                }
            )
            try Task.checkCancellation()
        } catch {
            let setupWasAlreadyPresented = pendingInvalidationRequirement != nil
            if let requirement = AppSetupRequirement(error: error)
                ?? pendingInvalidationRequirement {
                overlay.dismiss()
                appState.status = .idle
                outputSnapshot = nil
                if !setupWasAlreadyPresented {
                    onSetupRequired?(requirement)
                }
            } else if case TranscriptionError.partialResult(let text, _, _, _) = error {
                shouldCleanUpAudio = false
                handlePartialResult(
                    text,
                    audioURL: audioURL,
                    error: error
                )
            } else {
                shouldCleanUpAudio = false
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
        case .insertedViaAX, .pasteShortcutPosted:
            handlePostInsertionObservation(originalText: correctedText)
            break
        case .showPopup(let text):
            popupController.show(text: text)
        case .showRecoveryPopup(let text, let recoveryWindow):
            let duration = recoveryWindow.durationSeconds
            let message = """
            Automatic insertion could not be verified. The transcription will remain in your clipboard for \(duration) seconds. If it did not appear in the target app, press Command-V within \(duration) seconds or use Copy below at any time.

            \(text)
            """
            popupController.show(
                text: message,
                copyText: text,
                presentation: .preserveTargetFocus
            )
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
        let clipboardRecoveryWindow = InsertionStrategy
            .stageTemporaryClipboardRecovery(correctedText)

        handleRecoverableFailure(
            audioURL: audioURL,
            partialText: correctedText,
            clipboardRecoveryWindow: clipboardRecoveryWindow,
            error: error
        )
    }

    private func handleRecoverableFailure(
        audioURL: URL,
        partialText: String?,
        clipboardRecoveryWindow: ClipboardRecoveryWindow? = nil,
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
            let textRecoveryMessage: String
            if let clipboardRecoveryWindow {
                textRecoveryMessage = """
                The recovered text is in history and will remain in your clipboard for \(clipboardRecoveryWindow.durationSeconds) seconds. Use Copy below at any time.
                """
            } else {
                textRecoveryMessage = """
                The recovered text is in history. It could not be written to the clipboard; use Copy below to try again.
                """
            }
            if isPersisted {
                message = """
                Transcription was only partially completed. \(textRecoveryMessage)

                The original recording was saved for recovery:
                \(recoveryURL.path)
                """
            } else {
                message = """
                Transcription was only partially completed. \(textRecoveryMessage)

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
