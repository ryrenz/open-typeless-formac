import ApplicationServices
import Foundation

enum AccessibilityInsertionResult {
    case inserted
    case rejected
    case indeterminate
}

enum AccessibilityHelper {
    static func insertText(
        _ text: String,
        into element: AXUIElement
    ) -> AccessibilityInsertionResult {
        // Preferred: replace the current selection (or insert at the caret) surgically.
        // This avoids reading and rewriting the element's entire value, which is
        // expensive and risky for large fields (e.g. a terminal's scrollback buffer).
        let selectedTextResult = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        if selectedTextResult == .success {
            return .inserted
        }
        if isIndeterminate(selectedTextResult) {
            return .indeterminate
        }

        // Fallback: splice the text into the full value at the selected range.
        var currentValue: AnyObject?
        let valueResult = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &currentValue)

        var selectedRange: AnyObject?
        let rangeResult = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selectedRange)

        if isIndeterminate(valueResult) || isIndeterminate(rangeResult) {
            return .indeterminate
        }

        if valueResult == .success,
           rangeResult == .success,
           let currentStr = currentValue as? String,
           let selectedRange = selectedRange,
           CFGetTypeID(selectedRange) == AXValueGetTypeID() {
            let rangeValue = selectedRange as! AXValue
            var cfRange = CFRange()
            if AXValueGetType(rangeValue) == .cfRange,
               AXValueGetValue(rangeValue, .cfRange, &cfRange) {
                let replacement = replacingUTF16Range(
                    in: currentStr,
                    range: cfRange,
                    with: text
                )
                let setResult = AXUIElementSetAttributeValue(
                    element,
                    kAXValueAttribute as CFString,
                    replacement.value as CFTypeRef
                )
                if setResult == .success {
                    var newRange = CFRange(location: replacement.caretLocation, length: 0)
                    if let newRangeValue = AXValueCreate(.cfRange, &newRange) {
                        AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, newRangeValue)
                    }
                    return .inserted
                }
                if isIndeterminate(setResult) {
                    return .indeterminate
                }
            }
        }

        return .rejected
    }

    static func replacingUTF16Range(
        in currentValue: String,
        range: CFRange,
        with replacement: String
    ) -> (value: String, caretLocation: CFIndex) {
        let mutable = NSMutableString(string: currentValue)
        let location = max(0, min(range.location, mutable.length))
        let length = max(0, min(range.length, mutable.length - location))

        mutable.replaceCharacters(
            in: NSRange(location: location, length: length),
            with: replacement
        )
        return (
            value: mutable as String,
            caretLocation: location + (replacement as NSString).length
        )
    }

    private static func isIndeterminate(_ error: AXError) -> Bool {
        error == .cannotComplete || error == .failure
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
