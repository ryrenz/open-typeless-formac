import ApplicationServices
import SwiftUI

@main
struct OpenTypelessApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appDelegate.appState)
                .environmentObject(appDelegate.coordinator)
                .environmentObject(appDelegate.permissionManager)
                .environmentObject(appDelegate)
        } label: {
            Label(appDelegate.appState.menuBarTitle, systemImage: appDelegate.appState.menuBarIcon)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let appState = AppState()
    let coordinator: DictationSessionCoordinator
    let hotkeyManager = HotkeyManager()
    let permissionManager = PermissionManager()
    private var accessibilityTimer: Timer?
    private var configurationNavigationGeneration: UInt = 0

    override init() {
        self.coordinator = DictationSessionCoordinator(appState: appState)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Task.detached(priority: .utility) {
            do {
                _ = try TranscriptionConfigurationStore.shared.loadOrMigrate()
            } catch {
                print("[OpenTypeless] Configuration migration failed: \(error.localizedDescription)")
            }
        }

        // Load saved hotkey config
        if let config = HotkeyStore.loadConfig() {
            hotkeyManager.config = config
        }

        // Wire up toggle callback
        hotkeyManager.onHotkeyPressed = { [weak self] action in
            Task { @MainActor in
                self?.coordinator.handleToggle(action: action)
            }
        }
        coordinator.onSetupRequired = { [weak self] requirement in
            self?.showRequiredSetup(requirement)
        }

        // Pre-load Whisper model in background
        coordinator.preloadModel()

        // Start hotkey manager with accessibility polling
        startHotkeyWithAccessibilityPolling()

        // Open the required setup directly instead of waiting for a failed recording.
        let startupNavigationGeneration = configurationNavigationGeneration
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            await self?.showStartupSetupIfNeeded(
                expectedGeneration: startupNavigationGeneration
            )
        }
    }

    func showMainWindow() {
        requestMainWindow()
    }

    func showPrivacyPolicy() {
        requestMainWindow(selectedTab: .privacy)
    }

    private func requestMainWindow(selectedTab: SettingsTab? = nil) {
        configurationNavigationGeneration &+= 1
        let generation = configurationNavigationGeneration
        Task { [weak self] in
            guard let self else { return }
            let requirement = await coordinator.currentSetupRequirement()
            guard configurationNavigationGeneration == generation else { return }
            presentMainWindow(
                selectedTab: requirement == nil ? selectedTab : nil,
                setupRequirement: requirement
            )
        }
    }

    private func showStartupSetupIfNeeded(expectedGeneration: UInt) async {
        guard configurationNavigationGeneration == expectedGeneration else { return }
        let requirement = await coordinator.currentSetupRequirement()
        guard configurationNavigationGeneration == expectedGeneration else { return }
        if requirement != nil || !HotkeyStore.isSetupCompleted {
            presentMainWindow(setupRequirement: requirement)
        }
    }

    private func showRequiredSetup(_ requirement: AppSetupRequirement) {
        configurationNavigationGeneration &+= 1
        presentMainWindow(setupRequirement: requirement)
    }

    private func presentMainWindow(
        selectedTab: SettingsTab? = nil,
        setupRequirement: AppSetupRequirement?
    ) {
        MainWindowController.shared.show(
            appState: appState,
            coordinator: coordinator,
            permissionManager: permissionManager,
            hotkeyManager: hotkeyManager,
            selectedTab: selectedTab,
            setupRequirement: setupRequirement
        )
    }

    func applicationWillTerminate(_ notification: Notification) {
        accessibilityTimer?.invalidate()
        accessibilityTimer = nil
        hotkeyManager.stop()
    }

    private func startHotkeyWithAccessibilityPolling() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        print("[OpenTypeless] Accessibility trusted: \(trusted)")

        if trusted {
            if hotkeyManager.start() {
                print("[OpenTypeless] Hotkey manager started successfully")
                accessibilityTimer?.invalidate()
                return
            }
        }

        print("[OpenTypeless] Waiting for Accessibility permission...")
        accessibilityTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self = self else { return }
                if AXIsProcessTrusted() {
                    if self.hotkeyManager.start() {
                        print("[OpenTypeless] Hotkey manager started successfully (after permission grant)")
                        self.accessibilityTimer?.invalidate()
                        self.accessibilityTimer = nil
                    }
                }
            }
        }
    }
}
