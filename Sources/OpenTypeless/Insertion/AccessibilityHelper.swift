import ApplicationServices
import Foundation

enum AccessibilityHelper {
    static func insertText(_ text: String, into element: AXUIElement) -> Bool {
        var currentValue: AnyObject?
        let valueResult = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &currentValue)

        var selectedRange: AnyObject?
        let rangeResult = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRange)

        if valueResult == .success,
           rangeResult == .success,
           let currentStr = currentValue as? String,
           let rangeValue = selectedRange as? AXValue {
            var cfRange = CFRange()
            if AXValueGetValue(rangeValue, .cfRange, &cfRange) {
                var mutable = currentStr
                let start = mutable.index(mutable.startIndex, offsetBy: min(cfRange.location, currentStr.count))
                let end = mutable.index(start, offsetBy: min(cfRange.length, currentStr.count - cfRange.location))
                mutable.replaceSubrange(start..<end, with: text)

                let setResult = AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, mutable as CFTypeRef)
                if setResult == .success {
                    let newLocation = cfRange.location + text.count
                    var newRange = CFRange(location: newLocation, length: 0)
                    if let newRangeValue = AXValueCreate(.cfRange, &newRange) {
                        AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, newRangeValue)
                    }
                    return true
                }
            }
        }

        let selectedTextResult = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        return selectedTextResult == .success
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
