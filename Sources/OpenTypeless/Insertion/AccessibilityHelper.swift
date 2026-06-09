import ApplicationServices
import Foundation

enum AccessibilityHelper {
    static func insertText(_ text: String, into element: AXUIElement) -> Bool {
        // Preferred: replace the current selection (or insert at the caret) surgically.
        // This avoids reading and rewriting the element's entire value, which is
        // expensive and risky for large fields (e.g. a terminal's scrollback buffer).
        let selectedTextResult = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        if selectedTextResult == .success {
            return true
        }

        // Fallback: splice the text into the full value at the selected range.
        var currentValue: AnyObject?
        let valueResult = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &currentValue)

        var selectedRange: AnyObject?
        let rangeResult = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRange)

        if valueResult == .success,
           rangeResult == .success,
           let currentStr = currentValue as? String,
           let selectedRange = selectedRange {
            let rangeValue = selectedRange as! AXValue
            var cfRange = CFRange()
            if AXValueGetValue(rangeValue, .cfRange, &cfRange) {
                // Clamp the range to the actual string bounds — a stale or
                // out-of-range selection would otherwise crash the index math.
                let count = currentStr.count
                let location = max(0, min(cfRange.location, count))
                let length = max(0, min(cfRange.length, count - location))

                var mutable = currentStr
                let start = mutable.index(mutable.startIndex, offsetBy: location)
                let end = mutable.index(start, offsetBy: length)
                mutable.replaceSubrange(start..<end, with: text)

                let setResult = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, mutable as CFTypeRef)
                if setResult == .success {
                    let newLocation = location + text.count
                    var newRange = CFRange(location: newLocation, length: 0)
                    if let newRangeValue = AXValueCreate(.cfRange, &newRange) {
                        AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, newRangeValue)
                    }
                    return true
                }
            }
        }

        return false
    }

    static func isTextInput(_ element: AXUIElement) -> Bool {
        var role: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        guard result == .success, let roleStr = role as? String else { return false }

        let textRoles = [
            kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole,
            "AXWebArea", "AXSearchField",
        ]
        return textRoles.contains(roleStr)
    }

    static func getFocusedElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedApp: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success,
              let app = focusedApp,
              CFGetTypeID(app) == AXUIElementGetTypeID() else {
            return nil
        }

        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(app as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
              let element = focusedElement,
              CFGetTypeID(element) == AXUIElementGetTypeID() else {
            return nil
        }

        return (element as! AXUIElement)
    }
}
