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
    static let standard = ClipboardRecoveryWindow(
        durationSeconds: 10,
        transactionID: nil
    )

    let durationSeconds: Int
    fileprivate let transactionID: UUID?

    static func transaction(id: UUID) -> ClipboardRecoveryWindow {
        ClipboardRecoveryWindow(
            durationSeconds: standard.durationSeconds,
            transactionID: id
        )
    }
}

enum InsertionDeliveryMode: Equatable {
    case accessibilityPreferred
    case clipboardPaste
}

enum ClipboardPasteDeliveryResult: Equatable {
    case verified
    case unverified
    case failed
}

enum ClipboardPasteVerifier {
    static func confirmsInsertion(
        beforeValue: String,
        selectedRange: CFRange,
        afterValue: String,
        insertedText: String
    ) -> Bool {
        guard !insertedText.isEmpty else { return false }
        let expectedValue = AccessibilityHelper.replacingUTF16Range(
            in: beforeValue,
            range: selectedRange,
            with: insertedText
        ).value
        return afterValue == expectedValue
    }
}

@MainActor
protocol ClipboardPasteboardAccess: AnyObject {
    var changeCount: Int { get }
    func clearContents() -> Int
    func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool
    func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool
}

extension NSPasteboard: ClipboardPasteboardAccess {}

enum ClipboardRestoreOutcome: Equatable {
    case restored
    case abandoned
    case stale
    case retryScheduled
    case retryScheduledWithoutTranscript
    case retriesExhausted
    case retriesExhaustedWithoutTranscript
}

@MainActor
final class ClipboardTransactionManager {
    private struct Transaction {
        let id: UUID
        let originalItems: [NSPasteboardItem]
        let stagedText: String
        var expectedChangeCount: Int
        var retryCount = 0
    }

    private let maxRetryCount: Int
    private var transaction: Transaction?

    init(maxRetryCount: Int = 3) {
        self.maxRetryCount = maxRetryCount
    }

    var currentTransactionID: UUID? { transaction?.id }
    var hasPendingTransaction: Bool { transaction != nil }
    var currentRetryCount: Int { transaction?.retryCount ?? 0 }

    func originalItemsForRestaging(currentChangeCount: Int) -> [NSPasteboardItem]? {
        guard transaction?.expectedChangeCount == currentChangeCount else { return nil }
        return transaction?.originalItems
    }

    func begin(
        id: UUID,
        originalItems: [NSPasteboardItem],
        stagedText: String,
        expectedChangeCount: Int
    ) {
        transaction = Transaction(
            id: id,
            originalItems: originalItems,
            stagedText: stagedText,
            expectedChangeCount: expectedChangeCount
        )
    }

    func restore(
        transactionID: UUID,
        on pasteboard: any ClipboardPasteboardAccess
    ) -> ClipboardRestoreOutcome {
        guard var transaction, transaction.id == transactionID else {
            return .stale
        }
        guard pasteboard.changeCount == transaction.expectedChangeCount else {
            self.transaction = nil
            return .abandoned
        }

        _ = pasteboard.clearContents()
        let didRestore = transaction.originalItems.isEmpty
            || pasteboard.writeObjects(transaction.originalItems)
        guard didRestore else {
            transaction.retryCount += 1
            _ = pasteboard.clearContents()
            let didRestageTranscript = pasteboard.setString(
                transaction.stagedText,
                forType: .string
            )
            transaction.expectedChangeCount = pasteboard.changeCount
            self.transaction = transaction
            if transaction.retryCount <= maxRetryCount {
                return didRestageTranscript
                    ? .retryScheduled
                    : .retryScheduledWithoutTranscript
            }
            return didRestageTranscript
                ? .retriesExhausted
                : .retriesExhaustedWithoutTranscript
        }

        self.transaction = nil
        return .restored
    }

    func clearPasteboardAfterExhaustedRestore(
        transactionID: UUID,
        on pasteboard: any ClipboardPasteboardAccess
    ) -> Bool {
        guard var transaction,
              transaction.id == transactionID,
              transaction.retryCount > maxRetryCount,
              pasteboard.changeCount == transaction.expectedChangeCount else {
            return false
        }

        _ = pasteboard.clearContents()
        transaction.expectedChangeCount = pasteboard.changeCount
        self.transaction = transaction
        return true
    }
}

enum InsertionCompatibilityPolicy {
    static func deliveryMode(forBundleIdentifier bundleIdentifier: String?) -> InsertionDeliveryMode {
        switch bundleIdentifier {
        case "com.cmuxterm.app", "com.apple.Terminal":
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
    func restoreClipboardAfterVerifiedPaste(_ recoveryWindow: ClipboardRecoveryWindow)
    func postGlobalPasteShortcut(
        expectedFrontmostPID pid: pid_t,
        expectedText text: String
    ) async -> ClipboardPasteDeliveryResult
}

enum InsertionStrategy {
    // AX value replacement is intentionally bounded. Large payloads can make
    // accessibility clients read and rewrite an entire document or terminal
    // buffer, which is slow and can report a false success. Clipboard paste is
    // the recoverable delivery path for those payloads.
    static let maxDirectAXTextUTF16Length = 4_096

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
        let canUseDirectAX = text.utf16.count <= maxDirectAXTextUTF16Length
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
               canUseDirectAX,
               let refreshedElement = preparedTarget.focusedElement {
                candidates.append(refreshedElement)
            }
        }

        if deliveryMode == .accessibilityPreferred,
           canUseDirectAX,
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
        // Posting an event is not an acknowledgement from the target app, so
        // only an observed AX value change counts as silent success.
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
            let pasteDelivery = await environment.postGlobalPasteShortcut(
                expectedFrontmostPID: pid,
                expectedText: text
            )
            if pasteDelivery == .verified {
                environment.restoreClipboardAfterVerifiedPaste(recoveryWindow)
                return .pasteShortcutPosted
            }
        }
        return .showRecoveryPopup(text, recoveryWindow)
    }
}

@MainActor
private final class LiveInsertionEnvironment: InsertionEnvironment {
    static let shared = LiveInsertionEnvironment()
    private static let accessibilityMessagingTimeout: Float = 0.5
    private static let maxPasteVerificationValueUTF16Length = 200_000

    // Reading arbitrary pasteboard types can synchronously invoke lazy data
    // providers in other apps (notably images and file promises). Capture only
    // bounded text-like types to avoid the known high-risk providers and limit
    // the amount of data retained for recovery.
    private static let safeClipboardTypeRawValues: Set<String> = [
        NSPasteboard.PasteboardType.string.rawValue,
        NSPasteboard.PasteboardType.URL.rawValue,
        NSPasteboard.PasteboardType.html.rawValue,
        "public.utf8-plain-text",
        "public.utf16-plain-text",
        "public.url",
    ]
    private static let maxClipboardRecoveryDataBytes = 1_048_576
    private static let maxClipboardRecoveryTotalDataBytes = 2_097_152
    private static let maxClipboardRecoveryItemCount = 8
    private static let maxClipboardRecoveryTypesPerItem = 8

    private var clipboardRestoreTask: Task<Void, Never>?
    private let clipboardTransactions = ClipboardTransactionManager()

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
        AXUIElementSetMessagingTimeout(
            applicationElement,
            Self.accessibilityMessagingTimeout
        )
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
        AXUIElementSetMessagingTimeout(element, Self.accessibilityMessagingTimeout)
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
        let pasteboard = NSPasteboard.general
        let sourceChangeCount = pasteboard.changeCount
        let originalItems: [NSPasteboardItem]
        if let pendingOriginalItems = clipboardTransactions
            .originalItemsForRestaging(currentChangeCount: sourceChangeCount) {
            originalItems = pendingOriginalItems
        } else {
            let pasteboardItems = pasteboard.pasteboardItems ?? []
            guard pasteboardItems.count <= Self.maxClipboardRecoveryItemCount,
                  Self.canSnapshotPasteboardItemsWithoutDeferredData(pasteboardItems) else {
                insertionLogger.warning(
                    "Skipped clipboard staging because the original pasteboard is too complex or deferred"
                )
                return nil
            }
            guard pasteboard.changeCount == sourceChangeCount else {
                insertionLogger.warning(
                    "Skipped clipboard snapshot because the pasteboard changed during preflight"
                )
                return nil
            }
            var capturedItems: [NSPasteboardItem] = []
            var snapshotIsComplete = true
            var remainingBytes = Self.maxClipboardRecoveryTotalDataBytes
            for item in pasteboardItems {
                let snapshot = Self.copyPasteboardItem(
                    item,
                    remainingBytes: &remainingBytes
                )
                snapshotIsComplete = snapshotIsComplete && snapshot.isComplete
                if let copiedItem = snapshot.item {
                    capturedItems.append(copiedItem)
                }
            }
            guard snapshotIsComplete else {
                // Never clear a clipboard that contains data we cannot restore
                // without invoking an unsafe or unbounded pasteboard provider.
                insertionLogger.warning(
                    "Skipped clipboard staging because the original pasteboard snapshot was incomplete"
                )
                return nil
            }
            originalItems = capturedItems
        }

        guard pasteboard.changeCount == sourceChangeCount else {
            insertionLogger.warning(
                "Skipped clipboard staging because the pasteboard changed during snapshot"
            )
            return nil
        }

        clipboardRestoreTask?.cancel()
        let restoreID = UUID()
        let recoveryWindow = ClipboardRecoveryWindow.transaction(id: restoreID)
        pasteboard.clearContents()
        let didStageText = pasteboard.setString(text, forType: .string)
        clipboardTransactions.begin(
            id: restoreID,
            originalItems: originalItems,
            stagedText: text,
            expectedChangeCount: pasteboard.changeCount
        )
        guard didStageText else {
            attemptClipboardRestore(
                transactionID: restoreID,
                reason: "failed clipboard staging"
            )
            return nil
        }
        scheduleClipboardRestore(
            transactionID: restoreID,
            afterNanoseconds: UInt64(recoveryWindow.durationSeconds) * 1_000_000_000,
            reason: "recovery window"
        )
        return recoveryWindow
    }

    func restoreClipboardAfterVerifiedPaste(_ recoveryWindow: ClipboardRecoveryWindow) {
        guard let transactionID = recoveryWindow.transactionID,
              clipboardTransactions.currentTransactionID == transactionID else {
            insertionLogger.warning(
                "Ignored stale verified-paste clipboard restore"
            )
            return
        }
        clipboardRestoreTask?.cancel()
        attemptClipboardRestore(
            transactionID: transactionID,
            reason: "verified paste"
        )
    }

    func postGlobalPasteShortcut(
        expectedFrontmostPID pid: pid_t,
        expectedText text: String
    ) async -> ClipboardPasteDeliveryResult {
        guard let app = NSRunningApplication(processIdentifier: pid) else {
            insertionLogger.error("Paste target is no longer running pid=\(pid)")
            return .failed
        }
        guard app.isActive,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            insertionLogger.error("Paste target lost frontmost status pid=\(pid)")
            return .failed
        }

        guard let beforeElement = AccessibilityHelper.getFocusedElement(),
              belongsToProcess(beforeElement, pid: pid) else {
            insertionLogger.error("Cannot validate focused AX element for paste pid=\(pid)")
            return .failed
        }
        let beforeValue = readAXValue(from: beforeElement)
        let beforeSelection = readAXSelectedTextRange(from: beforeElement)
        if beforeValue == nil {
            insertionLogger.warning("Cannot capture AX value before paste pid=\(pid)")
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
            return .failed
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(pid)
        keyUp.postToPid(pid)
        insertionLogger.notice("Posted process-targeted paste shortcut for pid=\(pid)")

        try? await Task.sleep(nanoseconds: 250_000_000)
        guard app.isActive,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
            insertionLogger.error("Paste target lost frontmost status after dispatch pid=\(pid)")
            return .failed
        }

        guard let afterElement = AccessibilityHelper.getFocusedElement(),
              belongsToProcess(afterElement, pid: pid),
              CFEqual(beforeElement, afterElement),
              let afterValue = readAXValue(from: afterElement) else {
            insertionLogger.warning("Paste shortcut posted without AX readback pid=\(pid)")
            return .unverified
        }
        guard let beforeValue,
              let beforeSelection else {
            return .unverified
        }

        if ClipboardPasteVerifier.confirmsInsertion(
            beforeValue: beforeValue,
            selectedRange: beforeSelection,
            afterValue: afterValue,
            insertedText: text
        ) {
            insertionLogger.notice("Verified process-targeted paste delivery for pid=\(pid)")
            return .verified
        }

        insertionLogger.warning("Paste shortcut posted but target value did not confirm text pid=\(pid)")
        return .unverified
    }

    private func readAXValue(from element: AXUIElement) -> String? {
        AXUIElementSetMessagingTimeout(element, Self.accessibilityMessagingTimeout)
        var characterCount: AnyObject?
        if AXUIElementCopyAttributeValue(
            element,
            kAXNumberOfCharactersAttribute as CFString,
            &characterCount
        ) == .success,
           let characterCount = characterCount as? NSNumber,
           characterCount.intValue > Self.maxPasteVerificationValueUTF16Length {
            return nil
        }

        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &value
        ) == .success else {
            return nil
        }
        guard let value = value as? String,
              value.utf16.count <= Self.maxPasteVerificationValueUTF16Length else {
            return nil
        }
        return value
    }

    private func readAXSelectedTextRange(from element: AXUIElement) -> CFRange? {
        AXUIElementSetMessagingTimeout(element, Self.accessibilityMessagingTimeout)
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &value
        ) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID() else {
            return nil
        }

        let rangeValue = value as! AXValue
        guard AXValueGetType(rangeValue) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &range) else { return nil }
        return range
    }

    private func belongsToProcess(_ element: AXUIElement, pid expectedPID: pid_t) -> Bool {
        var actualPID: pid_t = 0
        return AXUIElementGetPid(element, &actualPID) == .success
            && actualPID == expectedPID
    }

    private func scheduleClipboardRestore(
        transactionID: UUID,
        afterNanoseconds: UInt64,
        reason: String
    ) {
        clipboardRestoreTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: afterNanoseconds)
            guard !Task.isCancelled,
                  self?.clipboardTransactions.currentTransactionID == transactionID else {
                return
            }
            self?.attemptClipboardRestore(
                transactionID: transactionID,
                reason: reason
            )
        }
    }

    private func attemptClipboardRestore(
        transactionID: UUID,
        reason: String
    ) {
        switch clipboardTransactions.restore(
            transactionID: transactionID,
            on: NSPasteboard.general
        ) {
        case .restored:
            clipboardRestoreTask = nil
            insertionLogger.notice(
                "Restored clipboard after \(reason, privacy: .public)"
            )
        case .abandoned:
            clipboardRestoreTask = nil
            insertionLogger.notice(
                "Skipped clipboard restore after external pasteboard change"
            )
        case .stale:
            insertionLogger.warning("Ignored stale clipboard restore attempt")
        case .retryScheduled:
            insertionLogger.error(
                "Failed to restore clipboard after \(reason, privacy: .public)"
            )
            scheduleClipboardRestore(
                transactionID: transactionID,
                afterNanoseconds: 250_000_000,
                reason: "restore retry"
            )
        case .retryScheduledWithoutTranscript:
            insertionLogger.error(
                "Failed to restore the clipboard or restage the transcript"
            )
            scheduleClipboardRestore(
                transactionID: transactionID,
                afterNanoseconds: 250_000_000,
                reason: "restore retry"
            )
        case .retriesExhausted:
            clipboardRestoreTask = nil
            _ = clipboardTransactions.clearPasteboardAfterExhaustedRestore(
                transactionID: transactionID,
                on: NSPasteboard.general
            )
            insertionLogger.error(
                "Clipboard restore retries exhausted; cleared the transcript and retained the bounded snapshot"
            )
        case .retriesExhaustedWithoutTranscript:
            clipboardRestoreTask = nil
            _ = clipboardTransactions.clearPasteboardAfterExhaustedRestore(
                transactionID: transactionID,
                on: NSPasteboard.general
            )
            insertionLogger.error(
                "Clipboard and transcript restore retries exhausted; retained the bounded snapshot"
            )
        }
    }

    private static func canSnapshotPasteboardItemsWithoutDeferredData(
        _ items: [NSPasteboardItem]
    ) -> Bool {
        guard items.allSatisfy({ item in
            !item.types.isEmpty
                && item.types.count <= maxClipboardRecoveryTypesPerItem
                && item.types.allSatisfy {
                    safeClipboardTypeRawValues.contains($0.rawValue)
                }
        }) else {
            return false
        }

        var pasteboardReference: Pasteboard?
        guard PasteboardCreate(
            kPasteboardClipboard as CFString,
            &pasteboardReference
        ) == noErr,
              let pasteboardReference else {
            return false
        }
        _ = PasteboardSynchronize(pasteboardReference)

        var itemCount = 0
        guard PasteboardGetItemCount(pasteboardReference, &itemCount) == noErr,
              itemCount == items.count else {
            return false
        }

        for (offset, item) in items.enumerated() {
            var itemID: UnsafeMutableRawPointer?
            guard PasteboardGetItemIdentifier(
                pasteboardReference,
                offset + 1,
                &itemID
            ) == noErr,
                  let itemID else {
                return false
            }

            for type in item.types {
                var flags = PasteboardFlavorFlags()
                guard PasteboardGetItemFlavorFlags(
                    pasteboardReference,
                    itemID,
                    type.rawValue as CFString,
                    &flags
                ) == noErr,
                      !flags.contains(.promised),
                      !flags.contains(.requestOnly) else {
                    return false
                }
            }
        }
        return true
    }

    private static func copyPasteboardItem(
        _ item: NSPasteboardItem,
        remainingBytes: inout Int
    ) -> (item: NSPasteboardItem?, isComplete: Bool) {
        let copy = NSPasteboardItem()
        var didCopyData = false
        var isComplete = true
        for type in item.types {
            guard safeClipboardTypeRawValues.contains(type.rawValue) else {
                isComplete = false
                continue
            }
            guard let data = item.data(forType: type),
                  data.count <= maxClipboardRecoveryDataBytes,
                  data.count <= remainingBytes,
                  copy.setData(data, forType: type) else {
                isComplete = false
                continue
            }
            remainingBytes -= data.count
            didCopyData = true
        }
        return (didCopyData ? copy : nil, isComplete && didCopyData)
    }

    private func focusedElement(in applicationElement: AXUIElement) -> AXUIElement? {
        AXUIElementSetMessagingTimeout(
            applicationElement,
            Self.accessibilityMessagingTimeout
        )
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
        AXUIElementSetMessagingTimeout(
            applicationElement,
            Self.accessibilityMessagingTimeout
        )
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
        AXUIElementSetMessagingTimeout(window, Self.accessibilityMessagingTimeout)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
    }
}
