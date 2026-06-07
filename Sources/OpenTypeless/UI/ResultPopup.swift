import AppKit
import SwiftUI

@MainActor
final class ResultPopupController: ObservableObject {
    @Published var isShowing = false
    @Published var resultText = ""
    @Published var showCopiedFeedback = false

    private var popupWindow: NSWindow?

    func show(text: String) {
        // Close any existing popup before creating a new one to avoid orphaned windows.
        popupWindow?.close()
        popupWindow = nil

        resultText = text
        isShowing = true
        showCopiedFeedback = false

        let view = ResultPopupView()
            .environmentObject(self)

        let hostingView = NSHostingView(rootView: view)
        hostingView.frame = NSRect(x: 0, y: 0, width: 360, height: 200)

        let window = NSPanel(
            contentRect: hostingView.frame,
            styleMask: [.titled, .closable, .nonactivatingPanel, .utilityWindow, .hudWindow],
            backing: .buffered,
            defer: false
        )
        window.contentView = hostingView
        window.isFloatingPanel = true
        window.level = .floating
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        // Allow ESC to close
        window.isReleasedWhenClosed = false

        popupWindow = window
    }

    func copyAndDismiss() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(resultText, forType: .string)

        showCopiedFeedback = true

        // Dismiss after brief feedback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.dismiss()
        }
    }

    func dismiss() {
        popupWindow?.close()
        popupWindow = nil
        isShowing = false
    }
}

struct ResultPopupView: View {
    @EnvironmentObject var controller: ResultPopupController

    var body: some View {
        VStack(spacing: 12) {
            ScrollView {
                Text(controller.resultText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
            }
            .frame(maxHeight: 120)

            HStack {
                Button(action: { controller.dismiss() }) {
                    Text("Close")
                }
                .keyboardShortcut(.escape, modifiers: [])

                Spacer()

                Button(action: { controller.copyAndDismiss() }) {
                    Text(controller.showCopiedFeedback ? "Copied!" : "Copy")
                        .frame(minWidth: 70)
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(controller.showCopiedFeedback)
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
        .frame(width: 360, height: 200)
    }
}
