import ApplicationServices
import Foundation

struct OutputTargetSnapshot {
    private static let accessibilityMessagingTimeout: Float = 0.5

    let focusedElement: AXUIElement?
    let appPID: pid_t?
    private let createdAt = Date()

    static func capture() -> OutputTargetSnapshot {
        let systemWide = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(systemWide, accessibilityMessagingTimeout)
        var focusedApp: AnyObject?
        let appResult = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp)

        guard appResult == .success,
              let app = focusedApp,
              CFGetTypeID(app) == AXUIElementGetTypeID() else {
            return OutputTargetSnapshot(focusedElement: nil, appPID: nil)
        }

        let appElement = app as! AXUIElement
        AXUIElementSetMessagingTimeout(appElement, accessibilityMessagingTimeout)

        var pid: pid_t = 0
        AXUIElementGetPid(appElement, &pid)

        var focusedUI: AnyObject?
        let elementResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedUI
        )

        if elementResult == .success,
           let ui = focusedUI,
           CFGetTypeID(ui) == AXUIElementGetTypeID() {
            return OutputTargetSnapshot(focusedElement: (ui as! AXUIElement), appPID: pid)
        }

        return OutputTargetSnapshot(focusedElement: nil, appPID: pid)
    }

    func isValid() -> Bool {
        guard let element = focusedElement else { return false }
        AXUIElementSetMessagingTimeout(element, Self.accessibilityMessagingTimeout)

        var role: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        guard result == .success, let roleStr = role as? String else { return false }

        let textRoles = [
            kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole,
            "AXWebArea", "AXSearchField",
        ]
        return textRoles.contains(roleStr)
    }

    var hasTarget: Bool {
        focusedElement != nil
    }

    var hasTextInput: Bool {
        guard let element = focusedElement else { return false }
        AXUIElementSetMessagingTimeout(element, Self.accessibilityMessagingTimeout)

        var role: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        guard result == .success, let roleStr = role as? String else { return false }

        // Strict text input roles only — no AXWebArea/AXGroup (too broad, causes false positives)
        let strictTextRoles = [
            kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField",
        ]
        if strictTextRoles.contains(roleStr) { return true }

        // For other roles, check if the element is actually editable
        var settable: DarwinBoolean = false
        let isSettable = AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable)
        if isSettable == .success && settable.boolValue { return true }

        return false
    }
}
