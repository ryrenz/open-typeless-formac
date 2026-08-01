import AppKit
import SwiftUI

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var selectedTab: SettingsTab = .hotkeys
    @Published var setupRequirement: AppSetupRequirement?

    func presentSetup(_ requirement: AppSetupRequirement) {
        selectedTab = .api
        setupRequirement = requirement
    }

    func completeSetup() {
        setupRequirement = nil
        selectedTab = .hotkeys
    }
}

@MainActor
final class MainWindowController {
    static let shared = MainWindowController()
    private var window: NSWindow?
    let navigation = SettingsNavigation()

    func show(
        appState: AppState,
        coordinator: DictationSessionCoordinator,
        permissionManager: PermissionManager,
        hotkeyManager: HotkeyManager,
        selectedTab: SettingsTab? = nil,
        setupRequirement: AppSetupRequirement? = nil
    ) {
        navigation.setupRequirement = nil
        if let selectedTab {
            navigation.selectedTab = selectedTab
        }
        if let setupRequirement {
            navigation.presentSetup(setupRequirement)
        }

        if let window = window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = MainWindowView(
            hotkeyManager: hotkeyManager,
            navigation: navigation
        )
            .environmentObject(appState)
            .environmentObject(coordinator)
            .environmentObject(permissionManager)

        let hostingController = NSHostingController(rootView: view)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "OpenTypeless"
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.setContentSize(NSSize(width: 680, height: 600))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    func close() {
        window?.close()
    }
}
