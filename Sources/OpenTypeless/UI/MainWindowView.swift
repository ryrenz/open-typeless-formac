import ServiceManagement
import SwiftUI

// MARK: - Localization

enum AppLanguage: String, CaseIterable {
    case en = "en"
    case zh = "zh"

    var displayName: String {
        switch self {
        case .en: return "English"
        case .zh: return "中文"
        }
    }

    static var current: AppLanguage {
        get {
            let raw = UserDefaults.standard.string(forKey: "appLanguage") ?? "en"
            return AppLanguage(rawValue: raw) ?? .en
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "appLanguage")
        }
    }
}

struct L {
    let lang: AppLanguage

    // Tabs
    var hotkeys: String { lang == .zh ? "快捷键" : "Hotkeys" }
    var api: String { "API" }
    var test: String { lang == .zh ? "测试" : "Test" }

    // Permissions
    var permissions: String { lang == .zh ? "权限" : "Permissions" }
    var microphone: String { lang == .zh ? "麦克风" : "Microphone" }
    var accessibility: String { lang == .zh ? "辅助功能" : "Accessibility" }
    var grantAccess: String { lang == .zh ? "授权" : "Grant Access" }
    var granted: String { lang == .zh ? "已授权" : "Granted" }
    var accessibilityHint: String {
        lang == .zh
            ? "授权后如未生效，请在系统设置中删除旧条目后重新授权。"
            : "After granting, remove the old entry and re-add via Grant Access."
    }

    // Hotkey
    var hotkey: String { lang == .zh ? "快捷键" : "Hotkey" }
    var transcribe: String { lang == .zh ? "转写：" : "Transcribe:" }
    var hotkeyHint: String {
        lang == .zh
            ? "默认：右 Option (Alt)。按一下开始，再按停止。双击取消。"
            : "Default: Right Option (Alt). Press once to start, press again to stop. Double-press to cancel."
    }

    // General
    var general: String { lang == .zh ? "通用" : "General" }
    var launchAtLogin: String { lang == .zh ? "登录时启动" : "Launch at Login" }
    var language: String { lang == .zh ? "语言" : "Language" }

    // API
    var provider: String { lang == .zh ? "服务商" : "Provider" }
    var apiKey: String { "API Key" }
    var model: String { lang == .zh ? "模型" : "Model" }
    var customHint: String {
        lang == .zh
            ? "必须是 OpenAI 兼容的 API 端点"
            : "Must be an OpenAI-compatible API endpoint"
    }

    // Test
    var recording: String { lang == .zh ? "录音" : "Recording" }
    var result: String { lang == .zh ? "结果" : "Result" }
    var status: String { lang == .zh ? "状态：" : "Status:" }
    var testHint: String {
        lang == .zh
            ? "按快捷键开始录音，再按一下停止。"
            : "Press your hotkey to start recording, press again to stop."
    }

    // Common
    var save: String { lang == .zh ? "保存" : "Save" }
    var saved: String { lang == .zh ? "已保存！" : "Saved!" }
}

// MARK: - Settings Tabs

enum SettingsTab: String, CaseIterable {
    case hotkeys
    case api
    case test

    func label(_ l: L) -> String {
        switch self {
        case .hotkeys: return l.hotkeys
        case .api: return l.api
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

    @State private var selectedTab: SettingsTab = .hotkeys
    @State private var appLanguage: AppLanguage = AppLanguage.current

    private var l: L { L(lang: appLanguage) }

    var body: some View {
        NavigationSplitView {
            VStack {
                List(SettingsTab.allCases, id: \.self, selection: $selectedTab) { tab in
                    Label(tab.label(l), systemImage: tabIcon(tab))
                }
                .listStyle(.sidebar)

                Divider()

                Picker("", selection: $appLanguage) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .onChange(of: appLanguage) { _, newValue in
                    AppLanguage.current = newValue
                }
            }
            .navigationSplitViewColumnWidth(min: 140, ideal: 160)
        } detail: {
            switch selectedTab {
            case .hotkeys:
                HotkeysTabView(hotkeyManager: hotkeyManager, l: l)
                    .environmentObject(permissionManager)
            case .api:
                APITabView(l: l)
            case .test:
                TestTabView(l: l)
                    .environmentObject(appState)
                    .environmentObject(coordinator)
            }
        }
        .frame(width: 560, height: 420)
        .onAppear {
            permissionManager.checkAll()
        }
    }

    private func tabIcon(_ tab: SettingsTab) -> String {
        switch tab {
        case .hotkeys: return "keyboard"
        case .api: return "key"
        case .test: return "mic"
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

struct APITabView: View {
    let l: L
    @State private var apiKey: String = ""
    @State private var provider: APIProvider = .openAI
    @State private var customHost: String = ""
    @State private var customBasePath: String = ""
    @State private var selectedModel: String = "gpt-4o-mini-transcribe"
    @State private var saveStatus: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            GroupBox(l.provider) {
                VStack(alignment: .leading, spacing: 8) {
                    Picker(l.provider, selection: $provider) {
                        ForEach(APIProvider.allCases) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .pickerStyle(.segmented)

                    if provider == .custom {
                        TextField("Host (e.g. space.ai-builders.com)", text: $customHost)
                            .textFieldStyle(.roundedBorder)
                        TextField("Base Path (e.g. /backend/v1)", text: $customBasePath)
                            .textFieldStyle(.roundedBorder)
                        Text(l.customHint)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
            }

            GroupBox(l.apiKey) {
                SecureField(l.apiKey, text: $apiKey)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: apiKey) { _, newValue in
                        TranscriptionService.apiKey = newValue
                    }
                    .padding(8)
            }

            GroupBox(l.model) {
                Picker(l.model, selection: $selectedModel) {
                    Text("gpt-4o-mini-transcribe ($0.003/min)").tag("gpt-4o-mini-transcribe")
                    Text("gpt-4o-transcribe ($0.006/min)").tag("gpt-4o-transcribe")
                    Text("whisper-1 ($0.006/min)").tag("whisper-1")
                }
                .pickerStyle(.menu)
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
        apiKey = TranscriptionService.apiKey
        provider = TranscriptionService.provider
        customHost = TranscriptionService.customHost
        customBasePath = TranscriptionService.customBasePath
        selectedModel = UserDefaults.standard.string(forKey: "transcriptionModel") ?? TranscriptionService.model

        if let stored = UserDefaults.standard.string(forKey: "apiProvider"),
           let p = APIProvider(rawValue: stored) { provider = p }
        if let h = UserDefaults.standard.string(forKey: "customHost") { customHost = h }
        if let bp = UserDefaults.standard.string(forKey: "customBasePath") { customBasePath = bp }
    }

    private func save() {
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

        saveStatus = l.saved
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { saveStatus = nil }
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
