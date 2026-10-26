import AppKit
import Carbon.HIToolbox

/// The frontmost app's selected text: asked for through Accessibility, which leaves the clipboard
/// alone, or, from apps that don't answer (many web browsers and Electron apps), by pressing ⌘C
/// for it and then putting the clipboard back as it was. Both need Accessibility access
/// (`Permissions.checkAccessibility`).
@MainActor
enum SelectedText {
    /// The selected text, or nil if there's none (no selection, no text in it, another app came
    /// to the front in the meantime, or the shortcut's keys were held for over a second). An app
    /// that takes over a second to copy leaves the selection on the clipboard.
    static func copy() async -> String? {
        let app = NSWorkspace.shared.frontmostApplication
        // Not Quick Chat's own panel: asking yourself through Accessibility can stall until it times out.
        if app?.processIdentifier != ProcessInfo.processInfo.processIdentifier, let text = accessibilitySelection() {
            return text
        }
        // The shortcut's own modifiers may still be down: ⌥ with ⌘C is another command
        // (in Chrome and Brave, Inspect Element), so wait until they're released.
        let released = { CGEventSource.flagsState(.combinedSessionState).isDisjoint(with: modifiers) }
        await waitUntil(timeout: 1, released)
        guard released(), NSWorkspace.shared.frontmostApplication == app else { return nil }
        let pasteboard = NSPasteboard.general
        let saved = PasteboardSnapshot(pasteboard)
        let before = pasteboard.changeCount
        pressCommandC()
        await waitUntil(timeout: 1) { pasteboard.changeCount != before }
        guard pasteboard.changeCount != before else { return nil }
        // Apps clear the clipboard, then write to it; give the writing a moment.
        try? await Task.sleep(for: .milliseconds(50))
        let text = pasteboard.string(forType: .string)
        saved.restore(to: pasteboard)
        return text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? text : nil
    }

    /// The focused element's selected text, if its app tells (nil when it doesn't, or it's
    /// empty). Waits a quarter second at most for an app that doesn't answer.
    private static func accessibilitySelection() -> String? {
        let system = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        AXUIElementSetMessagingTimeout(system, 0.25)
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement // its type is checked above
        AXUIElementSetMessagingTimeout(element, 0.25)
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    private static let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    private static func pressCommandC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for isDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_C), keyDown: isDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }
    }

    private static func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async {
        let deadline = Date(timeIntervalSinceNow: timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// A copy of a pasteboard's items (every type of each, in the app's order of preference), to
/// put back after borrowing it.
struct PasteboardSnapshot {
    private let items: [[(NSPasteboard.PasteboardType, Data)]]

    init(_ pasteboard: NSPasteboard) {
        items = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let restored = items.map { types in
            let item = NSPasteboardItem()
            for (type, data) in types { item.setData(data, forType: type) }
            return item
        }
        if !restored.isEmpty { pasteboard.writeObjects(restored) }
    }
}
