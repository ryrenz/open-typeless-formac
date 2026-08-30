import CoreGraphics
import XCTest
@testable import OpenTypeless

final class HotkeyManagerTests: XCTestCase {
    func testDefaultConfig() {
        let manager = HotkeyManager()
        // Default: Right Alt (keyCode=61) for transcribe
        XCTAssertEqual(manager.config.transcribeKeyCode, 61)
        // Default: Control+D for translate
        XCTAssertEqual(manager.config.translateKeyCode, 2)
        XCTAssertTrue(manager.config.translateModifiers.contains(.maskControl))
    }

    func testCustomConfig() {
        let config = HotkeyManager.HotkeyConfig(
            transcribeKeyCode: 0,
            transcribeModifiers: .maskCommand,
            translateKeyCode: 3,
            translateModifiers: .maskControl
        )
        let manager = HotkeyManager(config: config)
        XCTAssertEqual(manager.config.transcribeKeyCode, 0)
        XCTAssertEqual(manager.config.translateKeyCode, 3)
        XCTAssertTrue(manager.config.transcribeModifiers.contains(.maskCommand))
        XCTAssertTrue(manager.config.translateModifiers.contains(.maskControl))
    }

    func testCallbackInitiallyNil() {
        let manager = HotkeyManager()
        XCTAssertNil(manager.onHotkeyPressed)
    }

    func testPauseResume() {
        let manager = HotkeyManager()
        manager.pause()
        manager.resume()
    }

    func testPassThroughDoesNotRetainEvent() throws {
        let manager = HotkeyManager()
        let event = try XCTUnwrap(
            CGEvent(
                keyboardEventSource: nil,
                virtualKey: 0,
                keyDown: true
            )
        )
        let retainCountBefore = CFGetRetainCount(event)

        for _ in 0..<100 {
            guard manager.handleEvent(.keyDown, event: event) != nil else {
                return XCTFail("An unmatched key event must pass through")
            }
        }

        XCTAssertLessThanOrEqual(
            CFGetRetainCount(event),
            retainCountBefore + 2,
            "Pass-through events must not accumulate one retain per keyboard event"
        )
    }
}
