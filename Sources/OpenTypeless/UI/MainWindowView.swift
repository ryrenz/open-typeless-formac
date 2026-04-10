import ServiceManagement
import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var coordinator: DictationSessionCoordinator
    @EnvironmentObject var permissionManager: PermissionManager

    let hotkeyManager: HotkeyManager

    @State private var apiKey: String = ""
    @State private var provider: APIProvider = .openAI
    @State private var customHost: String = ""
    @State private var customBasePath: String = ""
    @State private var selectedModel: String = "gpt-4o-mini-transcribe"
    @State private var launchAtLogin: Bool = false
    @State private var transcribeShortcut: StoredShortcut?
    @State private var saveStatus: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                permissionsSection
                shortcutSection
                apiKeySection
                generalSection
                testSection
                actionBar
            }
            .padding(24)
        }
        .frame(width: 500, height: 480)
        .onAppear {
            loadSettings()
        }
    }

    // MARK: - Permissions

    private var permissionsSection: some View {
        GroupBox("Permissions") {
            VStack(alignment: .leading, spacing: 8) {
                permissionRow(
                    name: "Microphone",
                    granted: permissionManager.microphoneGranted,
                    action: {
                        Task { await permissionManager.requestMicrophone() }
                    }
                )
                permissionRow(
                    name: "Accessibility",
                    granted: permissionManager.accessibilityGranted,
                    action: {
                        permissionManager.requestAccessibility()
                        permissionManager.openAccessibilitySettings()
                    }
                )
                if !permissionManager.accessibilityGranted {
                    Text("After granting, toggle the switch off then on if it doesn't update.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
    }

    private func permissionRow(name: String, granted: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(granted ? .green : .red)
            Text(name)
            Spacer()
            if !granted {
                Button("Grant Access") { action() }
                    .buttonStyle(.bordered)
            } else {
                Text("Granted")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
    }

    // MARK: - Shortcuts

    private var shortcutSection: some View {
        GroupBox("Hotkeys") {
            VStack(alignment: .leading, spacing: 8) {
                ShortcutRecorderView(
                    label: "Transcribe:",
                    shortcut: $transcribeShortcut,
                    onRecordStart: { hotkeyManager.pause() },
                    onRecordEnd: { hotkeyManager.resume() }
                )
                Text("Default: Right Option (Alt). Press once to start, press again to stop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Double-press to cancel recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
        }
    }

    // MARK: - API Key

    private var apiKeySection: some View {
        GroupBox("Speech-to-Text API") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Provider", selection: $provider) {
                    ForEach(APIProvider.allCases) { p in
                        Text(p.displayName).tag(p)
                    }
                }
                .pickerStyle(.segmented)

                SecureField("API Key", text: $apiKey)
                    .textFieldStyle(.roundedBorder)

                Picker("Model", selection: $selectedModel) {
                    Text("gpt-4o-mini-transcribe ($0.003/min)").tag("gpt-4o-mini-transcribe")
                    Text("gpt-4o-transcribe ($0.006/min)").tag("gpt-4o-transcribe")
                    Text("whisper-1 ($0.006/min)").tag("whisper-1")
                }
                .pickerStyle(.menu)

                if provider == .custom {
                    TextField("Host (e.g. space.ai-builders.com)", text: $customHost)
                        .textFieldStyle(.roundedBorder)
                    TextField("Base Path (e.g. /backend/v1)", text: $customBasePath)
                        .textFieldStyle(.roundedBorder)
                    Text("Must be an OpenAI-compatible API endpoint")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(8)
        }
    }

    // MARK: - General

    private var generalSection: some View {
        GroupBox("General") {
            Toggle("Launch at Login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, newValue in
                    setLaunchAtLogin(newValue)
                }
                .padding(8)
        }
    }

    // MARK: - Test Area

    private var testSection: some View {
        GroupBox("Test") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Status:")
                    Text(appState.status.rawValue)
                        .foregroundStyle(appState.status == .recording ? .red : .secondary)
                        .fontWeight(appState.status == .recording ? .bold : .regular)
                }

                Text("Press your hotkey to start recording, press again to stop.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                TextEditor(text: $coordinator.lastTestResult)
                    .frame(height: 60)
                    .border(Color.gray.opacity(0.3))
                    .font(.body)
            }
            .padding(8)
        }
    }

    // MARK: - Action Bar

    private var actionBar: some View {
        HStack {
            Spacer()
            if let status = saveStatus {
                Text(status)
                    .foregroundStyle(.green)
                    .font(.caption)
            }
            Button("Save & Close") {
                saveSettings()
                MainWindowController.shared.close()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    // MARK: - Settings persistence

    private func loadSettings() {
        apiKey = TranscriptionService.apiKey
        provider = TranscriptionService.provider
        customHost = TranscriptionService.customHost
        customBasePath = TranscriptionService.customBasePath
        selectedModel = UserDefaults.standard.string(forKey: "transcriptionModel") ?? TranscriptionService.model
        launchAtLogin = SMAppService.mainApp.status == .enabled
        transcribeShortcut = HotkeyStore.loadTranscribe()

        if let stored = UserDefaults.standard.string(forKey: "apiProvider"),
           let p = APIProvider(rawValue: stored) {
            provider = p
        }
        if let h = UserDefaults.standard.string(forKey: "customHost") { customHost = h }
        if let bp = UserDefaults.standard.string(forKey: "customBasePath") { customBasePath = bp }

        permissionManager.checkAll()
    }

    private func saveSettings() {
        if !apiKey.isEmpty { TranscriptionService.apiKey = apiKey }
        TranscriptionService.provider = provider
        if provider == .custom {
            if !customHost.isEmpty { TranscriptionService.customHost = customHost }
            if !customBasePath.isEmpty { TranscriptionService.customBasePath = customBasePath }
        }
        TranscriptionService.model = selectedModel
        UserDefaults.standard.set(provider.rawValue, forKey: "apiProvider")
        UserDefaults.standard.set(customHost, forKey: "customHost")
        UserDefaults.standard.set(customBasePath, forKey: "customBasePath")
        UserDefaults.standard.set(selectedModel, forKey: "transcriptionModel")

        if let t = transcribeShortcut {
            HotkeyStore.saveTranscribe(t)
        }

        if let config = HotkeyStore.loadConfig() {
            hotkeyManager.config = config
        }

        HotkeyStore.isSetupCompleted = true

        saveStatus = "Saved!"
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            saveStatus = nil
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            print("[OpenTypeless] Launch at login error: \(error)")
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}
