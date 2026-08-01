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
    }

    func testFailedClipboardPasteShowsPopupAndKeepsTranscriptAvailable() async {
        let refreshedElement = AXUIElementCreateSystemWide()
        let snapshot = OutputTargetSnapshot(focusedElement: nil, appPID: 1234)
        let environment = MockInsertionEnvironment()
        environment.refreshedElement = refreshedElement
        environment.canReceivePaste = true
        environment.pasteShortcutSucceeds = false

        let result = await InsertionStrategy.insert(
            text: "recoverable text",
            snapshot: snapshot,
            environment: environment
        )

        guard case .showRecoveryPopup(let text, let recoveryWindow) = result else {
            return XCTFail("Expected failed clipboard paste to show the recovery popup")
        }
        XCTAssertEqual(text, "recoverable text")
        XCTAssertEqual(recoveryWindow, .standard)
        XCTAssertEqual(environment.clipboardWrites, ["recoverable text"])
        XCTAssertEqual(environment.pasteShortcutPIDs, [1234])
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
}

@MainActor
private final class MockInsertionEnvironment: InsertionEnvironment {
    var refreshedElement: AXUIElement?
    var canReceivePaste = false
    var deliveryMode: InsertionDeliveryMode = .accessibilityPreferred
    var successfulElement: AXUIElement?
    var indeterminateElement: AXUIElement?
    var clipboardStagingSucceeds = true
    var pasteShortcutSucceeds = true
    private(set) var preparedPIDs: [pid_t] = []
    private(set) var attemptedElements: [AXUIElement] = []
    private(set) var insertedTexts: [String] = []
    private(set) var clipboardWrites: [String] = []
    private(set) var pasteShortcutPIDs: [pid_t] = []

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
        return clipboardStagingSucceeds ? .standard : nil
    }

    func postGlobalPasteShortcut(expectedFrontmostPID pid: pid_t) async -> Bool {
        pasteShortcutPIDs.append(pid)
        return pasteShortcutSucceeds
    }
}
