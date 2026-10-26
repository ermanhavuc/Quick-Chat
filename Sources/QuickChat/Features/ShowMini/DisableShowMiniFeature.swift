import AppKit

/// User toggle that unbinds ChatGPT's Show Mini keyboard shortcut through
/// `ShowMiniController`. Show Mini itself stays usable from ChatGPT's UI.
///
/// While Quick Chat uses Mini's shortcut, Mini is unbound regardless, so the checkbox
/// shows ticked and locked with a greyed status line explaining why. `isEnabled` still
/// tracks only the user's own choice (`.userDisabled`), which is untouched by the lock
/// and takes effect again once Quick Chat releases the shortcut.
@MainActor
final class DisableShowMiniFeature: Feature {
    let id = "disableShowMini"
    private(set) var isEnabled = false
    private let showMini: ShowMiniController

    /// e.g. "Disable Show Mini Shortcut (⌥Space)". Re-read each time the menu opens,
    /// so it follows the user's own binding in ChatGPT's keymap.
    var title: String {
        let base = "Disable Show Mini Shortcut"
        guard let keys = showMini.userShortcutDescription else { return base }
        return "\(base) (\(keys))"
    }

    /// Mini is unbound because Quick Chat uses the same shortcut.
    private var lockedByQuickChat: Bool { showMini.reasons.contains(.quickChatShortcut) }

    var isChecked: Bool { isEnabled || lockedByQuickChat }

    private var chatGPTInstalled: Bool { ChatGPTApp.isInstalled }

    /// Nothing to toggle without ChatGPT; and unchecking couldn't restore Mini while
    /// Quick Chat holds its shortcut.
    var canToggle: Bool { chatGPTInstalled && !lockedByQuickChat }

    var statusText: String? {
        guard chatGPTInstalled else { return "ChatGPT app not installed" }
        guard lockedByQuickChat else { return nil }
        guard let keys = showMini.userShortcutDescription else { return "On while Quick Chat uses this shortcut" }
        return "On while Quick Chat uses \(keys)"
    }

    /// "Restart ChatGPT to Apply / to Restore Show Mini" while the running ChatGPT still
    /// has an outdated keymap, shown on or off (turning off needs a restart too). While
    /// Quick Chat holds Mini's shortcut it shows this item itself, so it appears only once.
    func menuItems() -> [NSMenuItem] {
        guard !lockedByQuickChat, let restart = showMini.restartMenuItem() else { return [] }
        return [restart]
    }

    init(showMini: ShowMiniController) {
        self.showMini = showMini
    }

    /// Without ChatGPT this silently stays off (no alert at launch); the saved
    /// preference is kept, so it applies on the next launch once ChatGPT is installed.
    func enable() throws {
        guard !isEnabled, chatGPTInstalled else { return }
        try showMini.set(.userDisabled, active: true)
        isEnabled = true
    }

    func disable() {
        try? showMini.set(.userDisabled, active: false) // restoring never throws
        isEnabled = false
    }
}
