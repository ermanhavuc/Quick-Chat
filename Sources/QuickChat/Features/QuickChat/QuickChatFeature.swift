import AppKit

/// Quick Chat: a global shortcut (default ⌥Space, changeable) toggles a floating
/// panel running chatgpt.com, in the spirit of ChatGPT Classic's companion chat. Another one
/// (Ask About Selection, default ⌥⇧Space) opens it with a new chat about the selected text.
///
/// If the shortcut is the same as ChatGPT's Show Mini shortcut, Show Mini is unbound
/// (through `ShowMiniController`) while this feature is on, so the two don't fight.
@MainActor
final class QuickChatFeature: Feature {
    let id = "miniChat" // pre-rename id; persisted, keep
    var title: String { "Quick Chat" }
    private(set) var isEnabled = false

    private let log = Log.make("QuickChat")
    private let showMini: ShowMiniController
    private var shortcut = Shortcut.load()
    private var hotKey: GlobalHotKey?
    private var askShortcut = Shortcut.loadAsk()
    private var askHotKey: GlobalHotKey?
    /// Why Ask About Selection's shortcut couldn't be registered; Quick Chat works without it.
    private var askError: Error?
    /// Set while Ask About Selection borrows the clipboard, so a second press waits its turn.
    private var isAsking = false
    private lazy var chat = QuickChatController()
    private let recorder = ShortcutRecorderWindow()

    init(showMini: ShowMiniController) {
        self.showMini = showMini
    }

    func enable() throws {
        guard !isEnabled else { return }
        try showMini.set(.quickChatShortcut, active: showMini.conflicts(with: shortcut))
        do {
            try registerHotKey()
        } catch {
            try? showMini.set(.quickChatShortcut, active: false)
            throw error
        }
        isEnabled = true
        log.info("Enabled with shortcut \(self.shortcut.displayString, privacy: .public)")
    }

    func disable() {
        unregisterHotKeys()
        recorder.close()
        chat.tearDown()
        try? showMini.set(.quickChatShortcut, active: false)
        isEnabled = false
        log.info("Disabled")
    }

    /// Puts the Quick Chat panel back to its default size and spot (same as the Reset Size & Position shortcut).
    func resetSize() { chat.resetSize() }

    /// Registers the Quick Chat shortcut (throws if it can't) and Ask About Selection's. If only
    /// the latter fails (another app has it), Quick Chat still works and the menu says so, so
    /// another one can be picked in Change Shortcut….
    private func registerHotKey() throws {
        unregisterHotKeys()
        hotKey = try GlobalHotKey(shortcut) { [weak self] in self?.chat.toggle() }
        do {
            askHotKey = try GlobalHotKey(askShortcut) { [weak self] in self?.askAboutSelection() }
            askError = nil
        } catch {
            askError = error
            log.error("Ask About Selection: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func unregisterHotKeys() {
        hotKey?.unregister()
        askHotKey?.unregister()
        hotKey = nil
        askHotKey = nil
    }

    /// Opens the panel with a new chat holding the frontmost app's selected text; with no
    /// selection, just opens the panel. The first time, macOS asks for Accessibility access
    /// (needed to copy the selection) and the panel stays closed.
    private func askAboutSelection() {
        guard !isAsking, Permissions.checkAccessibility(prompt: true) else { return }
        isAsking = true
        Task {
            let text = await SelectedText.copy()
            isAsking = false
            guard isEnabled else { return }
            if let text { chat.ask(about: text) } else { chat.show() }
        }
    }

    // MARK: Menu

    private var takesMiniShortcut: Bool { showMini.reasons.contains(.quickChatShortcut) }

    var statusText: String? {
        guard isEnabled, askError != nil else { return nil }
        return "Ask About Selection: \(askShortcut.displayString) is unavailable"
    }

    func menuItems() -> [NSMenuItem] {
        guard isEnabled else { return [] }
        var items: [NSMenuItem] = [
            ActionMenuItem("Change Shortcut… (\(shortcut.displayString))") { [weak self] in self?.editShortcut() },
            ActionMenuItem("Sign Out of Quick Chat") { [weak self] in self?.chat.signOut() },
        ]
        if takesMiniShortcut, let restart = showMini.restartMenuItem() { items.insert(restart, at: 0) }
        return items
    }

    private func editShortcut() {
        unregisterHotKeys() // so the current shortcuts can be pressed in the recorder
        let previous = shortcut
        let previousAsk = askShortcut
        let previousResetSize = chat.resetSizeShortcut
        let previousMaximize = chat.maximizeShortcut
        recorder.show(current: shortcut, ask: askShortcut, resetSize: chat.resetSizeShortcut,
                      maximize: chat.maximizeShortcut, miniShortcut: showMini.userShortcutDescription, onChange: { [weak self] new in
            self?.shortcut = new
        }, onAskChange: { [weak self] new in
            self?.askShortcut = new
        }, onResetSizeChange: { [weak self] new in
            self?.chat.resetSizeShortcut = new
            new.saveAsResetSize()
        }, onMaximizeChange: { [weak self] new in
            self?.chat.maximizeShortcut = new
            new.saveAsMaximize()
        }, onClose: { [weak self] in
            guard let self, self.isEnabled else { return }
            do {
                try self.registerHotKey()
                if let askError = self.askError { throw askError }
                try self.showMini.set(.quickChatShortcut, active: self.showMini.conflicts(with: self.shortcut))
                self.shortcut.save()
                self.askShortcut.saveAsAsk()
                self.log.info("Shortcuts: \(self.shortcut.displayString, privacy: .public), ask \(self.askShortcut.displayString, privacy: .public)")
                self.showMini.offerRestartIfNeeded()
            } catch {
                self.log.error("Shortcut rejected: \(error.localizedDescription, privacy: .public)")
                // Put all four back as they were, which keeps them distinct.
                self.shortcut = previous
                self.askShortcut = previousAsk
                self.chat.resetSizeShortcut = previousResetSize
                previousResetSize.saveAsResetSize()
                self.chat.maximizeShortcut = previousMaximize
                previousMaximize.saveAsMaximize()
                try? self.registerHotKey()
                NSApp.activate()
                NSAlert(error: error).runModal()
            }
        })
    }
}
