import SwiftUI

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var coordinator: DictationSessionCoordinator
    @EnvironmentObject var permissionManager: PermissionManager
    @EnvironmentObject var appDelegate: AppDelegate

    var body: some View {
        VStack {
            Text("Status: \(appState.status.rawValue)")
                .padding(.horizontal)

            Divider()

            Button("Settings...") {
                appDelegate.showMainWindow()
            }
            .keyboardShortcut(",", modifiers: .command)

            Button("Privacy Policy...") {
                appDelegate.showPrivacyPolicy()
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q", modifiers: .command)
        }
    }
}
