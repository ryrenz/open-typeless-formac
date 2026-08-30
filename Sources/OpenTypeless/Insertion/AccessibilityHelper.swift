import Darwin
import ApplicationServices
import Foundation

enum AccessibilityInsertionResult {
    case inserted
    case rejected
    case indeterminate
}

enum AccessibilityHelper {
    private static let axMessagingTimeout: Float = 0.5
    private static let maxDirectAXValueUTF16Length = 64_000

    private struct EditableTextState {
        let value: String
        let selectedRange: CFRange
    }

    private enum TextStateReadResult {
        case available(EditableTextState)
        case unavailable
        case indeterminate
    }

    static func insertText(
        _ text: String,
        into element: AXUIElement
    ) -> AccessibilityInsertionResult {
        // AXSelectedTextAttribute is documented as read-only. Some apps still
        // return success when it is written, so use a verified AXValue splice
        // instead of accepting that success as proof of delivery.
        AXUIElementSetMessagingTimeout(element, axMessagingTimeout)

        switch readEditableTextState(from: element) {
        case .indeterminate:
            return .indeterminate
        case .unavailable:
            return .rejected
        case .available(let state):
            guard state.value.utf16.count <= maxDirectAXValueUTF16Length else {
                return .indeterminate
            }

            let replacement = replacingUTF16Range(
                in: state.value,
                range: state.selectedRange,
                with: text
            )
            guard replacement.value.utf16.count <= maxDirectAXValueUTF16Length else {
                return .indeterminate
            }

            // Prefer the surgical operation when the target really supports
            // it, but never trust its AXError alone. A few apps report success
            // for this read-only attribute without changing their value.
            let selectedTextResult = AXUIElementSetAttributeValue(
                element,
                kAXSelectedTextAttribute as CFString,
                text as CFTypeRef
            )
            if selectedTextResult == .success {
                if verifyValue(replacement.value, in: element) {
                    return .inserted
                }
                // If the value is still exactly the pre-write value, the
                // surgical setter was a harmless false success and the full
                // value fallback remains safe. Any other mismatch is treated
                // as indeterminate to avoid overwriting concurrent edits.
                guard readValue(from: element) == state.value else {
                    return .indeterminate
                }
            }
            if isIndeterminate(selectedTextResult) {
                return .indeterminate
            }

            let setResult = AXUIElementSetAttributeValue(
                element,
                kAXValueAttribute as CFString,
                replacement.value as CFTypeRef
            )
            guard setResult == .success else {
                return isIndeterminate(setResult) ? .indeterminate : .rejected
            }

            guard verifyValue(
                replacement.value,
                in: element
            ) else {
                // The write may have been accepted asynchronously or may have
                // been a false success. Do not retry with AX or paste blindly.
                return .indeterminate
            }

            var newRange = CFRange(location: replacement.caretLocation, length: 0)
            if let newRangeValue = AXValueCreate(.cfRange, &newRange) {
                _ = AXUIElementSetAttributeValue(
                    element,
                    kAXSelectedTextRangeAttribute as CFString,
                    newRangeValue
                )
            }
            return .inserted
        }
    }

    private static func readEditableTextState(
        from element: AXUIElement
    ) -> TextStateReadResult {
        var characterCount: AnyObject?
        let characterCountResult = AXUIElementCopyAttributeValue(
            element,
            kAXNumberOfCharactersAttribute as CFString,
            &characterCount
        )
        if characterCountResult == .success,
           let characterCount = characterCount as? NSNumber,
           characterCount.intValue > maxDirectAXValueUTF16Length {
            return .indeterminate
        }
        if isIndeterminate(characterCountResult) {
            return .indeterminate
        }

        var currentValue: AnyObject?
        let valueResult = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &currentValue
        )
        guard valueResult == .success else {
            return isIndeterminate(valueResult) ? .indeterminate : .unavailable
        }
        guard let currentString = currentValue as? String else {
            return .unavailable
        }
        guard currentString.utf16.count <= maxDirectAXValueUTF16Length else {
            return .indeterminate
        }

        var selectedRange: AnyObject?
        let rangeResult = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            &selectedRange
        )
        guard rangeResult == .success else {
            return isIndeterminate(rangeResult) ? .indeterminate : .unavailable
        }
        guard let selectedRange,
              CFGetTypeID(selectedRange) == AXValueGetTypeID() else {
            return .unavailable
        }

        let rangeValue = selectedRange as! AXValue
        guard AXValueGetType(rangeValue) == .cfRange else {
            return .unavailable
        }
        var cfRange = CFRange()
        guard AXValueGetValue(rangeValue, .cfRange, &cfRange) else {
            return .unavailable
        }

        return .available(
            EditableTextState(value: currentString, selectedRange: cfRange)
        )
    }

    private static func verifyValue(_ expected: String, in element: AXUIElement) -> Bool {
        // A short retry window allows AppKit/WebKit controls to publish the new
        // AXValue without turning a delayed readback into a false failure.
        for attempt in 0..<3 {
            if let actual = readValue(from: element), actual == expected {
                return true
            }

            if attempt < 2 { usleep(20_000) }
        }
        return false
    }

    private static func readValue(from element: AXUIElement) -> String? {
        var value: AnyObject?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &value
        ) == .success,
              let value = value as? String,
              value.utf16.count <= maxDirectAXValueUTF16Length else {
            return nil
        }
        return value
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
        AXUIElementSetMessagingTimeout(systemWide, axMessagingTimeout)
        var focusedApp: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success,
              let app = focusedApp,
              CFGetTypeID(app) == AXUIElementGetTypeID() else {
            return nil
        }

        var focusedElement: AnyObject?
        let appElement = app as! AXUIElement
        AXUIElementSetMessagingTimeout(appElement, axMessagingTimeout)
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success,
              let element = focusedElement,
              CFGetTypeID(element) == AXUIElementGetTypeID() else {
            return nil
        }

        return (element as! AXUIElement)
    }
}
