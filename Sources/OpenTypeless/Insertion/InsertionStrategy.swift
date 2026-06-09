import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

enum InsertionResult {
    case insertedViaAX
    case insertedViaClipboard
    case showPopup(String)
}

enum InsertionStrategy {
    /// Insert text using the best available method, falling back through layers.
    @MainActor
    static func insert(text: String, snapshot: OutputTargetSnapshot) async -> InsertionResult {
        // Layer 1 — direct Accessibility insertion into the captured element.
        // Most reliable: writes straight into the field, never touches the
        // clipboard (so the "old clipboard pasted" race can't happen), and works
        // even if the target app isn't frontmost.
        if let element = snapshot.focusedElement,
           AccessibilityHelper.insertText(text, into: element) {
            return .insertedViaAX
        }

        // Layer 2 — clipboard paste fallback. Optimistic: as long as *something*
        // is focused (terminal, web input, Electron view — whose AX value often
        // isn't settable, so layer 1 fails) we try to paste rather than bailing
        // out to a popup. This is what makes terminals and browser inputs work.
        if snapshot.hasTarget {
            // Re-focus the captured app so the synthetic Cmd+V lands in the field
            // the user was actually looking at, not wherever focus drifted to.
            if let pid = snapshot.appPID,
               let app = NSRunningApplication(processIdentifier: pid),
               !app.isActive {
                app.activate()
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            await clipboardPaste(text: text)
            return .insertedViaClipboard
        }

        // Layer 3 — nothing focused. The transcription is still on the clipboard
        // (left there by the popup's own Copy button) and saved to history.
        return .showPopup(text)
    }

    /// Paste via clipboard, restoring the user's previous clipboard afterwards.
    @MainActor
    private static func clipboardPaste(text: String) async {
        let pasteboard = NSPasteboard.general

        // Snapshot the user's current clipboard so we can restore it later.
        let originalItems = pasteboard.pasteboardItems?.compactMap { item -> (String, Data)? in
            guard let type = item.types.first,
                  let data = item.data(forType: type) else { return nil }
            return (type.rawValue, data)
        }

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let writeChangeCount = pasteboard.changeCount

        simulatePaste()

        // Let the target consume the synthetic Cmd+V before we report back.
        try? await Task.sleep(nanoseconds: 250_000_000)

        // Restore the previous clipboard, but decoupled from the result path and
        // after a generous delay. A slow target (terminal / heavy app) may read
        // the pasteboard well after the keystroke; restoring too eagerly is what
        // caused stale clipboard content to be pasted instead of the transcription.
        if let originalItems {
            scheduleClipboardRestore(originalItems, expectedChangeCount: writeChangeCount)
        }
    }

    /// Restore the previous clipboard after the paste has had time to land.
    /// Skips restoration if the user copied something new in the meantime — a
    /// reader consuming the paste does not bump `changeCount`, but a writer does,
    /// so an unchanged count means it is safe to put the old content back.
    @MainActor
    private static func scheduleClipboardRestore(
        _ items: [(String, Data)],
        expectedChangeCount: Int
    ) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            let pasteboard = NSPasteboard.general
            guard pasteboard.changeCount == expectedChangeCount else { return }

            pasteboard.clearContents()
            for (typeStr, data) in items {
                pasteboard.setData(data, forType: NSPasteboard.PasteboardType(typeStr))
            }
        }
    }

    private static func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key down: Cmd+V (keycode 9 = V)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        keyDown?.flags = .maskCommand
        keyDown?.post(tap: .cghidEventTap)

        // Key up
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand
        keyUp?.post(tap: .cghidEventTap)
    }
}
