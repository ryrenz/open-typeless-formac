import CoreGraphics
import XCTest
@testable import OpenTypeless

final class HotkeyStoreTests: XCTestCase {
    override func setUp() {
        super.setUp()
        // Clean up test keys
        UserDefaults.standard.removeObject(forKey: "hotkeyTranscribeKeyCode")
        UserDefaults.standard.removeObject(forKey: "hotkeyTranscribeModifiers")
        UserDefaults.standard.removeObject(forKey: "hotkeyTranslateKeyCode")
        UserDefaults.standard.removeObject(forKey: "hotkeyTranslateModifiers")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "hotkeyTranscribeKeyCode")
        UserDefaults.standard.removeObject(forKey: "hotkeyTranscribeModifiers")
        UserDefaults.standard.removeObject(forKey: "hotkeyTranslateKeyCode")
        UserDefaults.standard.removeObject(forKey: "hotkeyTranslateModifiers")
        super.tearDown()
    }

    func testLoadReturnsNilWhenEmpty() {
        XCTAssertNil(HotkeyStore.loadTranscribe())
        XCTAssertNil(HotkeyStore.loadTranslate())
    }

    func testSaveAndLoad() {
        let shortcut = StoredShortcut(keyCode: 1, modifiers: [.maskCommand, .maskShift])
        HotkeyStore.saveTranscribe(shortcut)

        let loaded = HotkeyStore.loadTranscribe()
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.keyCode, 1)
        XCTAssertTrue(loaded!.modifiers.contains(.maskCommand))
        XCTAssertTrue(loaded!.modifiers.contains(.maskShift))
    }

    func testLoadConfigReturnsDefaultTranslateWhenPartial() {
        let shortcut = StoredShortcut(keyCode: 1, modifiers: .maskCommand)
        HotkeyStore.saveTranscribe(shortcut)
        let config = HotkeyStore.loadConfig()
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.transcribeKeyCode, 1)
        XCTAssertEqual(config?.translateKeyCode, 2)
        XCTAssertEqual(config?.translateModifiers, .maskControl)
    }

    func testLoadConfigReturnsBothWhenComplete() {
        HotkeyStore.saveTranscribe(StoredShortcut(keyCode: 1, modifiers: .maskCommand))
        HotkeyStore.saveTranslate(StoredShortcut(keyCode: 2, modifiers: .maskControl))

        let config = HotkeyStore.loadConfig()
        XCTAssertNotNil(config)
        XCTAssertEqual(config?.transcribeKeyCode, 1)
        XCTAssertEqual(config?.translateKeyCode, 2)
    }

    func testDisplayString() {
        let shortcut1 = StoredShortcut(keyCode: 1, modifiers: [.maskCommand, .maskShift])
        XCTAssertEqual(shortcut1.displayString, "⇧⌘S")

        let shortcut2 = StoredShortcut(keyCode: 2, modifiers: [.maskControl, .maskAlternate])
        XCTAssertEqual(shortcut2.displayString, "⌃⌥D")

        let shortcut3 = StoredShortcut(keyCode: 15, modifiers: .maskCommand)
        XCTAssertEqual(shortcut3.displayString, "⌘R")
    }

    func testIsValidAcceptsAnyKey() {
        let noModifier = StoredShortcut(keyCode: 1, modifiers: CGEventFlags(rawValue: 0))
        XCTAssertTrue(noModifier.isValid)

        let withModifier = StoredShortcut(keyCode: 1, modifiers: .maskCommand)
        XCTAssertTrue(withModifier.isValid)
    }

    func testIsValidAllowsKeyCodeZero() {
        // keyCode 0 = kVK_ANSI_A, should be valid with modifier
        let keyA = StoredShortcut(keyCode: 0, modifiers: .maskCommand)
        XCTAssertTrue(keyA.isValid)
    }
}
