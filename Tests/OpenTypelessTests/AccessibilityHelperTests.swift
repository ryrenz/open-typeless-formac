import ApplicationServices
import XCTest
@testable import OpenTypeless

final class AccessibilityHelperTests: XCTestCase {
    func testReplacingRangeUsesUTF16OffsetsForEmoji() {
        let result = AccessibilityHelper.replacingUTF16Range(
            in: "A😀B",
            range: CFRange(location: 1, length: 2),
            with: "好"
        )

        XCTAssertEqual(result.value, "A好B")
        XCTAssertEqual(result.caretLocation, 2)
    }

    func testReplacementCaretUsesUTF16Length() {
        let result = AccessibilityHelper.replacingUTF16Range(
            in: "AB",
            range: CFRange(location: 1, length: 0),
            with: "😀"
        )

        XCTAssertEqual(result.value, "A😀B")
        XCTAssertEqual(result.caretLocation, 3)
    }

    func testReplacingRangeClampsStaleSelection() {
        let result = AccessibilityHelper.replacingUTF16Range(
            in: "A😀B",
            range: CFRange(location: 100, length: 100),
            with: "!"
        )

        XCTAssertEqual(result.value, "A😀B!")
        XCTAssertEqual(result.caretLocation, 5)
    }
}
