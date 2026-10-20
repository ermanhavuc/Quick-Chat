import AppKit
import Carbon.HIToolbox

/// The frontmost app's selected text, read by pressing ⌘C for it and then putting the clipboard
/// back as it was. Works in any app that can copy text, but pressing keys for another app
/// needs Accessibility access (`Permissions.checkAccessibility`).
@MainActor
enum SelectedText {
    /// The selected text, or nil if nothing was copied (no selection, no text in it, or another
    /// app came to the front in the meantime). An app that takes over a second to copy leaves
    /// the selection on the clipboard.
    static func copy() async -> String? {
        let app = NSWorkspace.shared.frontmostApplication
        // The shortcut's own modifiers may still be down: ⌥ with ⌘C is another command
        // (in Chrome and Brave, Inspect Element), so wait until they're released.
        await waitUntil(timeout: 1) { CGEventSource.flagsState(.combinedSessionState).isDisjoint(with: modifiers) }
        guard NSWorkspace.shared.frontmostApplication == app else { return nil }
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
