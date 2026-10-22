import AppKit

/// Quick Chat: a global shortcut (default ⌥Space, changeable) toggles a floating
/// panel running chatgpt.com, in the spirit of ChatGPT Classic's companion chat. Two more
/// (Ask About Selection, default ⌥⇧Space, and Ask About Clipboard, default ⌥⇧V) open it with a
/// new chat about the selected or copied text.
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
    private var clipboardShortcut = Shortcut.loadAskClipboard()
    private var clipboardHotKey: GlobalHotKey?
    /// The Ask shortcuts that couldn't be registered (another app has them), and why; Quick Chat
    /// works without them.
    private var unavailable: [(name: String, shortcut: Shortcut, error: Error)] = []
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

    /// Registers the Quick Chat shortcut (throws if it can't) and the Ask shortcuts. If only an
    /// Ask one fails (another app has it), Quick Chat still works and the menu says so, so
    /// another one can be picked in Change Shortcut….
    private func registerHotKey() throws {
        unregisterHotKeys()
        hotKey = try GlobalHotKey(shortcut) { [weak self] in self?.chat.toggle() }
        unavailable = []
        askHotKey = registerAsk("Ask About Selection", askShortcut) { [weak self] in self?.askAboutSelection() }
        clipboardHotKey = registerAsk("Ask About Clipboard", clipboardShortcut) { [weak self] in self?.askAboutClipboard() }
    }

    /// Registers an Ask shortcut, unless one of Quick Chat's other shortcuts has it (the recorder
    /// keeps them apart, but Ask About Clipboard's default arrived after the others were picked).
    private func registerAsk(_ name: String, _ shortcut: Shortcut, _ handler: @escaping @MainActor () -> Void) -> GlobalHotKey? {
        let others: [(String, Shortcut)] = [("Quick Chat", self.shortcut), ("Ask About Selection", askShortcut),
                                            ("Ask About Clipboard", clipboardShortcut),
                                            ("Reset Size & Position", chat.resetSizeShortcut), ("Maximize", chat.maximizeShortcut)]
        do {
            if let other = others.first(where: { $0.0 != name && $0.1 == shortcut })?.0 {
                throw FeatureError("\(shortcut.displayString) is already \(other).",
                                   recoverySuggestion: "Choose a different shortcut for \(name) in Change Shortcut….")
            }
            return try GlobalHotKey(shortcut, handler: handler)
        } catch {
            unavailable.append((name, shortcut, error))
            log.error("\(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func unregisterHotKeys() {
        for key in [hotKey, askHotKey, clipboardHotKey] { key?.unregister() }
        hotKey = nil
        askHotKey = nil
        clipboardHotKey = nil
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

    /// Opens the panel with a new chat holding the clipboard's text, as Ask About Selection does,
    /// without pressing ⌘C (so no Accessibility access). Without text there (only an image, say),
    /// just opens the panel and says so. Reads the clipboard only when asked.
    private func askAboutClipboard() {
        let text = NSPasteboard.general.string(forType: .string)
        if let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chat.ask(about: text)
        } else {
            chat.show()
            chat.showToast("No text on the clipboard", symbol: "doc.on.clipboard")
        }
    }

    // MARK: Menu

    private var takesMiniShortcut: Bool { showMini.reasons.contains(.quickChatShortcut) }

    var statusText: String? {
        guard isEnabled, !unavailable.isEmpty else { return nil }
        return unavailable.map { "\($0.name): \($0.shortcut.displayString) is unavailable" }.joined(separator: "; ")
    }

    func menuItems() -> [NSMenuItem] {
        guard isEnabled else { return [] }
        var items: [NSMenuItem] = [
            ActionMenuItem("Open Chat in Browser (⇧⌘B)", isEnabled: chat.chatURLForBrowser != nil) { [weak self] in
                self?.chat.openChatInBrowser()
            },
            ActionMenuItem("Ask About Clipboard (\(clipboardShortcut.displayString))") { [weak self] in self?.askAboutClipboard() },
            ActionMenuItem("Change Shortcut… (\(shortcut.displayString))") { [weak self] in self?.editShortcut() },
            ActionMenuItem("Sign Out of Quick Chat…") { [weak self] in self?.confirmSignOut() },
        ]
        if takesMiniShortcut, let restart = showMini.restartMenuItem() { items.insert(restart, at: 0) }
        return items
    }

    /// Signing out deletes the panel's sign-in, so it asks first.
    private func confirmSignOut() {
        let alert = NSAlert()
        alert.messageText = "Sign out of Quick Chat?"
        alert.informativeText = "This deletes Quick Chat's cookies and website data, so you'll need to sign in again. "
            + "Your chats stay in your ChatGPT account."
        alert.addButton(withTitle: "Sign Out")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn { chat.signOut() }
    }

    private func editShortcut() {
        unregisterHotKeys() // so the current shortcuts can be pressed in the recorder
        let previous = shortcut
        let previousAsk = askShortcut
        let previousClipboard = clipboardShortcut
        let previousResetSize = chat.resetSizeShortcut
        let previousMaximize = chat.maximizeShortcut
        recorder.show(current: shortcut, ask: askShortcut, clipboard: clipboardShortcut, resetSize: chat.resetSizeShortcut,
                      maximize: chat.maximizeShortcut, miniShortcut: showMini.userShortcutDescription, onChange: { [weak self] new in
            self?.shortcut = new
        }, onAskChange: { [weak self] new in
            self?.askShortcut = new
        }, onClipboardChange: { [weak self] new in
            self?.clipboardShortcut = new
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
                if let error = self.unavailable.first?.error { throw error }
                try self.showMini.set(.quickChatShortcut, active: self.showMini.conflicts(with: self.shortcut))
                self.shortcut.save()
                self.askShortcut.saveAsAsk()
                self.clipboardShortcut.saveAsAskClipboard()
                self.log.info("Shortcuts: \(self.shortcut.displayString, privacy: .public), ask \(self.askShortcut.displayString, privacy: .public), clipboard \(self.clipboardShortcut.displayString, privacy: .public)")
                self.showMini.offerRestartIfNeeded()
            } catch {
                self.log.error("Shortcut rejected: \(error.localizedDescription, privacy: .public)")
                // Put all five back as they were, which keeps them distinct.
                self.shortcut = previous
                self.askShortcut = previousAsk
                self.clipboardShortcut = previousClipboard
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
