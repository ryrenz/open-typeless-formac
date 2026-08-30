import XCTest
@testable import OpenTypeless

final class OutputTargetSnapshotTests: XCTestCase {
    func testSnapshotWithNoFocusedElement() {
        // In test environment, there's no focused AX element
        let snapshot = OutputTargetSnapshot(focusedElement: nil, appPID: nil)
        XCTAssertFalse(snapshot.hasTarget)
        XCTAssertFalse(snapshot.isValid())
    }

    func testSnapshotHasTarget() {
        // Create a snapshot with a dummy element
        let element = AXUIElementCreateSystemWide()
        let snapshot = OutputTargetSnapshot(focusedElement: element, appPID: 1234)
        XCTAssertTrue(snapshot.hasTarget)
        // isValid() will return false since system-wide element is not a text input
        XCTAssertFalse(snapshot.isValid())
    }
}

@MainActor
final class InsertionStrategyTests: XCTestCase {
    func testInsertWithNoTargetShowsPopup() async {
        let snapshot = OutputTargetSnapshot(focusedElement: nil, appPID: nil)
        let environment = MockInsertionEnvironment()
        let result = await InsertionStrategy.insert(
            text: "test",
            snapshot: snapshot,
            environment: environment
        )

        if case .showPopup(let text) = result {
            XCTAssertEqual(text, "test")
        } else {
            XCTFail("Expected showPopup result")
        }
        XCTAssertEqual(environment.clipboardWrites, [])
        XCTAssertEqual(environment.pasteShortcutPIDs, [])
    }

    func testInsertRefreshesFocusedElementBeforeAXInsertion() async {
        let capturedElement = AXUIElementCreateSystemWide()
        let refreshedElement = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let snapshot = OutputTargetSnapshot(
            focusedElement: capturedElement,
            appPID: ProcessInfo.processInfo.processIdentifier
        )
        let environment = MockInsertionEnvironment()
        environment.refreshedElement = refreshedElement
        environment.canReceivePaste = true
        environment.successfulElement = refreshedElement

        let result = await InsertionStrategy.insert(
            text: "fresh",
            snapshot: snapshot,
            environment: environment
        )

        guard case .insertedViaAX = result else {
            return XCTFail("Expected refreshed AX insertion to succeed")
        }
        XCTAssertEqual(environment.preparedPIDs, [ProcessInfo.processInfo.processIdentifier])
        XCTAssertEqual(environment.insertedTexts, ["fresh"])
        XCTAssertEqual(environment.attemptedElements.count, 1)
        XCTAssertTrue(CFEqual(environment.attemptedElements[0], refreshedElement))
        XCTAssertEqual(environment.clipboardWrites, [])
        XCTAssertEqual(environment.pasteShortcutPIDs, [])
    }

    func testInsertUsesCapturedElementWhenTargetRefreshIsUnavailable() async {
        let capturedElement = AXUIElementCreateSystemWide()
        let snapshot = OutputTargetSnapshot(focusedElement: capturedElement, appPID: 1234)
        let environment = MockInsertionEnvironment()
        environment.successfulElement = capturedElement

        let result = await InsertionStrategy.insert(
            text: "captured",
            snapshot: snapshot,
            environment: environment
        )

        guard case .insertedViaAX = result else {
            return XCTFail("Expected captured AX insertion to succeed")
        }
        XCTAssertEqual(environment.attemptedElements.count, 1)
        XCTAssertTrue(CFEqual(environment.attemptedElements[0], capturedElement))
        XCTAssertEqual(environment.clipboardWrites, [])
        XCTAssertEqual(environment.pasteShortcutPIDs, [])
    }

    func testInsertTriesCapturedElementWhenRefreshedElementIsNotWritable() async {
        let capturedElement = AXUIElementCreateSystemWide()
        let refreshedElement = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let snapshot = OutputTargetSnapshot(
            focusedElement: capturedElement,
            appPID: ProcessInfo.processInfo.processIdentifier
        )
        let environment = MockInsertionEnvironment()
        environment.refreshedElement = refreshedElement
        environment.canReceivePaste = true
        environment.successfulElement = capturedElement

        let result = await InsertionStrategy.insert(
            text: "captured fallback",
            snapshot: snapshot,
            environment: environment
        )

        guard case .insertedViaAX = result else {
            return XCTFail("Expected captured AX insertion to succeed")
        }
        XCTAssertEqual(environment.attemptedElements.count, 2)
        XCTAssertTrue(CFEqual(environment.attemptedElements[0], refreshedElement))
        XCTAssertTrue(CFEqual(environment.attemptedElements[1], capturedElement))
        XCTAssertEqual(environment.clipboardWrites, [])
        XCTAssertEqual(environment.pasteShortcutPIDs, [])
    }

    func testSuccessfulClipboardPasteDoesNotShowRecoveryPopup() async {
        let refreshedElement = AXUIElementCreateSystemWide()
        let snapshot = OutputTargetSnapshot(focusedElement: nil, appPID: 1234)
        let environment = MockInsertionEnvironment()
        environment.refreshedElement = refreshedElement
        environment.canReceivePaste = true

        let result = await InsertionStrategy.insert(
            text: "recoverable text",
            snapshot: snapshot,
            environment: environment
        )

        guard case .pasteShortcutPosted = result else {
            return XCTFail("Expected successful clipboard paste delivery")
        }
        XCTAssertEqual(environment.clipboardWrites, ["recoverable text"])
        XCTAssertEqual(environment.pasteShortcutPIDs, [1234])
        XCTAssertEqual(environment.clipboardRestores, 1)
        XCTAssertEqual(
            environment.restoredRecoveryWindows,
            environment.stagedRecoveryWindows
        )
    }

    func testFailedClipboardPasteShowsPopupAndKeepsTranscriptAvailable() async {
        let refreshedElement = AXUIElementCreateSystemWide()
        let snapshot = OutputTargetSnapshot(focusedElement: nil, appPID: 1234)
        let environment = MockInsertionEnvironment()
        environment.refreshedElement = refreshedElement
        environment.canReceivePaste = true
        environment.pasteDeliveryResult = .failed

        let result = await InsertionStrategy.insert(
            text: "recoverable text",
            snapshot: snapshot,
            environment: environment
        )

        guard case .showRecoveryPopup(let text, let recoveryWindow) = result else {
            return XCTFail("Expected failed clipboard paste to show the recovery popup")
        }
        XCTAssertEqual(text, "recoverable text")
        XCTAssertEqual(recoveryWindow.durationSeconds, ClipboardRecoveryWindow.standard.durationSeconds)
        XCTAssertEqual(environment.clipboardWrites, ["recoverable text"])
        XCTAssertEqual(environment.pasteShortcutPIDs, [1234])
        XCTAssertEqual(environment.clipboardRestores, 0)
    }

    func testUnverifiedClipboardPasteShowsRecoveryPopup() async {
        let refreshedElement = AXUIElementCreateSystemWide()
        let snapshot = OutputTargetSnapshot(focusedElement: nil, appPID: 1234)
        let environment = MockInsertionEnvironment()
        environment.refreshedElement = refreshedElement
        environment.canReceivePaste = true
        environment.pasteDeliveryResult = .unverified

        let result = await InsertionStrategy.insert(
            text: "unverified paste",
            snapshot: snapshot,
            environment: environment
        )

        guard case .showRecoveryPopup(let text, let recoveryWindow) = result else {
            return XCTFail("An unverified paste must keep the recovery UI visible")
        }
        XCTAssertEqual(text, "unverified paste")
        XCTAssertEqual(recoveryWindow.durationSeconds, ClipboardRecoveryWindow.standard.durationSeconds)
        XCTAssertEqual(environment.clipboardWrites, ["unverified paste"])
        XCTAssertEqual(environment.pasteShortcutPIDs, [1234])
        XCTAssertEqual(environment.clipboardRestores, 0)
    }

    func testClipboardStagingFailureShowsPopupWithoutPostingPaste() async {
        let snapshot = OutputTargetSnapshot(focusedElement: nil, appPID: 1234)
        let environment = MockInsertionEnvironment()
        environment.canReceivePaste = true
        environment.clipboardStagingSucceeds = false

        let result = await InsertionStrategy.insert(
            text: "unstaged text",
            snapshot: snapshot,
            environment: environment
        )

        guard case .showPopup(let text) = result else {
            return XCTFail("Expected clipboard staging failure to show the result popup")
        }
        XCTAssertEqual(text, "unstaged text")
        XCTAssertEqual(environment.clipboardWrites, ["unstaged text"])
        XCTAssertEqual(environment.pasteShortcutPIDs, [])
    }

    func testUnavailableTargetDoesNotPasteIntoAnotherApplication() async {
        let capturedElement = AXUIElementCreateSystemWide()
        let snapshot = OutputTargetSnapshot(focusedElement: capturedElement, appPID: 1234)
        let environment = MockInsertionEnvironment()

        let result = await InsertionStrategy.insert(
            text: "manual recovery",
            snapshot: snapshot,
            environment: environment
        )

        guard case .showRecoveryPopup(let text, _) = result else {
            return XCTFail("Expected unavailable target to show the recovery popup")
        }
        XCTAssertEqual(text, "manual recovery")
        XCTAssertEqual(environment.clipboardWrites, ["manual recovery"])
        XCTAssertEqual(environment.pasteShortcutPIDs, [])
    }

    func testIndeterminateAXResultDoesNotRetryOrPaste() async {
        let capturedElement = AXUIElementCreateSystemWide()
        let refreshedElement = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let snapshot = OutputTargetSnapshot(
            focusedElement: capturedElement,
            appPID: ProcessInfo.processInfo.processIdentifier
        )
        let environment = MockInsertionEnvironment()
        environment.refreshedElement = refreshedElement
        environment.canReceivePaste = true
        environment.indeterminateElement = refreshedElement

        let result = await InsertionStrategy.insert(
            text: "uncertain result",
            snapshot: snapshot,
            environment: environment
        )

        guard case .showRecoveryPopup(let text, _) = result else {
            return XCTFail("Expected an indeterminate AX result to show recovery")
        }
        XCTAssertEqual(text, "uncertain result")
        XCTAssertEqual(environment.attemptedElements.count, 1)
        XCTAssertTrue(CFEqual(environment.attemptedElements[0], refreshedElement))
        XCTAssertEqual(environment.clipboardWrites, ["uncertain result"])
        XCTAssertEqual(environment.pasteShortcutPIDs, [])
    }

    func testClipboardPasteModeBypassesFalsePositiveAXSuccess() async {
        let refreshedElement = AXUIElementCreateSystemWide()
        let snapshot = OutputTargetSnapshot(focusedElement: nil, appPID: 1234)
        let environment = MockInsertionEnvironment()
        environment.refreshedElement = refreshedElement
        environment.canReceivePaste = true
        environment.deliveryMode = .clipboardPaste
        environment.successfulElement = refreshedElement

        let result = await InsertionStrategy.insert(
            text: "terminal text",
            snapshot: snapshot,
            environment: environment
        )

        guard case .pasteShortcutPosted = result else {
            return XCTFail("Expected successful clipboard-paste delivery")
        }
        XCTAssertEqual(environment.attemptedElements.count, 0)
        XCTAssertEqual(environment.clipboardWrites, ["terminal text"])
        XCTAssertEqual(environment.pasteShortcutPIDs, [1234])
    }

    func testLongTextUsesRecoverableClipboardDeliveryInsteadOfAX() async {
        let refreshedElement = AXUIElementCreateSystemWide()
        let snapshot = OutputTargetSnapshot(focusedElement: nil, appPID: 1234)
        let environment = MockInsertionEnvironment()
        environment.refreshedElement = refreshedElement
        environment.canReceivePaste = true
        environment.successfulElement = refreshedElement
        let text = String(repeating: "long transcript ", count: 400)

        let result = await InsertionStrategy.insert(
            text: text,
            snapshot: snapshot,
            environment: environment
        )

        guard case .pasteShortcutPosted = result else {
            return XCTFail("Long text should use recoverable clipboard delivery")
        }
        XCTAssertGreaterThan(text.utf16.count, InsertionStrategy.maxDirectAXTextUTF16Length)
        XCTAssertEqual(environment.attemptedElements.count, 0)
        XCTAssertEqual(environment.clipboardWrites, [text])
        XCTAssertEqual(environment.pasteShortcutPIDs, [1234])
    }

    func testUnavailableClipboardPasteTargetDoesNotFallBackToAX() async {
        let capturedElement = AXUIElementCreateSystemWide()
        let snapshot = OutputTargetSnapshot(
            focusedElement: capturedElement,
            appPID: 1234
        )
        let environment = MockInsertionEnvironment()
        environment.deliveryMode = .clipboardPaste
        environment.successfulElement = capturedElement

        let result = await InsertionStrategy.insert(
            text: "recoverable terminal text",
            snapshot: snapshot,
            environment: environment
        )

        guard case .showRecoveryPopup(let text, _) = result else {
            return XCTFail("Expected unavailable clipboard-paste target recovery")
        }
        XCTAssertEqual(text, "recoverable terminal text")
        XCTAssertEqual(environment.attemptedElements.count, 0)
        XCTAssertEqual(environment.clipboardWrites, ["recoverable terminal text"])
        XCTAssertEqual(environment.pasteShortcutPIDs, [])
    }

    func testCMUXUsesClipboardPasteDelivery() {
        XCTAssertEqual(
            InsertionCompatibilityPolicy.deliveryMode(
                forBundleIdentifier: "com.cmuxterm.app"
            ),
            .clipboardPaste
        )
    }

    func testTerminalUsesClipboardPasteDelivery() {
        XCTAssertEqual(
            InsertionCompatibilityPolicy.deliveryMode(
                forBundleIdentifier: "com.apple.Terminal"
            ),
            .clipboardPaste
        )
    }

    func testPasteVerificationRequiresExactSelectedRangeReplacement() {
        XCTAssertTrue(
            ClipboardPasteVerifier.confirmsInsertion(
                beforeValue: "prompt old suffix",
                selectedRange: CFRange(location: 7, length: 3),
                afterValue: "prompt new suffix",
                insertedText: "new"
            )
        )
    }

    func testPasteVerificationRejectsPreexistingTextWithUnrelatedChange() {
        XCTAssertFalse(
            ClipboardPasteVerifier.confirmsInsertion(
                beforeValue: "prompt repeated transcript",
                selectedRange: CFRange(location: 7, length: 0),
                afterValue: "prompt repeated transcript\nbackground output",
                insertedText: "repeated transcript"
            )
        )
    }

    func testClipboardTransactionRejectsStaleRestoreWithoutTouchingPasteboard() {
        let manager = ClipboardTransactionManager()
        let pasteboard = MockClipboardPasteboard(changeCount: 10)
        let currentID = UUID()
        manager.begin(
            id: currentID,
            originalItems: [NSPasteboardItem()],
            stagedText: "current transcript",
            expectedChangeCount: pasteboard.changeCount
        )

        XCTAssertEqual(
            manager.restore(transactionID: UUID(), on: pasteboard),
            .stale
        )
        XCTAssertEqual(manager.currentTransactionID, currentID)
        XCTAssertEqual(pasteboard.clearCount, 0)
    }

    func testClipboardTransactionAbandonsRestoreAfterExternalChange() {
        let manager = ClipboardTransactionManager()
        let pasteboard = MockClipboardPasteboard(changeCount: 10)
        let transactionID = UUID()
        manager.begin(
            id: transactionID,
            originalItems: [NSPasteboardItem()],
            stagedText: "current transcript",
            expectedChangeCount: pasteboard.changeCount
        )
        pasteboard.simulateExternalChange()

        XCTAssertEqual(
            manager.restore(transactionID: transactionID, on: pasteboard),
            .abandoned
        )
        XCTAssertFalse(manager.hasPendingTransaction)
        XCTAssertEqual(pasteboard.clearCount, 0)
    }

    func testClipboardTransactionRestagesTranscriptThenRestoresOnRetry() {
        let manager = ClipboardTransactionManager()
        let pasteboard = MockClipboardPasteboard(
            changeCount: 10,
            writeResults: [false, true]
        )
        let transactionID = UUID()
        manager.begin(
            id: transactionID,
            originalItems: [NSPasteboardItem()],
            stagedText: "recoverable transcript",
            expectedChangeCount: pasteboard.changeCount
        )

        XCTAssertEqual(
            manager.restore(transactionID: transactionID, on: pasteboard),
            .retryScheduled
        )
        XCTAssertEqual(pasteboard.stagedStrings, ["recoverable transcript"])
        XCTAssertEqual(manager.currentRetryCount, 1)

        XCTAssertEqual(
            manager.restore(transactionID: transactionID, on: pasteboard),
            .restored
        )
        XCTAssertFalse(manager.hasPendingTransaction)
    }

    func testClipboardTransactionRetainsSnapshotAfterRetryLimit() {
        let manager = ClipboardTransactionManager(maxRetryCount: 3)
        let pasteboard = MockClipboardPasteboard(
            changeCount: 10,
            writeResults: [false, false, false, false]
        )
        let transactionID = UUID()
        manager.begin(
            id: transactionID,
            originalItems: [NSPasteboardItem()],
            stagedText: "recoverable transcript",
            expectedChangeCount: pasteboard.changeCount
        )

        for _ in 0..<3 {
            XCTAssertEqual(
                manager.restore(transactionID: transactionID, on: pasteboard),
                .retryScheduled
            )
        }
        XCTAssertEqual(
            manager.restore(transactionID: transactionID, on: pasteboard),
            .retriesExhausted
        )

        XCTAssertTrue(manager.hasPendingTransaction)
        XCTAssertEqual(manager.currentRetryCount, 4)
        XCTAssertEqual(pasteboard.stagedStrings.count, 4)
        XCTAssertEqual(pasteboard.currentString, "recoverable transcript")
        XCTAssertTrue(
            manager.clearPasteboardAfterExhaustedRestore(
                transactionID: transactionID,
                on: pasteboard
            )
        )
        XCTAssertNil(pasteboard.currentString)
        XCTAssertNotNil(
            manager.originalItemsForRestaging(
                currentChangeCount: pasteboard.changeCount
            )
        )
    }

    func testClipboardTransactionReportsTranscriptRestageFailure() {
        let manager = ClipboardTransactionManager(maxRetryCount: 0)
        let pasteboard = MockClipboardPasteboard(
            changeCount: 10,
            writeResults: [false],
            setStringResults: [false]
        )
        let transactionID = UUID()
        manager.begin(
            id: transactionID,
            originalItems: [NSPasteboardItem()],
            stagedText: "recoverable transcript",
            expectedChangeCount: pasteboard.changeCount
        )

        XCTAssertEqual(
            manager.restore(transactionID: transactionID, on: pasteboard),
            .retriesExhaustedWithoutTranscript
        )
        XCTAssertTrue(manager.hasPendingTransaction)
        XCTAssertEqual(pasteboard.setStringAttempts, ["recoverable transcript"])
        XCTAssertEqual(pasteboard.stagedStrings, [])
        XCTAssertTrue(
            manager.clearPasteboardAfterExhaustedRestore(
                transactionID: transactionID,
                on: pasteboard
            )
        )
        XCTAssertNil(pasteboard.currentString)
    }

    func testClipboardTransactionClearsPartialRestoreBeforeRestagingTranscript() {
        let manager = ClipboardTransactionManager()
        let pasteboard = MockClipboardPasteboard(
            changeCount: 10,
            writeResults: [false],
            simulatePartialWriteOnFailure: true
        )
        let transactionID = UUID()
        manager.begin(
            id: transactionID,
            originalItems: [NSPasteboardItem()],
            stagedText: "recoverable transcript",
            expectedChangeCount: pasteboard.changeCount
        )

        XCTAssertEqual(
            manager.restore(transactionID: transactionID, on: pasteboard),
            .retryScheduled
        )
        XCTAssertEqual(pasteboard.clearCount, 2)
        XCTAssertEqual(pasteboard.currentString, "recoverable transcript")
    }
}

@MainActor
private final class MockInsertionEnvironment: InsertionEnvironment {
    var refreshedElement: AXUIElement?
    var canReceivePaste = false
    var deliveryMode: InsertionDeliveryMode = .accessibilityPreferred
    var successfulElement: AXUIElement?
    var indeterminateElement: AXUIElement?
    var clipboardStagingSucceeds = true
    var pasteDeliveryResult: ClipboardPasteDeliveryResult = .verified
    private(set) var preparedPIDs: [pid_t] = []
    private(set) var attemptedElements: [AXUIElement] = []
    private(set) var insertedTexts: [String] = []
    private(set) var clipboardWrites: [String] = []
    private(set) var pasteShortcutPIDs: [pid_t] = []
    private(set) var clipboardRestores = 0
    private(set) var stagedRecoveryWindows: [ClipboardRecoveryWindow] = []
    private(set) var restoredRecoveryWindows: [ClipboardRecoveryWindow] = []

    func prepareTarget(pid: pid_t) async -> PreparedInsertionTarget {
        preparedPIDs.append(pid)
        return PreparedInsertionTarget(
            focusedElement: refreshedElement,
            canReceivePaste: canReceivePaste,
            deliveryMode: deliveryMode
        )
    }

    func insertText(
        _ text: String,
        into element: AXUIElement
    ) -> AccessibilityInsertionResult {
        insertedTexts.append(text)
        attemptedElements.append(element)
        if let successfulElement, CFEqual(successfulElement, element) {
            return .inserted
        }
        if let indeterminateElement, CFEqual(indeterminateElement, element) {
            return .indeterminate
        }
        return .rejected
    }

    func stageTemporaryClipboardRecovery(_ text: String) -> ClipboardRecoveryWindow? {
        clipboardWrites.append(text)
        guard clipboardStagingSucceeds else { return nil }
        let recoveryWindow = ClipboardRecoveryWindow.transaction(id: UUID())
        stagedRecoveryWindows.append(recoveryWindow)
        return recoveryWindow
    }

    func restoreClipboardAfterVerifiedPaste(_ recoveryWindow: ClipboardRecoveryWindow) {
        clipboardRestores += 1
        restoredRecoveryWindows.append(recoveryWindow)
    }

    func postGlobalPasteShortcut(
        expectedFrontmostPID pid: pid_t,
        expectedText: String
    ) async -> ClipboardPasteDeliveryResult {
        pasteShortcutPIDs.append(pid)
        return pasteDeliveryResult
    }
}

@MainActor
private final class MockClipboardPasteboard: ClipboardPasteboardAccess {
    private(set) var changeCount: Int
    private var writeResults: [Bool]
    private var setStringResults: [Bool]
    private let simulatePartialWriteOnFailure: Bool
    private(set) var clearCount = 0
    private(set) var setStringAttempts: [String] = []
    private(set) var stagedStrings: [String] = []
    private(set) var currentString: String?

    init(
        changeCount: Int,
        writeResults: [Bool] = [],
        setStringResults: [Bool] = [],
        simulatePartialWriteOnFailure: Bool = false
    ) {
        self.changeCount = changeCount
        self.writeResults = writeResults
        self.setStringResults = setStringResults
        self.simulatePartialWriteOnFailure = simulatePartialWriteOnFailure
    }

    func clearContents() -> Int {
        clearCount += 1
        currentString = nil
        changeCount += 1
        return changeCount
    }

    func setString(
        _ string: String,
        forType dataType: NSPasteboard.PasteboardType
    ) -> Bool {
        _ = dataType
        setStringAttempts.append(string)
        let result = setStringResults.isEmpty ? true : setStringResults.removeFirst()
        if result {
            stagedStrings.append(string)
            currentString = string
            changeCount += 1
        }
        return result
    }

    func writeObjects(_ objects: [NSPasteboardWriting]) -> Bool {
        _ = objects
        let result = writeResults.isEmpty ? true : writeResults.removeFirst()
        if result {
            changeCount += 1
        } else if simulatePartialWriteOnFailure {
            currentString = "partial original content"
            changeCount += 1
        }
        return result
    }

    func simulateExternalChange() {
        changeCount += 1
    }
}
