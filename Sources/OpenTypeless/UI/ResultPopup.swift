import AppKit
import SwiftUI

enum ResultPopupPresentation {
    case interactive
    case preserveTargetFocus
}

@MainActor
final class ResultPopupController: ObservableObject {
    @Published var isShowing = false
    @Published var resultText = ""
    @Published var showCopiedFeedback = false
    @Published var showCopyFailedFeedback = false

    private var popupWindow: NSWindow?
    private var copyText = ""

    func show(
        text: String,
        copyText: String? = nil,
        presentation: ResultPopupPresentation = .interactive
    ) {
        // Close any existing popup before creating a new one to avoid orphaned windows.
        popupWindow?.close()
        popupWindow = nil

        resultText = text
        self.copyText = copyText ?? text
        isShowing = true
        showCopiedFeedback = false
        showCopyFailedFeedback = false

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
        switch presentation {
        case .interactive:
            window.makeKeyAndOrderFront(nil)
        case .preserveTargetFocus:
            window.orderFrontRegardless()
        }

        // Allow ESC to close
        window.isReleasedWhenClosed = false

        popupWindow = window
    }

    func copyAndDismiss() {
        let pasteboard = NSPasteboard.general
        let originalItems = pasteboard.pasteboardItems?.map(Self.copyPasteboardItem) ?? []
        showCopyFailedFeedback = false

        pasteboard.clearContents()
        guard pasteboard.setString(copyText, forType: .string) else {
            pasteboard.clearContents()
            if !originalItems.isEmpty {
                _ = pasteboard.writeObjects(originalItems)
            }
            showCopyFailedFeedback = true
            return
        }

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

    private static func copyPasteboardItem(_ item: NSPasteboardItem) -> NSPasteboardItem {
        let copy = NSPasteboardItem()
        for type in item.types {
            if let data = item.data(forType: type) {
                copy.setData(data, forType: type)
            }
        }
        return copy
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
                    Text(copyButtonTitle)
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

    private var copyButtonTitle: String {
        if controller.showCopiedFeedback {
            return "Copied!"
        }
        if controller.showCopyFailedFeedback {
            return "Copy failed"
        }
        return "Copy"
    }
}
