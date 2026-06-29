import AppKit

/// Global push-to-talk via a *tap* of the left Option key.
///
/// "Tap" = press then release with no other key in between and within a short
/// window — so normal Option+key shortcuts don't trigger it. Works app-wide
/// when granted Accessibility; otherwise only while the app is focused.
@MainActor
final class HotkeyManager {
    var onTap: () -> Void = {}
    var enabled = true

    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var optionDown = false
    private var comboUsed = false
    private var pressTS: TimeInterval = 0

    private let leftOptionKeyCode: UInt16 = 58   // kVK_Option (left)
    private let tapMaxDuration: TimeInterval = 0.8

    func start() {
        requestAccessibilityIfNeeded()
        localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]
        ) { [weak self] e in self?.handle(e); return e }

        globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.flagsChanged, .keyDown]
        ) { [weak self] e in self?.handle(e) }
    }

    func stop() {
        [localMonitor, globalMonitor].forEach { if let m = $0 { NSEvent.removeMonitor(m) } }
        localMonitor = nil; globalMonitor = nil
    }

    private func handle(_ e: NSEvent) {
        switch e.type {
        case .keyDown:
            if optionDown { comboUsed = true }   // Option used as a modifier → not a tap
        case .flagsChanged:
            guard e.keyCode == leftOptionKeyCode else { return }
            if e.modifierFlags.contains(.option) {
                optionDown = true; comboUsed = false; pressTS = e.timestamp
            } else {
                let isTap = optionDown && !comboUsed
                    && (e.timestamp - pressTS) < tapMaxDuration
                optionDown = false
                if isTap, enabled { onTap() }
            }
        default:
            break
        }
    }

    private func requestAccessibilityIfNeeded() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }
}
