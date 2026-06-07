import AppKit

enum OverlayState {
    case recording
    case transcribing
    case error
}

@MainActor
final class ProgressOverlayController {
    static let shared = ProgressOverlayController()

    private var window: NSPanel?
    private var label: NSTextField?
    private var indicator: NSView?
    private var dismissTask: Task<Void, Never>?
    private var meteringTask: Task<Void, Never>?

    var audioLevelProvider: (() -> Float)?

    func show(state: OverlayState) {
        dismissTask?.cancel()

        if let window = window {
            updateUI(state: state)
            window.alphaValue = 1
            window.orderFrontRegardless()
            if state == .recording { startMetering() } else { stopMetering() }
            return
        }

        // Build UI with AppKit only — no SwiftUI, no ObservableObject
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 40))
        container.wantsLayer = true
        container.layer?.cornerRadius = 20
        container.layer?.backgroundColor = NSColor(white: 0.1, alpha: 0.85).cgColor

        let dot = NSView(frame: NSRect(x: 16, y: 14, width: 12, height: 12))
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 6
        dot.layer?.backgroundColor = NSColor.red.cgColor
        container.addSubview(dot)
        self.indicator = dot

        let text = NSTextField(labelWithString: "")
        text.frame = NSRect(x: 36, y: 10, width: 170, height: 20)
        text.textColor = .white
        text.font = .systemFont(ofSize: 14, weight: .medium)
        container.addSubview(text)
        self.label = text

        let panel = NSPanel(
            contentRect: container.frame,
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.contentView = container
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        positionAtBottomCenter(panel)
        panel.orderFrontRegardless()

        self.window = panel
        updateUI(state: state)

        if state == .recording { startMetering() }
    }

    func update(state: OverlayState) {
        updateUI(state: state)
        if state == .recording { startMetering() } else { stopMetering() }
    }

    func dismiss() {
        stopMetering()
        dismissTask?.cancel()
        // Capture the window reference now so subsequent show() calls don't
        // get their new window closed by this task waking up after the sleep.
        let windowToClose = self.window
        dismissTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }

            windowToClose?.animator().alphaValue = 0
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }

            windowToClose?.close()
            if self.window === windowToClose {
                self.window = nil
                self.label = nil
                self.indicator = nil
            }
        }
    }

    func flashError() {
        update(state: .error)
        dismissTask?.cancel()
        dismissTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    private func updateUI(state: OverlayState) {
        switch state {
        case .recording:
            label?.stringValue = "Recording..."
            indicator?.layer?.backgroundColor = NSColor.red.cgColor
        case .transcribing:
            label?.stringValue = "Transcribing..."
            indicator?.layer?.backgroundColor = NSColor.systemBlue.cgColor
        case .error:
            label?.stringValue = "Error"
            indicator?.layer?.backgroundColor = NSColor.red.cgColor
        }
    }

    private func startMetering() {
        stopMetering()
        meteringTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self = self else { break }
                let level = self.audioLevelProvider?() ?? 0
                // Pulse the dot opacity based on audio level
                self.indicator?.layer?.opacity = 0.4 + level * 0.6
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    private func stopMetering() {
        meteringTask?.cancel()
        meteringTask = nil
        indicator?.layer?.opacity = 1
    }

    private func positionAtBottomCenter(_ panel: NSPanel) {
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - panel.frame.width / 2
        let y = screenFrame.origin.y + 80
        panel.setFrameOrigin(NSPoint(x: x, y: y))
        panel.alphaValue = 1
    }
}
