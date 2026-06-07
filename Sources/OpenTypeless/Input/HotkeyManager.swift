import Carbon
import CoreGraphics
import Foundation

enum HotkeyAction {
    case transcribe
    case translate
}

final class HotkeyManager {
    struct HotkeyConfig {
        var transcribeKeyCode: CGKeyCode
        var transcribeModifiers: CGEventFlags
        var translateKeyCode: CGKeyCode
        var translateModifiers: CGEventFlags
    }

    var onHotkeyPressed: ((HotkeyAction) -> Void)?

    fileprivate var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var isPaused = false

    // Right Option/Alt keyCode on this keyboard = 61
    static let kVK_RightOption: CGKeyCode = 61

    var config: HotkeyConfig {
        didSet { /* live-update, no re-registration needed for CGEvent tap */ }
    }

    init(config: HotkeyConfig? = nil) {
        // Default: Right Alt (keyCode=61) for transcribe, Left Control+D for translate
        self.config = config ?? HotkeyConfig(
            transcribeKeyCode: Self.kVK_RightOption,
            transcribeModifiers: CGEventFlags(rawValue: 0), // modifier-only key
            translateKeyCode: CGKeyCode(kVK_ANSI_D),
            translateModifiers: .maskControl
        )
    }

    func start() -> Bool {
        guard eventTap == nil else { return true }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: hotkeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    deinit {
        stop()
    }

    func pause() {
        isPaused = true
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }

    func resume() {
        isPaused = false
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: true)
        }
    }

    // MARK: - Internal

    fileprivate func handleEvent(_ type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        guard !isPaused else { return Unmanaged.passRetained(event) }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))

        let flags = event.flags

        switch type {
        case .flagsChanged:
            if let action = matchModifierOnlyAction(keyCode: keyCode, flags: flags) {
                onHotkeyPressed?(action)
                return nil
            }

        case .keyDown:
            if let action = matchKeyComboAction(keyCode: keyCode, flags: flags) {
                onHotkeyPressed?(action)
                return nil
            }

        default:
            break
        }

        return Unmanaged.passRetained(event)
    }

    /// Match modifier-only hotkeys (e.g. Right Alt pressed down)
    private func matchModifierOnlyAction(keyCode: CGKeyCode, flags: CGEventFlags) -> HotkeyAction? {
        let modifiersActive = !flags.intersection([.maskControl, .maskAlternate, .maskShift, .maskCommand]).isEmpty

        // Only trigger when the SPECIFIC key is pressed (keyCode matches AND its modifier flag is active)
        if keyCode == config.transcribeKeyCode && config.transcribeModifiers.rawValue == 0 && modifiersActive {
            return .transcribe
        }
        if keyCode == config.translateKeyCode && config.translateModifiers.rawValue == 0 && modifiersActive {
            return .translate
        }
        return nil
    }

    /// Match regular key + modifier combos (e.g. Ctrl+Option+D)
    private func matchKeyComboAction(keyCode: CGKeyCode, flags: CGEventFlags) -> HotkeyAction? {
        let relevantFlags: CGEventFlags = [.maskAlternate, .maskControl, .maskShift, .maskCommand]
        let pressed = flags.intersection(relevantFlags)

        // Skip modifier-only configs (handled by matchModifierOnlyAction)
        if config.transcribeModifiers.rawValue != 0
            && keyCode == config.transcribeKeyCode
            && pressed == config.transcribeModifiers {
            return .transcribe
        }
        if config.translateModifiers.rawValue != 0
            && keyCode == config.translateKeyCode
            && pressed == config.translateModifiers {
            return .translate
        }
        return nil
    }
}

// MARK: - C callback

private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let userInfo = userInfo {
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            if let tap = manager.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        return Unmanaged.passRetained(event)
    }

    guard let userInfo = userInfo else {
        return Unmanaged.passRetained(event)
    }

    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    return manager.handleEvent(type, event: event)
}
