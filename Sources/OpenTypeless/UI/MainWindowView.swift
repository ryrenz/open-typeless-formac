import ServiceManagement
import SwiftUI

struct L {
    // Tabs
    var hotkeys: String { "Hotkeys" }
    var dictionary: String { "Dictionary" }
    var history: String { "History" }
    var failedRecordings: String { "Failed Recordings" }
    var api: String { "API" }
    var privacy: String { "Privacy" }
    var test: String { "Test" }

    // Permissions
    var permissions: String { "Permissions" }
    var microphone: String { "Microphone" }
    var accessibility: String { "Accessibility" }
    var grantAccess: String { "Grant Access" }
    var granted: String { "Granted" }
    var accessibilityHint: String {
        "If permission keeps resetting after rebuilds, configure stable local signing first. See README."
    }

    // Hotkey
    var hotkey: String { "Hotkey" }
    var transcribe: String { "Transcribe:" }
    var hotkeyHint: String {
        "Default: Right Option (Alt). Press once to start, press again to stop. Double-press to cancel."
    }

    // General
    var general: String { "General" }
    var launchAtLogin: String { "Launch at Login" }

    // API
    var provider: String { "Provider" }
    var apiKey: String { "API Key" }
    var model: String { "Model" }
    var customHint: String {
        "Must be an OpenAI-compatible API endpoint"
    }
    var customModelHint: String {
        "Enter the model ID provided by the service"
    }
    var apiKeySaved: String {
        "The API key is stored securely in macOS Keychain. Enter a new key to replace it."
    }
    var apiKeyMissing: String {
        "The API key is stored only in Keychain on this Mac."
    }
    var deleteAPIKey: String { "Delete API Key" }
    var deleteAPIKeyConfirmation: String {
        "Transcription will be unavailable until you save a new API key."
    }
    var cancel: String { "Cancel" }
    var dataProcessing: String { "Data Processing" }
    var dataProcessingDisclosure: String {
        "During transcription, audio, dictionary hints, and generated text are sent to the endpoint below. The OpenTypeless developer does not receive this content; the provider may process or retain it under its own privacy policy."
    }
    var dataProcessingConsent: String {
        "I understand and agree to send this data to the selected provider"
    }

    // Test
    var recording: String { "Recording" }
    var result: String { "Result" }
    var status: String { "Status:" }
    var testHint: String {
        "Press your hotkey to start recording, press again to stop."
    }

    // Common
    var save: String { "Save" }
    var saved: String { "Saved!" }
}

// MARK: - Settings Tabs

enum SettingsTab: String, CaseIterable {
    case hotkeys
    case dictionary
    case history
    case failedRecordings
    case api
    case privacy
    case test

    func label(_ l: L) -> String {
        switch self {
        case .hotkeys: return l.hotkeys
        case .dictionary: return l.dictionary
        case .history: return l.history
        case .failedRecordings: return l.failedRecordings
        case .api: return l.api
        case .privacy: return l.privacy
        case .test: return l.test
        }
    }
}

// MARK: - Main Window

struct MainWindowView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var coordinator: DictationSessionCoordinator
    @EnvironmentObject var permissionManager: PermissionManager

    let hotkeyManager: HotkeyManager
    @ObservedObject var navigation: SettingsNavigation

    private let l = L()

    var body: some View {
        Group {
            if let requirement = navigation.setupRequirement {
                SetupGateView(
                    requirement: requirement,
                    l: l,
                    onCompleted: {
                        navigation.completeSetup()
                    }
                )
            } else {
                settingsView
            }
        }
        .frame(width: 680, height: 600)
        .onAppear {
            permissionManager.checkAll()
        }
    }

    private var settingsView: some View {
        NavigationSplitView {
            VStack {
                List(
                    SettingsTab.allCases,
                    id: \.self,
                    selection: $navigation.selectedTab
                ) { tab in
                    Label(tab.label(l), systemImage: tabIcon(tab))
                }
                .listStyle(.sidebar)
            }
            .navigationSplitViewColumnWidth(min: 140, ideal: 160)
        } detail: {
            switch navigation.selectedTab {
            case .hotkeys:
                HotkeysTabView(hotkeyManager: hotkeyManager, l: l)
                    .environmentObject(permissionManager)
            case .dictionary:
                DictionaryTabView()
            case .history:
                HistoryTabView()
            case .failedRecordings:
                PendingTranscriptionsTabView()
            case .api:
                APITabView(
                    l: l,
                    mode: .settings,
                    onConfigurationChanged: { requirement in
                        if let requirement {
                            coordinator.configurationDidBecomeInvalid(requirement)
                            navigation.presentSetup(requirement)
                        }
                    }
                )
            case .privacy:
                PrivacyTabView()
            case .test:
                TestTabView(l: l)
                    .environmentObject(appState)
                    .environmentObject(coordinator)
            }
        }
    }

    private func tabIcon(_ tab: SettingsTab) -> String {
        switch tab {
        case .hotkeys: return "keyboard"
        case .dictionary: return "text.book.closed"
        case .history: return "clock.arrow.circlepath"
        case .failedRecordings: return "waveform.badge.exclamationmark"
        case .api: return "key"
        case .privacy: return "hand.raised"
        case .test: return "mic"
        }
    }
}

private struct SetupGateView: View {
    let requirement: AppSetupRequirement
    let l: L
    let onCompleted: () -> Void

    @EnvironmentObject var coordinator: DictationSessionCoordinator
    @State private var isComplete = false

    var body: some View {
        Group {
            if isComplete {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 52))
                        .foregroundStyle(.green)
                    Text("Setup complete")
                        .font(.title2.weight(.semibold))
                    Text("You can now use the hotkey to start dictating.")
                    .foregroundStyle(.secondary)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else {
                APITabView(
                    l: l,
                    mode: .setup(requirement),
                    onConfigurationChanged: { requirement in
                        if let requirement {
                            coordinator.configurationDidBecomeInvalid(requirement)
                            return
                        }
                        withAnimation(.easeOut(duration: 0.18)) {
                            isComplete = true
                        }
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 700_000_000)
                            onCompleted()
                        }
                    }
                )
            }
        }
    }
}

// MARK: - Hotkeys Tab

struct HotkeysTabView: View {
    let hotkeyManager: HotkeyManager
    let l: L
    @EnvironmentObject var permissionManager: PermissionManager

    @State private var transcribeShortcut: StoredShortcut?
    @State private var launchAtLogin: Bool = false
    @State private var saveStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox(l.permissions) {
                VStack(alignment: .leading, spacing: 8) {
                    permissionRow(
                        name: l.microphone,
                        granted: permissionManager.microphoneGranted,
                        action: { Task { await permissionManager.requestMicrophone() } }
                    )
                    permissionRow(
                        name: l.accessibility,
                        granted: permissionManager.accessibilityGranted,
                        action: {
                            permissionManager.requestAccessibility()
                            permissionManager.openAccessibilitySettings()
                        }
                    )
                    if !permissionManager.accessibilityGranted {
                        Text(l.accessibilityHint)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            }

            GroupBox(l.hotkey) {
                VStack(alignment: .leading, spacing: 8) {
                    ShortcutRecorderView(
                        label: l.transcribe,
                        shortcut: $transcribeShortcut,
                        onRecordStart: { hotkeyManager.pause() },
                        onRecordEnd: { hotkeyManager.resume() }
                    )
                    Text(l.hotkeyHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }

            GroupBox(l.general) {
                Toggle(l.launchAtLogin, isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        setLaunchAtLogin(newValue)
                    }
                    .padding(8)
            }

            HStack {
                Spacer()
                if let status = saveStatus {
                    Text(status).foregroundStyle(.green).font(.caption)
                }
                Button(l.save) { save() }
                    .buttonStyle(.borderedProminent)
            }

            Spacer()
        }
        .padding(20)
        .onAppear { load() }
    }

    private func load() {
        transcribeShortcut = HotkeyStore.loadTranscribe()
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func save() {
        if let t = transcribeShortcut {
            HotkeyStore.saveTranscribe(t)
        }
        if let config = HotkeyStore.loadConfig() {
            hotkeyManager.config = config
        }
        HotkeyStore.isSetupCompleted = true
        saveStatus = l.saved
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saveStatus = nil }
    }

    private func permissionRow(name: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            Text(name)
            Spacer()
            if !granted {
                Button(l.grantAccess) { action() }
                    .buttonStyle(.bordered)
            } else {
                Text(l.granted).foregroundStyle(.secondary).font(.caption)
            }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

// MARK: - API Tab

enum APIConfigurationMode: Equatable {
    case settings
    case setup(AppSetupRequirement)
}

struct APITabView: View {
    let l: L
    let mode: APIConfigurationMode
    let onConfigurationChanged: (AppSetupRequirement?) -> Void

    @State private var apiKey: String = ""
    @State private var provider: APIProvider = .openAI
    @State private var customHost: String = ""
    @State private var customBasePath: String = ""
    @State private var selectedModel: String = StoredTranscriptionConfiguration.defaultModel
    @State private var saveStatus: String?
    @State private var saveFailed = false
    @State private var hasStoredKey = false
    @State private var showsDeleteKeyConfirmation = false
    @State private var hasDataProcessingConsent = false
    @State private var isKeyOperationInProgress = false
    @State private var hasFinishedInitialLoad = false
    @State private var configurationRecoveryRequired = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if isSetupMode {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(
                            "Finish setting up OpenTypeless",
                            systemImage: "waveform.and.mic"
                        )
                        .font(.title2.weight(.semibold))
                        Text(setupReason)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.bottom, 4)
                }

                GroupBox(l.provider) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker(l.provider, selection: Binding(
                            get: { provider },
                            set: {
                                let didChangeProvider = provider != $0
                                provider = $0
                                if didChangeProvider {
                                    clearStoredKeyForDestinationChange()
                                }
                                if !$0.providerPreset.allowsCustomModel {
                                    selectedModel = $0.providerPreset.defaultModel
                                }
                                resetConsentForEditedEndpoint()
                            }
                        )) {
                            ForEach(APIProvider.allCases) { p in
                                Text(p.displayName).tag(p)
                            }
                        }
                        .pickerStyle(.menu)

                        if provider == .custom {
                            TextField("Host (e.g. api.example.com)", text: Binding(
                                get: { customHost },
                                set: {
                                    customHost = $0
                                    clearStoredKeyForDestinationChange()
                                    resetConsentForEditedEndpoint()
                                }
                            ))
                                .textFieldStyle(.roundedBorder)
                            TextField("Base Path (e.g. /v1)", text: Binding(
                                get: { customBasePath },
                                set: {
                                    customBasePath = $0
                                    clearStoredKeyForDestinationChange()
                                    resetConsentForEditedEndpoint()
                                }
                            ))
                                .textFieldStyle(.roundedBorder)
                            Text(l.customHint)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                }

                GroupBox(l.apiKey) {
                    VStack(alignment: .leading, spacing: 4) {
                        SecureField(l.apiKey, text: $apiKey)
                            .textFieldStyle(.roundedBorder)
                        Text(hasStoredKey ? l.apiKeySaved : l.apiKeyMissing)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        if configurationRecoveryRequired {
                            Text("The saved configuration cannot be read. Enter a new API key and save, or reset the saved configuration.")
                            .font(.caption2)
                            .foregroundStyle(.red)
                        }
                        if hasStoredKey || configurationRecoveryRequired {
                            Button(deleteKeyLabel, role: .destructive) {
                                showsDeleteKeyConfirmation = true
                            }
                            .buttonStyle(.borderless)
                            .disabled(isKeyOperationInProgress)
                        }
                    }
                    .padding(8)
                }

                GroupBox(l.model) {
                    VStack(alignment: .leading, spacing: 6) {
                        if provider.providerPreset.allowsCustomModel {
                            TextField("Model ID", text: $selectedModel)
                                .textFieldStyle(.roundedBorder)
                            Text(l.customModelHint)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        } else {
                            Picker(l.model, selection: $selectedModel) {
                                ForEach(provider.providerPreset.modelOptions) { option in
                                    Text(option.displayName).tag(option.id)
                                }
                            }
                            .pickerStyle(.menu)
                        }
                    }
                    .padding(8)
                }

                GroupBox(l.dataProcessing) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(l.dataProcessingDisclosure)
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        HStack(spacing: 10) {
                            Image(systemName: "arrow.up.right.circle.fill")
                                .font(.title2)
                                .foregroundStyle(Color.accentColor)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Audio will be sent to")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(dataProcessingEndpoint.displayAddress)
                                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                                    .textSelection(.enabled)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(
                            Color.accentColor.opacity(0.08),
                            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                        )

                        Text("A new provider or address requires confirmation. Returning to the exact same approved address restores consent automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        Toggle(
                            l.dataProcessingConsent,
                            isOn: Binding(
                                get: { hasDataProcessingConsent },
                                set: { updateDataProcessingConsent($0) }
                            )
                        )
                        .toggleStyle(.checkbox)
                        .font(.callout.weight(.medium))

                        PrivacyPolicyButton()

                        if !isSetupMode {
                            Button(
                                "Revoke consent for all saved destinations",
                                role: .destructive
                            ) {
                                revokeAllDataProcessingConsent()
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                    .padding(8)
                }

                HStack {
                    if let status = saveStatus {
                        Text(status)
                            .foregroundStyle(saveFailed ? .red : .green)
                            .font(.caption)
                    }
                    Spacer()
                    Button(isSetupMode ? continueLabel : l.save) { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(
                            isKeyOperationInProgress
                                || (isSetupMode && !canCompleteSetup)
                        )
                }
            }
            .padding(20)
            .disabled(isKeyOperationInProgress)
        }
        .onAppear { load() }
        .confirmationDialog(
            deleteKeyLabel,
            isPresented: $showsDeleteKeyConfirmation,
            titleVisibility: .visible
        ) {
            Button(deleteKeyLabel, role: .destructive) { deleteAPIKey() }
            Button(l.cancel, role: .cancel) {}
        } message: {
            Text(deleteKeyConfirmation)
        }
    }

    private func load() {
        apiKey = ""
        guard !isKeyOperationInProgress else { return }
        isKeyOperationInProgress = true
        Task {
            defer {
                isKeyOperationInProgress = false
                hasFinishedInitialLoad = true
            }
            do {
                let configuration = try await Task.detached(priority: .userInitiated) {
                    try TranscriptionConfigurationTransaction.perform {
                        try TranscriptionConfigurationStore.shared.loadOrMigrate()
                    }
                }.value
                provider = configuration.provider
                customHost = configuration.customHost
                customBasePath = configuration.customBasePath
                selectedModel = configuration.provider.providerPreset.normalizedModel(
                    configuration.model
                )
                hasStoredKey = configuration.apiKey != nil
                configurationRecoveryRequired = false
                hasDataProcessingConsent = DataProcessingConsentStore.shared.hasConsent(
                    for: configuration.endpoint
                )
            } catch is TranscriptionConfigurationStoreError {
                hasStoredKey = false
                hasDataProcessingConsent = false
                configurationRecoveryRequired = true
                showStatus(
                    "The saved configuration is damaged or from a newer version. Enter a new API key and save, or reset it.",
                    failed: true
                )
            } catch {
                showStatus(error.localizedDescription, failed: true)
            }
        }
    }

    private func save() {
        guard !isKeyOperationInProgress else { return }
        let endpoint = dataProcessingEndpoint
        guard endpoint.isValid else {
            showStatus(
                "Invalid custom endpoint. Enter only a domain or IP in Host and put the path separately.",
                failed: true
            )
            return
        }
        let trimmedModel = selectedModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty else {
            showStatus(
                "Model ID cannot be empty.",
                failed: true
            )
            return
        }
        let providerToSave = provider
        let modelToSave = provider.providerPreset.normalizedModel(trimmedModel)
        let keyToSave = apiKey
        let consentToSave = hasDataProcessingConsent
        let requiresReplacement = configurationRecoveryRequired
        let normalizedCustomEndpoint = DataProcessingEndpoint.current(
            provider: .custom,
            customHost: customHost,
            customBasePath: customBasePath
        )
        isKeyOperationInProgress = true
        Task {
            defer { isKeyOperationInProgress = false }
            do {
                let hasStoredKeyAfterSave = try await Task.detached(priority: .userInitiated) {
                    try TranscriptionConfigurationTransaction.perform {
                        let hasNewKey = !keyToSave
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                        var configuration: StoredTranscriptionConfiguration
                        if requiresReplacement {
                            guard hasNewKey else {
                                throw APIKeyStoreError.emptyKey
                            }
                            configuration = StoredTranscriptionConfiguration(
                                apiKey: keyToSave,
                                provider: providerToSave,
                                customHost: normalizedCustomEndpoint.host,
                                customBasePath: normalizedCustomEndpoint.basePath,
                                model: modelToSave
                            )
                        } else {
                            configuration = try TranscriptionConfigurationStore.shared
                                .loadOrMigrate()
                            let destinationChanged = configuration.endpoint.fingerprint
                                != endpoint.fingerprint
                            guard !destinationChanged || hasNewKey else {
                                throw APIKeyStoreError.keyRequiredForDestinationChange
                            }
                            if hasNewKey {
                                configuration.apiKey = keyToSave
                            }
                            configuration.provider = providerToSave
                            configuration.customHost = normalizedCustomEndpoint.host
                            configuration.customBasePath = normalizedCustomEndpoint.basePath
                            configuration.model = modelToSave
                        }

                        try TranscriptionConfigurationStore.shared.save(configuration)
                        if consentToSave {
                            DataProcessingConsentStore.shared.grantConsent(for: endpoint)
                        } else {
                            DataProcessingConsentStore.shared.revokeConsent(for: endpoint)
                        }
                        return configuration.apiKey != nil
                    }
                }.value
                if hasStoredKeyAfterSave {
                    apiKey = ""
                }
                hasStoredKey = hasStoredKeyAfterSave
                configurationRecoveryRequired = false
                if providerToSave == .custom {
                    customHost = endpoint.host
                    customBasePath = endpoint.basePath
                }

                if consentToSave {
                    showStatus(l.saved, failed: false)
                } else {
                    showStatus(
                        "Settings saved; consent is required before transcription.",
                        failed: false
                    )
                }
                onConfigurationChanged(currentRequirement)
            } catch {
                showStatus(error.localizedDescription, failed: true)
            }
        }
    }

    private func deleteAPIKey() {
        guard !isKeyOperationInProgress else { return }
        isKeyOperationInProgress = true
        Task {
            defer { isKeyOperationInProgress = false }
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try TranscriptionConfigurationTransaction.perform {
                        try TranscriptionConfigurationStore.shared.deleteAPIKey()
                    }
                }.value
                apiKey = ""
                hasStoredKey = false
                let wasRecoveringConfiguration = configurationRecoveryRequired
                if wasRecoveringConfiguration {
                    DataProcessingConsentStore.shared.revokeConsent()
                }
                configurationRecoveryRequired = false
                onConfigurationChanged(.apiKeyMissing)
                if result.legacyCleanupErrorDescription != nil {
                    showStatus(
                        "The active API key was deleted, but a legacy Keychain copy could not be cleaned up yet. The app will retry automatically.",
                        failed: true
                    )
                } else {
                    showStatus("API key deleted.", failed: false)
                }
            } catch {
                showStatus(error.localizedDescription, failed: true)
            }
        }
    }

    private func showStatus(_ status: String, failed: Bool) {
        saveStatus = status
        saveFailed = failed
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            saveStatus = nil
        }
    }

    private var dataProcessingEndpoint: DataProcessingEndpoint {
        .current(
            provider: provider,
            customHost: customHost,
            customBasePath: customBasePath
        )
    }

    private func resetConsentForEditedEndpoint() {
        hasDataProcessingConsent = DataProcessingConsentStore.shared.hasConsent(
            for: dataProcessingEndpoint
        )
    }

    private func clearStoredKeyForDestinationChange() {
        apiKey = ""
        hasStoredKey = false
    }

    private func updateDataProcessingConsent(_ isGranted: Bool) {
        hasDataProcessingConsent = isGranted
        guard !isGranted else { return }
        DataProcessingConsentStore.shared.revokeConsent(for: dataProcessingEndpoint)
        onConfigurationChanged(.dataProcessingConsentRequired)
    }

    private func revokeAllDataProcessingConsent() {
        DataProcessingConsentStore.shared.revokeConsent()
        hasDataProcessingConsent = false
        onConfigurationChanged(.dataProcessingConsentRequired)
    }

    private var isSetupMode: Bool {
        if case .setup = mode { return true }
        return false
    }

    private var continueLabel: String {
        "Agree and continue"
    }

    private var deleteKeyLabel: String {
        guard configurationRecoveryRequired else { return l.deleteAPIKey }
        return "Reset saved configuration"
    }

    private var deleteKeyConfirmation: String {
        guard configurationRecoveryRequired else { return l.deleteAPIKeyConfirmation }
        return "This removes the unreadable configuration and API key, and revokes all saved data-processing consent."
    }

    private var canCompleteSetup: Bool {
        hasFinishedInitialLoad
            && dataProcessingEndpoint.isValid
            && hasDataProcessingConsent
            && (hasStoredKey || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    private var currentRequirement: AppSetupRequirement? {
        guard hasStoredKey else { return .apiKeyMissing }
        guard dataProcessingEndpoint.isValid else { return .invalidEndpoint }
        guard hasDataProcessingConsent else { return .dataProcessingConsentRequired }
        return nil
    }

    private var setupReason: String {
        guard case .setup(let requirement) = mode else { return "" }
        switch requirement {
        case .apiKeyMissing:
            return "Add an API key and confirm where audio is sent before using dictation."
        case .credentialStoreUnavailable(let detail):
            return "Keychain is temporarily unavailable: \(detail)"
        case .invalidEndpoint:
            return "The current custom endpoint is invalid. Correct it to continue."
        case .dataProcessingConsentRequired:
            return "Confirm the current data recipient to continue using dictation."
        }
    }
}

// MARK: - Test Tab

struct TestTabView: View {
    let l: L
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var coordinator: DictationSessionCoordinator

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox(l.recording) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(l.status)
                        Text(appState.status.rawValue)
                            .foregroundStyle(appState.status == .recording ? .red : .secondary)
                            .fontWeight(appState.status == .recording ? .bold : .regular)
                    }

                    Text(l.testHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
            }

            GroupBox(l.result) {
                TextEditor(text: $coordinator.lastTestResult)
                    .frame(minHeight: 100)
                    .border(Color.gray.opacity(0.3))
                    .font(.body)
                    .padding(8)
            }

            Spacer()
        }
        .padding(20)
    }
}
