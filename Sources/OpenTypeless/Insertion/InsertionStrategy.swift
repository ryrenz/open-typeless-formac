import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import OSLog

private let insertionLogger = Logger(
    subsystem: "com.scinttt.open-typeless",
    category: "Insertion"
)

enum InsertionResult {
    case insertedViaAX
    case pasteShortcutPosted
    case showPopup(String)
    case showRecoveryPopup(String, ClipboardRecoveryWindow)
}

struct ClipboardRecoveryWindow: Equatable {
    static let standard = ClipboardRecoveryWindow(durationSeconds: 10)

    let durationSeconds: Int
}

enum InsertionDeliveryMode: Equatable {
    case accessibilityPreferred
    case clipboardPaste
}

enum InsertionCompatibilityPolicy {
    static func deliveryMode(forBundleIdentifier bundleIdentifier: String?) -> InsertionDeliveryMode {
        switch bundleIdentifier {
        case "com.cmuxterm.app":
            return .clipboardPaste
        default:
            return .accessibilityPreferred
        }
    }
}

struct PreparedInsertionTarget {
    let focusedElement: AXUIElement?
    let canReceivePaste: Bool
    let deliveryMode: InsertionDeliveryMode

    static let unavailable = PreparedInsertionTarget(
        focusedElement: nil,
        canReceivePaste: false,
        deliveryMode: .accessibilityPreferred
    )
}

@MainActor
protocol InsertionEnvironment: AnyObject {
    func prepareTarget(pid: pid_t) async -> PreparedInsertionTarget
    func insertText(
        _ text: String,
        into element: AXUIElement
    ) -> AccessibilityInsertionResult
    func stageTemporaryClipboardRecovery(_ text: String) -> ClipboardRecoveryWindow?
    func postGlobalPasteShortcut(expectedFrontmostPID pid: pid_t) async -> Bool
}

enum InsertionStrategy {
    @MainActor
    static func stageTemporaryClipboardRecovery(
        _ text: String
    ) -> ClipboardRecoveryWindow? {
        LiveInsertionEnvironment.shared.stageTemporaryClipboardRecovery(text)
    }

    @MainActor
    static func insert(text: String, snapshot: OutputTargetSnapshot) async -> InsertionResult {
        await insert(text: text, snapshot: snapshot, environment: LiveInsertionEnvironment.shared)
    }

    @MainActor
    static func insert(
        text: String,
        snapshot: OutputTargetSnapshot,
        environment: any InsertionEnvironment
    ) async -> InsertionResult {
        let hadTarget = snapshot.appPID != nil || snapshot.focusedElement != nil
        var candidates: [AXUIElement] = []
        var canReceivePaste = false
        var deliveryMode = InsertionDeliveryMode.accessibilityPreferred

        if let pid = snapshot.appPID {
            let preparedTarget = await environment.prepareTarget(pid: pid)
            canReceivePaste = preparedTarget.canReceivePaste
            deliveryMode = preparedTarget.deliveryMode
            let modeDescription = deliveryMode == .clipboardPaste
                ? "clipboardPaste"
                : "accessibilityPreferred"
            insertionLogger.info(
                "Prepared target pid=\(pid) mode=\(modeDescription, privacy: .public) canPaste=\(canReceivePaste)"
            )
            if deliveryMode == .accessibilityPreferred,
               let refreshedElement = preparedTarget.focusedElement {
                candidates.append(refreshedElement)
            }
        }

        if deliveryMode == .accessibilityPreferred,
           let capturedElement = snapshot.focusedElement,
           !candidates.contains(where: { CFEqual($0, capturedElement) }) {
            candidates.append(capturedElement)
        }

        candidateLoop: for element in candidates {
            switch environment.insertText(text, into: element) {
            case .inserted:
                return .insertedViaAX
            case .rejected:
                continue
            case .indeterminate:
                canReceivePaste = false
                break candidateLoop
            }
        }

        guard hadTarget else {
            return .showPopup(text)
        }

        // Keep the transcript recoverable while the target consumes Cmd+V.
        // A guarded shortcut dispatch counts as successful delivery; only an
        // explicit dispatch failure should interrupt the user with recovery UI.
        guard let recoveryWindow = environment.stageTemporaryClipboardRecovery(text) else {
            insertionLogger.error(
                "Failed to stage clipboard delivery pid=\(snapshot.appPID ?? -1)"
            )
            return .showPopup(text)
        }
        insertionLogger.notice(
            "Using recoverable clipboard delivery pid=\(snapshot.appPID ?? -1) canPaste=\(canReceivePaste)"
        )
        if canReceivePaste, let pid = snapshot.appPID {
            let didPostPasteShortcut = await environment.postGlobalPasteShortcut(
                expectedFrontmostPID: pid
            )
            if didPostPasteShortcut {
                return .pasteShortcutPosted
            }
        }
        return .showRecoveryPopup(text, recoveryWindow)
    }
}

@MainActor
private final class LiveInsertionEnvironment: InsertionEnvironment {
    static let shared = LiveInsertionEnvironment()

    private var clipboardRestoreTask: Task<Void, Never>?
    private var clipboardRestoreID: UUID?
    private var clipboardOriginalItems: [NSPasteboardItem]?
    private var clipboardExpectedChangeCount: Int?

    func prepareTarget(pid: pid_t) async -> PreparedInsertionTarget {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            return .unavailable
        }

        let deliveryMode = InsertionCompatibilityPolicy.deliveryMode(
            forBundleIdentifier: app.bundleIdentifier
        )
        let bundleIdentifier = app.bundleIdentifier ?? "unknown"
        app.activate()
        for _ in 0..<20 where !app.isActive {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard app.isActive else {
            insertionLogger.error(
                "Target activation failed pid=\(pid) bundle=\(bundleIdentifier, privacy: .public)"
            )
            return PreparedInsertionTarget(
                focusedElement: nil,
                canReceivePaste: false,
                deliveryMode: deliveryMode
            )
        }

        let applicationElement = AXUIElementCreateApplication(pid)
        raiseFocusedWindow(in: applicationElement)
        try? await Task.sleep(nanoseconds: 150_000_000)

        guard let element = focusedElement(in: applicationElement) else {
            return PreparedInsertionTarget(
                focusedElement: nil,
                canReceivePaste: true,
                deliveryMode: deliveryMode
            )
        }

        AXUIElementSetAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            true as CFTypeRef
        )
        try? await Task.sleep(nanoseconds: 50_000_000)

        return PreparedInsertionTarget(
            focusedElement: focusedElement(in: applicationElement) ?? element,
            canReceivePaste: true,
            deliveryMode: deliveryMode
        )
    }

    func insertText(
        _ text: String,
        into element: AXUIElement
    ) -> AccessibilityInsertionResult {
        AccessibilityHelper.insertText(text, into: element)
    }

    func stageTemporaryClipboardRecovery(_ text: String) -> ClipboardRecoveryWindow? {
        let recoveryWindow = ClipboardRecoveryWindow.standard
        let pasteboard = NSPasteboard.general
        let originalItems: [NSPasteboardItem]
        if let clipboardExpectedChangeCount,
           pasteboard.changeCount == clipboardExpectedChangeCount,
           let clipboardOriginalItems {
            originalItems = clipboardOriginalItems
        } else {
            originalItems = pasteboard.pasteboardItems?.map(Self.copyPasteboardItem) ?? []
        }

        clipboardRestoreTask?.cancel()
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            pasteboard.clearContents()
            if !originalItems.isEmpty {
                _ = pasteboard.writeObjects(originalItems)
            }
            clipboardRestoreTask = nil
            clipboardRestoreID = nil
            clipboardOriginalItems = nil
            clipboardExpectedChangeCount = nil
            return nil
        }
        let expectedChangeCount = pasteboard.changeCount
        let restoreID = UUID()
        clipboardOriginalItems = originalItems
        clipboardExpectedChangeCount = expectedChangeCount
        clipboardRestoreID = restoreID

        clipboardRestoreTask = Task { @MainActor [weak self] in
            try? await Task.sleep(
                nanoseconds: UInt64(recoveryWindow.durationSeconds) * 1_000_000_000
            )
            guard !Task.isCancelled,
                  self?.clipboardRestoreID == restoreID else {
                return
            }
            defer {
                self?.clipboardRestoreTask = nil
                self?.clipboardRestoreID = nil
                self?.clipboardOriginalItems = nil
                self?.clipboardExpectedChangeCount = nil
            }
            guard pasteboard.changeCount == expectedChangeCount else { return }

            pasteboard.clearContents()
            if !originalItems.isEmpty {
                pasteboard.writeObjects(originalItems)
            }
            insertionLogger.notice("Restored clipboard after recovery window")
        }
        return recoveryWindow
    }

    func postGlobalPasteShortcut(expectedFrontmostPID pid: pid_t) async -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            insertionLogger.error("Paste target is no longer running pid=\(pid)")
            return false
        }
        guard app.isActive,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            insertionLogger.error("Paste target lost frontmost status pid=\(pid)")
            return false
        }

        let source = CGEventSource(stateID: .hidSystemState)
        guard let keyDown = CGEvent(
            keyboardEventSource: source,
            virtualKey: 0x09,
            keyDown: true
        ), let keyUp = CGEvent(
            keyboardEventSource: source,
            virtualKey: 0x09,
            keyDown: false
        ) else {
            insertionLogger.error("Failed to create global paste events pid=\(pid)")
            return false
        }

        keyDown.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.flags = .maskCommand
        keyUp.post(tap: .cghidEventTap)
        insertionLogger.notice("Posted global paste shortcut for pid=\(pid)")

        try? await Task.sleep(nanoseconds: 250_000_000)
        return true
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

    private func focusedElement(in applicationElement: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedUIElementAttribute as CFString,
            &value
        )

        guard result == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return unsafeBitCast(value, to: AXUIElement.self)
    }

    private func raiseFocusedWindow(in applicationElement: AXUIElement) {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            applicationElement,
            kAXFocusedWindowAttribute as CFString,
            &value
        )

        guard result == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return
        }

        let window = unsafeBitCast(value, to: AXUIElement.self)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }
}
