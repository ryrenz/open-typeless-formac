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

    override init() {
        self.coordinator = DictationSessionCoordinator(appState: appState)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
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

        // Pre-load Whisper model in background
        coordinator.preloadModel()

        // Start hotkey manager with accessibility polling
        startHotkeyWithAccessibilityPolling()

        // Show setup window on first launch
        if !HotkeyStore.isSetupCompleted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showMainWindow()
            }
        }
    }

    func showMainWindow() {
        MainWindowController.shared.show(
            appState: appState,
            coordinator: coordinator,
            permissionManager: permissionManager,
            hotkeyManager: hotkeyManager
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
