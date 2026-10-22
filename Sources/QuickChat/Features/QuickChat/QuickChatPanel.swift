import AppKit
import WebKit

/// Floating Quick Chat in the spirit of ChatGPT Classic's companion chat: chatgpt.com in a
/// web view, which uses its compact layout at this width.
@MainActor
final class QuickChatController: NSObject {
    private static let chatURL = URL(string: "https://chatgpt.com/")!
    /// A new temporary chat (not saved in your chat history): what the panel starts on, and what
    /// ⌘N and Ask About Selection open.
    static let temporaryChatPath = "/?temporary-chat=true"
    private static let temporaryChatURL = URL(string: temporaryChatPath, relativeTo: chatURL)!
    /// Sign-in pages (OpenAI, Google, Apple, Microsoft), which with chatgpt.com are the only pages
    /// links open inside Quick Chat. Just these hosts, not their whole sites: a link to e.g.
    /// openai.com/terms or support.apple.com belongs in the browser.
    private static let signInHosts = ["auth.openai.com", "auth0.openai.com", "auth0.com", "accounts.google.com",
                                      "appleid.apple.com", "login.microsoftonline.com", "login.live.com",
                                      "login.microsoft.com"]
    private static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    private let log = Log.make("QuickChat")
    private var panel: QuickChatPanel?
    private var webView: QuickChatWebView?
    /// The panel's content: the web view, its find bar and toasts.
    private var content: QuickChatContentView?
    /// Open popup windows (see `makePopup`); each one leaves this list when it closes.
    private var popups: [NSWindow] = []
    private var previousApp: NSRunningApplication?
    /// Where each in-flight download is being written, for "show in Finder" when it finishes.
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]
    /// Downloads that finished while the panel was hidden, announced when it's shown again.
    private var unseenDownloads: [URL] = []

    var isVisible: Bool { panel?.isVisible == true }

    /// Local shortcut (only while the panel is key) that triggers `resetPosition()`.
    var resetSizeShortcut = Shortcut.loadResetSize() {
        didSet { panel?.resetSizeShortcut = resetSizeShortcut }
    }

    /// Local shortcut (only while the panel is key) that toggles maximize.
    var maximizeShortcut = Shortcut.loadMaximize() {
        didSet { panel?.maximizeShortcut = maximizeShortcut }
    }

    /// Puts the panel back to its default size at the bottom center of its screen (no-op if it
    /// was never built).
    func resetPosition() { panel?.resetPosition() }

    static let pageZoomDefaultsKey = "quickChat.pageZoom"
    /// Below 100% so text is smaller than chatgpt.com's own; ⌘0 comes back here.
    static let defaultPageZoom: CGFloat = 0.9
    /// The ⌘− / ⌘= steps (Chrome's zoom levels).
    private static let pageZoomLevels: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]

    /// chatgpt.com's zoom in the panel, remembered across launches.
    private var pageZoom = UserDefaults.standard.object(forKey: pageZoomDefaultsKey) as? CGFloat ?? defaultPageZoom {
        didSet {
            webView?.pageZoom = pageZoom
            updateFirstClickBand()
            UserDefaults.standard.set(Double(pageZoom), forKey: Self.pageZoomDefaultsKey)
        }
    }

    /// Zooms one level out (`step` < 0) or in (> 0), or back to the default (0), and says so.
    func zoom(_ step: Int) {
        let next = step == 0 ? Self.defaultPageZoom
            : step > 0 ? Self.pageZoomLevels.first { $0 > pageZoom + 0.001 }
            : Self.pageZoomLevels.last { $0 < pageZoom - 0.001 }
        let symbol = step < 0 ? "minus.magnifyingglass" : step > 0 ? "plus.magnifyingglass" : "magnifyingglass"
        let percent = "Zoom \(Int((pageZoom * 100).rounded()))%"
        guard let next else {
            NSSound.beep()
            return showToast("\(percent), the \(step > 0 ? "largest" : "smallest")", symbol: symbol)
        }
        pageZoom = next
        showToast("Zoom \(Int((pageZoom * 100).rounded()))%", symbol: symbol)
    }

    /// A short message over the top of the panel (see `QuickChatContentView.showToast`).
    func showToast(_ text: String, symbol: String? = nil, action: ToastAction? = nil) {
        content?.showToast(text, symbol: symbol, action: action)
    }

    static let hidesTopBarDefaultsKey = "quickChat.hidesTopBar"

    /// Whether chatgpt.com's top bar is hidden (see `hideTopBarCSS`); it is by default. Remembered
    /// across launches.
    private(set) var hidesTopBar = UserDefaults.standard.object(forKey: hidesTopBarDefaultsKey) as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(hidesTopBar, forKey: Self.hidesTopBarDefaultsKey)
            updateFirstClickBand()
            guard let webView else { return }
            addUserScripts(to: webView.configuration.userContentController) // for the next page loads
            webView.evaluateJavaScript(Self.topBarScript(hidden: hidesTopBar))
        }
    }

    /// ⌘\: shows or hides chatgpt.com's top bar.
    func toggleTopBar() { hidesTopBar.toggle() }

    /// chatgpt.com's top bar height (its --height-toolbar), in CSS pixels.
    private static let topBarHeight: CGFloat = 52

    /// While the top bar is shown, a first click on its band reaches the page (see `QuickChatWebView`).
    private func updateFirstClickBand() {
        webView?.firstClickBand = hidesTopBar ? 0 : Self.topBarHeight * pageZoom
    }

    /// ⌘N / ⇧⌘N: a new temporary chat (chatgpt.com's `?temporary-chat=true`), or a new saved one.
    /// Both are Chat, never Work (`chatOnlyScript`).
    func newChat(temporary: Bool) {
        let path = temporary ? Self.temporaryChatPath : "/"
        webView?.callAsyncJavaScript(Self.newChatScript, arguments: ["path": path],
                                     in: nil, in: .page) { [weak self] result in
            guard case .failure(let error) = result, let self else { return }
            self.log.error("New chat: \(error.localizedDescription, privacy: .public)")
            self.webView?.load(URLRequest(url: URL(string: path, relativeTo: Self.chatURL)!))
        }
    }

    /// Goes to `path` through chatgpt.com's own router (pushState plus the popstate event that
    /// Back/Forward fire), which is quicker than reloading the app, then focuses the new chat's
    /// message box once it's there (throwing after 5 s, so `newChat` reloads instead). Already
    /// there: does nothing if that chat has no messages yet, else reloads so the chat starts
    /// fresh. Loads chatgpt.com when on another site (sign-in).
    private static let newChatScript = """
        \(messageBoxScript)
        if (location.host !== "chatgpt.com") { location.href = "https://chatgpt.com" + path; return; }
        if (location.pathname + location.search === path) {
          if (\(hasMessagesScript)) location.reload(); else messageBox()?.focus();
          return;
        }
        const previous = messageBox();
        history.pushState(null, "", path);
        dispatchEvent(new PopStateEvent("popstate", {state: null}));
        const box = await newMessageBox(previous);
        if (!box) throw new Error("no message box in the new chat");
        box.focus();
        """

    /// `messageBox()`: the rendered message box. `newMessageBox(previous)`: waits (up to 5 s) for
    /// a new chat's message box: the previous one stays in the page, hidden, and may still show
    /// for a moment.
    private static let messageBoxScript = """
        const sleep = ms => new Promise(r => setTimeout(r, ms));
        const messageBox = () => [...document.querySelectorAll('#prompt-textarea, form [contenteditable="true"]')]
          .find(e => e.getClientRects().length);
        const newMessageBox = async previous => {
          for (let i = 0; i < 100; i++) {
            const box = messageBox();
            if (box && box !== previous) return box;
            await sleep(50);
          }
          return null;
        };
        """

    /// Whether the visible chat has messages (each turn has a data-turn-key); the previous
    /// chat's stay in the page, hidden, after a new chat.
    private static let hasMessagesScript =
        #"[...document.querySelectorAll("[data-turn-key]")].some(e => e.getClientRects().length)"#

    /// Text for `ask(about:)` that waits for the page to finish loading; `afterReload` once the
    /// page was reloaded for it.
    private var pendingQuestion: (text: String, afterReload: Bool)?

    /// Shows the panel with a new temporary chat that has `text` in its message box (after
    /// anything already typed there), ready for a question about it.
    func ask(about text: String) {
        show()
        guard let webView else { return }
        if webView.isLoading { pendingQuestion = (text, false) } else { insertQuestion(text, afterReload: false) }
    }

    private func insertQuestion(_ text: String, afterReload: Bool) {
        webView?.callAsyncJavaScript(Self.askScript, arguments: ["text": text, "path": Self.temporaryChatPath],
                                     in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value as String) where value == "reload" && !afterReload:
                // A chat with messages at the new chat's own address: only a reload leaves it.
                self.pendingQuestion = (text, true)
                self.webView?.load(URLRequest(url: Self.temporaryChatURL))
            case .success(let value as String) where value == "reload":
                self.log.error("Ask about selection: still in a chat after reloading")
                NSSound.beep()
            case .success:
                break
            case .failure(let error):
                let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                self.log.error("Ask about selection: \(message ?? error.localizedDescription, privacy: .public)")
                NSSound.beep()
            }
        }
    }

    /// Opens a new chat at `path` like `newChatScript`, but never reloads itself, which would
    /// drop the text: it returns "reload" if that's needed, and `insertQuestion` reloads and
    /// runs it again. Then pastes `text` into the message box as if with ⌘V (so a long text
    /// becomes an attachment, as chatgpt.com does with pastes), followed by an empty line for
    /// the question. The previous chat's message box is never written to (`newMessageBox`).
    private static let askScript = """
        \(messageBoxScript)
        if (location.hostname !== "chatgpt.com") throw new Error("not on chatgpt.com");
        const here = location.pathname + location.search === path;
        if (here && \(hasMessagesScript)) return "reload";
        const previous = here ? null : messageBox();
        if (previous !== null) {
          history.pushState(null, "", path);
          dispatchEvent(new PopStateEvent("popstate", {state: null}));
        }
        const box = await newMessageBox(previous);
        if (!box) throw new Error("no message box in the new chat");
        box.focus();
        const end = document.createRange();
        end.selectNodeContents(box);
        end.collapse(false);
        getSelection().removeAllRanges();
        getSelection().addRange(end);
        await sleep(50);
        const lines = text.replace(/^\\s*\\n|\\n\\s*$/g, ""); // no blank lines around it; indentation stays
        const paste = (box.innerText.trim() ? "\\n\\n" : "") + lines + "\\n\\n";
        const data = new DataTransfer();
        data.setData("text/plain", paste);
        if (box.dispatchEvent(new ClipboardEvent("paste", {clipboardData: data, bubbles: true, cancelable: true}))) {
          document.execCommand("insertText", false, paste); // the page ignored the paste
        }
        """

    /// Set while `stepEffort` runs, so a held ⌘] can't open and close the picker over itself.
    private var isSteppingEffort = false

    /// Moves chatgpt.com's thinking effort (Instant, Medium, High…) one level down (`step` < 0)
    /// or up (> 0) and shows the new level. Beeps when there's no effort control or it's already
    /// at that end.
    func stepEffort(_ step: Int) {
        guard let webView, !isSteppingEffort else { return }
        isSteppingEffort = true
        webView.callAsyncJavaScript(Self.stepEffortScript, arguments: ["step": step],
                                    in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            self.isSteppingEffort = false
            switch result {
            case .success(let value as [String: Any]):
                var level = (value["level"] as? String ?? "").trimmingCharacters(in: .whitespaces)
                if level.hasSuffix(".") { level.removeLast() }
                if value["changed"] as? Bool == true {
                    self.log.info("Thinking effort: \(level, privacy: .public)")
                    self.showToast("Thinking: \(level)", symbol: "brain")
                } else {
                    NSSound.beep()
                    self.showToast("Thinking: \(level), the \(step > 0 ? "highest" : "lowest")", symbol: "brain")
                }
            case .success, .failure:
                if case .failure(let error) = result {
                    // A thrown Error's message is in the userInfo; the description just says "exception".
                    let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                    self.log.error("Thinking effort: \(message ?? error.localizedDescription, privacy: .public)")
                }
                NSSound.beep()
                self.showToast("No thinking effort to change here", symbol: "brain")
            }
        }
    }

    /// The effort slider sits in the composer's model picker menu ("Power"; Left/Right arrow keys
    /// adjust it, as the menu item's aria-keyshortcuts says). Opens the menu if needed, steps the
    /// slider, closes the menu again and puts focus back in the composer. Returns the level
    /// after the step ("High, 3 of 5.") and whether it changed. Only rendered elements count:
    /// after a new chat the page keeps the previous chat's composer around, hidden, ahead of the
    /// new one. Depends on chatgpt.com's markup.
    private static let stepEffortScript = """
        const sleep = ms => new Promise(r => setTimeout(r, ms));
        const shown = selector => [...document.querySelectorAll(selector)].filter(e => e.getClientRects().length);
        const findSlider = () => shown('[role="menu"] [role="menuitem"][aria-keyshortcuts~="ArrowRight"]')[0];
        const level = slider => slider.closest('[role="menu"]').querySelector('[role="status"]')?.textContent;
        const press = (el, key) => el.dispatchEvent(new KeyboardEvent("keydown", {key, code: key, bubbles: true, cancelable: true}));
        let slider = findSlider();
        const opened = !slider;
        if (opened) {
          const trigger = shown('form button[aria-label="Select ChatGPT model"]')[0]
            ?? shown('form button[aria-haspopup="menu"]').pop();
          if (!trigger) throw new Error("no model picker in the composer");
          // Radix menus open on pointerdown, not click.
          trigger.dispatchEvent(new PointerEvent("pointerdown", {bubbles: true, cancelable: true, button: 0, pointerType: "mouse", isPrimary: true}));
          for (let i = 0; i < 20 && !(slider = findSlider()); i++) await sleep(25);
          if (!slider) {
            const menu = shown('[role="menu"]')[0];
            if (menu) press(menu, "Escape");
            throw new Error("no effort slider in the model picker");
          }
        }
        const before = level(slider);
        slider.focus();
        press(slider, step > 0 ? "ArrowRight" : "ArrowLeft");
        await sleep(0);
        const after = level(slider);
        if (opened) {
          press(slider.closest('[role="menu"]'), "Escape");
          await sleep(50);
          \(focusComposerScript)
        }
        return {level: after ?? "", changed: after !== before};
        """

    /// Hides the panel whenever it's visible (focused or not), otherwise shows it. Focus goes
    /// back to the previous app only if the panel had it.
    func toggle() {
        if let panel, panel.isVisible {
            hide(restoreFocus: panel.isKeyWindow && NSApp.isActive)
        } else {
            show()
        }
    }

    func show() {
        let panel = self.panel ?? makePanel()
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(webView)
        focusComposer()
        stopWatchingAnswer()
        hasUnseenAnswer = false
        if !unseenDownloads.isEmpty {
            announceDownloads(unseenDownloads)
            unseenDownloads = []
        }
    }

    /// `restoreFocus`: give focus back to the app that was frontmost before showing.
    func hide(restoreFocus: Bool) {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        if restoreFocus { previousApp?.activate() }
        watchAnswer()
    }

    /// Closes the panel and releases the web view (the sign-in session stays in the data store).
    func tearDown() {
        for popup in popups { popup.close() }
        panel?.orderOut(nil)
        webView?.stopLoading()
        content?.finder.client = nil
        panel?.contentView = nil
        panel = nil
        webView = nil
        content = nil
        pendingQuestion = nil
        stopWatchingAnswer()
        hasUnseenAnswer = false
    }

    // MARK: Answer ready

    /// Posted when `hasUnseenAnswer` changes (the menu-bar icon shows a dot meanwhile).
    static let unseenAnswerDidChange = Notification.Name("QuickChatUnseenAnswerDidChange")

    /// An answer finished while the panel was hidden; cleared when it's shown again.
    private(set) var hasUnseenAnswer = false {
        didSet {
            guard hasUnseenAnswer != oldValue else { return }
            NotificationCenter.default.post(name: Self.unseenAnswerDidChange, object: self)
        }
    }

    private var answerTimer: Timer?

    /// After hiding: if chatgpt.com is still answering, checks once a second until it's done
    /// (the page keeps answering while hidden), then sets `hasUnseenAnswer`.
    private func watchAnswer() {
        stopWatchingAnswer()
        webView?.evaluateJavaScript(Self.answeringScript) { [weak self] answering, _ in
            MainActor.assumeIsolated {
                guard let self, answering as? Bool == true, !self.isVisible, self.answerTimer == nil else { return }
                self.answerTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.checkAnswer() }
                }
            }
        }
    }

    private func checkAnswer() {
        guard let webView, !isVisible else { return stopWatchingAnswer() }
        webView.evaluateJavaScript(Self.answeringScript) { [weak self] answering, _ in
            MainActor.assumeIsolated {
                // A page that's loading or gone answers nothing: keep checking.
                guard let self, answering as? Bool == false, self.answerTimer != nil, !self.isVisible else { return }
                self.stopWatchingAnswer()
                self.hasUnseenAnswer = true
                self.log.info("An answer finished while the panel was hidden")
            }
        }
    }

    private func stopWatchingAnswer() {
        answerTimer?.invalidate()
        answerTimer = nil
    }

    /// Whether chatgpt.com is answering: the message box's send button has become Stop (a
    /// plain button rather than the form's submit button; or labeled Stop, in English).
    static let answeringScript = #"""
        [...document.querySelectorAll('form button[class~="bg-composer-primary"][type="button"], form button[aria-label="Stop"]')]
          .some(b => b.getClientRects().length)
        """#

    // MARK: Find, browser

    /// ⇧⌘F / ⌘G / ⇧⌘G: the find bar (AppKit's, as in Safari) over the page.
    func find(_ action: NSTextFinder.Action) {
        content?.find(action)
    }

    /// The open chat on chatgpt.com, for the browser: only a saved chat with messages. A
    /// temporary chat can't be opened elsewhere, and a new chat has nothing to open.
    var chatURLForBrowser: URL? { webView?.url.flatMap(Self.browserURL(for:)) }

    static func browserURL(for url: URL) -> URL? {
        guard url.scheme == "https", url.host?.lowercased() == "chatgpt.com", url.path.hasPrefix("/c/"),
              !url.path.hasPrefix("/c/local-"), !isTemporary(url),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// chatgpt.com keeps `?temporary-chat=true` on a temporary chat, also once it has messages.
    static func isTemporary(_ url: URL) -> Bool {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .contains { $0.name == "temporary-chat" && $0.value == "true" } == true
    }

    /// ⇧⌘B: opens the chat in the default browser (`chatURLForBrowser`) and hides the panel.
    func openChatInBrowser() {
        guard let url = chatURLForBrowser else {
            NSSound.beep()
            let temporary = webView?.url.map(Self.isTemporary) == true
            return showToast(temporary ? "A temporary chat can't open in the browser" : "No saved chat to open yet",
                             symbol: "safari")
        }
        NSWorkspace.shared.open(url)
        hide(restoreFocus: false)
    }

    /// Signs out by clearing the panel's website data (cookies, storage).
    func signOut() {
        pendingQuestion = nil
        let store = WKWebsiteDataStore.default()
        store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) { [weak self] in
            MainActor.assumeIsolated {
                self?.log.info("Cleared Quick Chat website data")
                self?.webView?.load(URLRequest(url: Self.chatURL))
            }
        }
    }

    // MARK: Building

    private func makePanel() -> QuickChatPanel {
        let panel = QuickChatPanel(contentRect: NSRect(origin: .zero, size: QuickChatPanel.defaultSize))
        panel.onCancel = { [weak self] in self?.hide(restoreFocus: true) }
        panel.onZoom = { [weak self] in self?.zoom($0) }
        panel.onEffort = { [weak self] in self?.stepEffort($0) }
        panel.onNewChat = { [weak self] in self?.newChat(temporary: $0) }
        panel.onToggleTopBar = { [weak self] in self?.toggleTopBar() }
        panel.onFind = { [weak self] in self?.find($0) }
        panel.onOpenInBrowser = { [weak self] in self?.openChatInBrowser() }
        panel.resetSizeShortcut = resetSizeShortcut
        panel.maximizeShortcut = maximizeShortcut

        let webView = makeWebView()
        let content = QuickChatContentView(webView: webView)
        panel.setContent(content)
        self.content = content

        if !panel.setFrameUsingName(QuickChatPanel.autosaveName) {
            // First open: the bottom center of the screen with the mouse.
            let mouse = NSEvent.mouseLocation
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main {
                panel.setFrame(panel.bottomCenterFrame(on: screen), display: false)
            }
        }
        panel.setFrameAutosaveName(QuickChatPanel.autosaveName)

        self.panel = panel
        self.webView = webView
        webView.load(URLRequest(url: Self.temporaryChatURL))
        return panel
    }

    /// A window for a page opened with `window.open` / target=_blank, like a browser's popup. The
    /// web view must come from WebKit's `configuration` so the page keeps its `window.opener`:
    /// popup sign-ins (Google's "Continue as" card) post their result back through it and then
    /// close themselves. Loading such pages in the panel instead left a blank Google page.
    private func makePopup(configuration: WKWebViewConfiguration, windowFeatures: WKWindowFeatures) -> WKWebView {
        let size = NSSize(width: windowFeatures.width?.doubleValue ?? 480, height: windowFeatures.height?.doubleValue ?? 640)
        let webView = WKWebView(frame: NSRect(origin: .zero, size: size), configuration: configuration)
        webView.customUserAgent = Self.safariUserAgent // Google refuses sign-in from web views that look embedded
        webView.uiDelegate = self
        webView.navigationDelegate = self

        let popup = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
        popup.isReleasedWhenClosed = false
        popup.level = .floating // same level as the panel, ordered in front of it
        popup.contentView = webView
        popup.bind(.title, to: webView, withKeyPath: "title", options: [.nullPlaceholder: "Quick Chat"])
        popup.delegate = self
        if let panel {
            popup.setFrameOrigin(NSPoint(x: panel.frame.midX - popup.frame.width / 2,
                                         y: panel.frame.midY - popup.frame.height / 2))
        } else {
            popup.center()
        }
        popups.append(popup)
        popup.makeKeyAndOrderFront(nil)
        return webView
    }

    private func makeWebView() -> QuickChatWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = []
        addUserScripts(to: config.userContentController)
        config.userContentController.add(self, name: Self.dragMessage)
        config.userContentController.add(self, name: Self.openInBrowserMessage)
        let webView = QuickChatWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.safariUserAgent
        webView.pageZoom = pageZoom
        webView.firstClickBand = hidesTopBar ? 0 : Self.topBarHeight * pageZoom
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.underPageBackgroundColor = .windowBackgroundColor
        return webView
    }

    /// The page touch-ups, run at the start of every chatgpt.com page load. Replaces the earlier
    /// ones, so `hidesTopBar` changes reach the next load.
    private func addUserScripts(to controller: WKUserContentController) {
        controller.removeAllUserScripts()
        for source in [Self.pageStyleScript, Self.topBarScript(hidden: hidesTopBar), Self.dragScript, Self.chatOnlyScript,
                       Self.shareInMenuScript] {
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
    }

    /// Focuses chatgpt.com's message box: once a contenteditable #prompt-textarea, now an unnamed
    /// contenteditable (ProseMirror) in the composer form. Pages also keep a hidden one (a chat
    /// has the new-chat page's), so it takes the first that's rendered. Best effort, as it
    /// depends on chatgpt.com's markup.
    private static let focusComposerScript =
        #"[...document.querySelectorAll('#prompt-textarea, form [contenteditable="true"]')].find(e => e.getClientRects().length)?.focus();"#

    private func focusComposer() {
        webView?.evaluateJavaScript(Self.focusComposerScript)
    }

    /// Mac colors for chatgpt.com's surfaces: the page and its top bar, sidebar and side rail take
    /// macOS's content background, and the message box a step lighter (darker in light mode). These
    /// system colors follow the page's own Light/Dark theme. chatgpt.com's accent (send button,
    /// your messages, selection) is left alone.
    private static let macColorsCSS = """
        :root, [data-theme] {
          --quick-chat-surface: -apple-system-control-background;
          --quick-chat-elevated: color-mix(in srgb, -apple-system-control-background 92%, -apple-system-label);
          --app-color-background-surface: var(--quick-chat-surface);
          --app-color-background-surface-under: var(--quick-chat-surface);
          --app-color-background-shell: var(--quick-chat-surface);
          --color-background-panel: var(--quick-chat-surface);
          --app-color-background-elevated-primary: var(--quick-chat-elevated);
          --app-color-background-elevated-primary-opaque: var(--quick-chat-elevated);
          --color-background-composer-surface: var(--quick-chat-elevated);
        }
        """

    /// Layout fixes for chatgpt.com's browser-tab layout, which shows a bit off in the panel:
    /// - The gap under the message box is 24px in a chat, and on the new-chat page 24px plus a
    ///   16px-padded notice slot under the box (empty, or "For safety, we may keep a copy of this
    ///   chat…" in a temporary chat), against 16px at the sides; it showed as a dark strip under
    ///   the box. The notice is hidden and the gap matches the sides (both follow
    ///   --thread-body-inline-padding). Other banners in that slot keep their space.
    /// - The top bar is transparent, with only its button groups on pills, so a chat scrolled
    ///   under it showed through between and around the buttons. It now gets the page's surface
    ///   color, as the pills have.
    /// - Under a chat's last message, 82px separated its action icons from the message box: 6px
    ///   of list gap (before an empty placeholder chatgpt.com sizes while answering), 20px and
    ///   32px of padding, and the 24px "ChatGPT can make mistakes" line. That line is hidden and
    ///   the rest cut to nothing, so the icons end at the scroll area's edge, 16px above the box
    ///   (see the last point).
    /// - In the narrow layout, the temporary chat page's content keeps a scroll bar's width free
    ///   at its right edge (scrollbar-gutter: stable). With a mouse connected, macOS shows
    ///   scroll bars that take up room, so the message box sat 15px further from the right edge
    ///   than the left, though nothing scrolled. The room is now kept only while it scrolls.
    /// - In a chat, the scroll area filled the panel and the messages scrolled behind the
    ///   message box, over a solid strip from the box's top edge down; a spacer as tall as that
    ///   strip (chatgpt.com measures it into --thread-scroll-padding-bottom) let the last message
    ///   scroll above it. So text ran right up to the box, and with a mouse connected the scroll
    ///   bar ran down beside the box, its thumb hidden behind the strip at the end of a chat.
    ///   The scroll area now ends 16px above the box (the gap at its sides), so its scroll bar
    ///   and text end there too, and the spacer is gone. The variable is the strip's height plus
    ///   that 16px (the spacer subtracts it), so the scroll area is the panel minus the variable.
    /// If chatgpt.com renames these hooks, the rules stop matching and the page looks as before.
    private static let pageLayoutCSS = """
        body, body [data-theme] { --thread-composer-bottom-inset: var(--thread-body-inline-padding, 1rem); }
        @media not all and (min-width: 40rem) {
          [class~="max-sm:pb-6"]:has(form) { padding-bottom: var(--thread-body-inline-padding, 1rem); }
          [class~="max-sm:[scrollbar-gutter:stable]"] { scrollbar-gutter: auto; }
        }
        [class*="ComposerBannerPortal-"] [class~="text-codex-description"] { display: none; }
        [class*="ComposerBannerPortal-"]:has(> * > [class~="text-codex-description"]):not(:has(> * > :not([class~="text-codex-description"]))) {
          padding-bottom: 0;
        }
        header.draggable { background-color: var(--color-surface); }
        [class~="text-codex-description"][class~="min-h-6"] { display: none; }
        [class*="transcriptContent-"] { padding-bottom: 0; }
        [class*="transcriptContent-"] > [class~="pb-5"] { padding-bottom: 0; }
        [class*="transcriptContent-"] > [class~="pb-5"] > :last-child:empty { margin-top: -0.375rem; }
        .thread-scroll-container {
          max-height: calc(100% - var(--thread-scroll-padding-bottom, 0px));
          scroll-padding-bottom: 0;
        }
        .thread-scroll-container [class*="h-[calc(var(--thread-scroll-padding-bottom)"] { height: 0; }
        """

    /// Liquid Glass (macOS 26 and later; see `QuickChatPanel.setContent`): the page lets the
    /// panel's glass show through instead of painting chatgpt.com's surfaces.
    /// - The page is a 45% tint of the Mac background color over the glass, following the page's
    ///   Light/Dark theme, so text stays readable over a bright window behind the panel. Its body,
    ///   main area and the strip behind the message box (in a chat and on the new-chat page) are
    ///   see-through, and so are the wide layout's (⌘F) page layers and docked sidebar, which
    ///   keeps its own light tint.
    /// - The message box and the top bar's buttons get a see-through white fill: 7% in Dark mode,
    ///   70% in Light mode (chatgpt.com's solid white box looked pasted on). Menus, dialogs and
    ///   the narrow layout's sliding sidebar keep their solid Mac colors.
    /// - With the top bar shown (⌘\), a chat's scroll area starts 16px below its buttons, as it
    ///   ends 16px above the message box, so text doesn't run behind the see-through bar.
    /// chatgpt.com paints the root and body through an attribute selector; `:root` ties with it
    /// and wins as the later sheet.
    private static let glassCSS = """
        :root { background-color: color-mix(in srgb, var(--quick-chat-surface) 45%, transparent); }
        :root body, main[class*="MainContentSurface-"], header.draggable, [class~="max-sm:bg-surface"]:has(form),
        [class~="bottom-0"]:has(form) [class*="background-"][class*="surface-"][class~="bg-surface"],
        [class*="FullHeightPageSurfaceLayout-"], [class*="FullHeightPageSurfaceLayout-"] > ::before,
        .sidebar-navigation:not([class*="ConversationSidebar-"]) {
          background-color: transparent;
        }
        :root, [data-theme] { --quick-chat-glass-fill: light-dark(rgb(255 255 255 / 0.7), rgb(255 255 255 / 0.07)); }
        [class*="ComposerLayoutRoot-"]:is([data-composer-surface-variant="default"], [data-composer-surface-variant="opaque"]) {
          --composer-layout-surface-background: var(--quick-chat-glass-fill);
        }
        header.draggable [class~="bg-surface"], header.draggable [class~="browser:bg-surface"] {
          background-color: var(--quick-chat-glass-fill);
        }
        :root:not([data-quick-chat-hide-top-bar]) main:has(> header.draggable) .thread-scroll-container {
          margin-top: var(--thread-floating-content-top-inset, 60px);
          padding-top: calc(var(--thread-content-top-inset, 84px) - var(--thread-floating-content-top-inset, 60px));
          max-height: calc(100% - var(--thread-scroll-padding-bottom, 0px) - var(--thread-floating-content-top-inset, 60px));
        }
        """

    /// Quick Chat is just chats (see `chatOnlyScript`), so chatgpt.com's sidebar is gone: its
    /// button in the top bar, the sidebar that slides in over the chat (with its dimmed
    /// backdrop), and in the wide layout (⌘F) the side panel with its icon rail. The Chat/Work
    /// switch on the new-chat page goes too. A group of top bar buttons is hidden only if the
    /// sidebar button is all it holds (in a chat, New chat sits beside it).
    private static let chatOnlyCSS = """
        header.draggable .no-drag:has(button[aria-controls="browser-sidebar-popover"]):not(:has(button:not([aria-controls="browser-sidebar-popover"]))),
        #browser-sidebar-popover, .codex-dialog-overlay:has(~ #browser-sidebar-popover),
        aside.app-shell-left-panel, [class~="@container/home-mode-toggle"] {
          display: none;
        }
        """

    /// While `hidesTopBar` is on (the root element has `data-quick-chat-hide-top-bar`), the top
    /// bar is gone: its sidebar button (⇧⌘S does the same), Chat/Work switch, temporary chat
    /// button (⇧⌘N), and in a chat its New chat and More buttons (Share is in More's menu,
    /// `shareInMenuScript`). The content frame's margin that made room for the bar goes too, so
    /// a chat scrolls to the panel's top edge.
    /// Pages without this bar, like the signed-out page with its Log in button, are unaffected.
    private static let hideTopBarCSS = """
        [data-quick-chat-hide-top-bar] main > header.draggable { display: none; }
        [data-quick-chat-hide-top-bar] main:has(> header.draggable) [class*="MainContentFrame-"] {
          --app-shell-main-content-frame-top-offset: 0px;
        }
        """

    /// A temporary chat (`chatOnlyScript` marks the root `data-quick-chat-temporary`) says so in
    /// the empty message box, also while the top bar with chatgpt.com's own Temporary button is
    /// hidden: the placeholder reads "Ask ChatGPT · temporary chat". A saved chat's box stays as
    /// it is.
    private static let temporaryChatCSS = """
        [data-quick-chat-temporary] form .ProseMirror p.placeholder[data-placeholder]::before {
          content: attr(data-placeholder) " · temporary chat";
        }
        """

    /// With the top bar shown, a chat's title (`--quick-chat-title`, set by `chatOnlyScript`)
    /// sits centered between its buttons, cut short with "…" when it doesn't fit, as in a
    /// window's title bar. Pressing it drags the panel, as around it. The bar's slot for page
    /// content takes half the room in a temporary chat though it's empty, so an empty one goes.
    private static let chatTitleCSS = """
        main > header.draggable > [class*="group/titlebar"]::before {
          content: var(--quick-chat-title, none);
          flex: 1 1 0;
          min-width: 0;
          overflow: hidden;
          text-overflow: ellipsis;
          white-space: nowrap;
          text-align: center;
          font-size: 14px;
          font-weight: 600;
        }
        main > header.draggable [data-app-shell-titlebar-content]:empty { display: none; }
        """

    /// A chat's Share button leaves the top bar for its More menu (`shareInMenuScript`). It's
    /// hidden only beside a More button, so it can't vanish altogether. Goes by the buttons'
    /// English labels, as chatgpt.com gives them no other names.
    private static let shareInMenuCSS = """
        main > header.draggable:has(button[aria-label="More"])
          .no-drag:has(> * > button[aria-label="Share"]):not(:has(button:not([aria-label="Share"]))) {
          display: none;
        }
        """

    /// The page's touch-ups, with `glassCSS` where the panel is Liquid Glass.
    private static var pageCSS: String {
        let css = macColorsCSS + pageLayoutCSS + chatOnlyCSS + temporaryChatCSS + chatTitleCSS + shareInMenuCSS + hideTopBarCSS
        if #available(macOS 26, *) { return css + glassCSS }
        return css
    }

    /// Adds `pageCSS` as a constructed style sheet, which survives the page re-rendering its own
    /// DOM. Its rules aren't in a cascade layer, so they beat chatgpt.com's.
    private static let pageStyleScript = """
        if (location.hostname === "chatgpt.com") {
          const sheet = new CSSStyleSheet();
          sheet.replaceSync(\(String(decoding: try! JSONEncoder().encode(pageCSS), as: UTF8.self)));
          document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
        }
        """

    /// Turns `hideTopBarCSS` on or off for the page.
    private static func topBarScript(hidden: Bool) -> String {
        #"if (location.hostname === "chatgpt.com") document.documentElement.toggleAttribute("data-quick-chat-hide-top-bar", \#(hidden));"#
    }

    private static let dragMessage = "quickChatDragPanel"
    private static let openInBrowserMessage = "quickChatOpenInBrowser"

    /// Keeps the panel to chats (`isChatPath`): a link to another chatgpt.com page, or the page
    /// moving there itself (it routes in place with pushState or replaceState, without a page
    /// load the app would see), opens it in the default browser instead, and the panel goes
    /// back; Back/Forward skip such pages. ⇧⌘S (chatgpt.com's sidebar key) does nothing, as the
    /// sidebar is gone (`chatOnlyCSS`). Chats are always Chat, never Work: the Chat/Work switch is
    /// gone too, so its cookie is set to Chat before the page reads it. Marks the root
    /// `data-quick-chat-temporary` in a temporary chat (`temporaryChatCSS`), and puts a chat's
    /// title in `--quick-chat-title` for the top bar (`chatTitleCSS`), in a style sheet of its
    /// own: chatgpt.com names the page after the chat (a temporary one after its first message),
    /// and every other page "ChatGPT".
    private static let chatOnlyScript = """
        if (location.hostname === "chatgpt.com") {
          document.cookie = "codex_composer_mode=chat; path=/; max-age=31536000; secure; samesite=lax";
          const titleSheet = new CSSStyleSheet();
          document.adoptedStyleSheets = [...document.adoptedStyleSheets, titleSheet];
          let shownTitle = "";
          const markTitle = () => {
            const title = location.pathname.startsWith("/c/") ? document.title.trim() : "";
            const shown = title === "ChatGPT" ? "" : title;
            if (shown === shownTitle) return;
            shownTitle = shown;
            titleSheet.replaceSync(shown ? `:root { --quick-chat-title: "${CSS.escape(shown)}"; }` : "");
          };
          addEventListener("DOMContentLoaded", () => {
            markTitle();
            new MutationObserver(markTitle).observe(document.head, {childList: true, subtree: true, characterData: true});
          });
          const markPage = () => {
            document.documentElement.toggleAttribute("data-quick-chat-temporary",
              new URLSearchParams(location.search).get("temporary-chat") === "true");
            markTitle();
          };
          markPage();
          const isChatPath = path => path === "/" || path.startsWith("/c/") || path.startsWith("/auth/");
          const outside = href => {
            const url = new URL(href, location.href);
            return url.hostname === "chatgpt.com" && !isChatPath(url.pathname) ? url : null;
          };
          const openInBrowser = url => webkit.messageHandlers.\(openInBrowserMessage).postMessage(url.href);
          addEventListener("click", event => {
            const link = event.target.closest?.("a[href]");
            const url = link && event.button === 0 && outside(link.href);
            if (!url) return;
            event.preventDefault();
            event.stopImmediatePropagation();
            openInBrowser(url);
          }, true);
          for (const name of ["pushState", "replaceState"]) {
            const move = history[name];
            history[name] = function (state, title, href) {
              const url = href != null && outside(href);
              const [fromState, from] = [history.state, location.href];
              move.apply(this, arguments);
              if (url) {
                openInBrowser(url);
                if (name === "pushState") {
                  history.back();
                } else {
                  move.call(this, fromState, "", from);
                  dispatchEvent(new PopStateEvent("popstate", {state: fromState}));
                }
              }
              markPage();
            };
          }
          addEventListener("popstate", event => {
            if (outside(location.href)) {
              event.stopImmediatePropagation();
              history.back();
            }
            markPage();
          }, true);
          addEventListener("keydown", event => {
            if (event.metaKey && event.shiftKey && !event.altKey && !event.ctrlKey && event.key.toLowerCase() === "s") {
              event.preventDefault();
              event.stopImmediatePropagation();
            }
          }, true);
        }
        """

    /// Puts Share at the top of the top bar's More menu (its button is hidden, `shareInMenuCSS`):
    /// when that menu opens, a copy of its first item gets the Share button's icon and label, and
    /// choosing it closes the menu and clicks the hidden button, which does what it always did
    /// (chatgpt.com at once makes a public link and copies it). The menu's keys don't know the
    /// added item, so ↑ from the first item and Home go to it, and ↓ and End leave it.
    private static let shareInMenuScript = """
        if (location.hostname === "chatgpt.com") {
          const addShare = menu => {
            const trigger = document.getElementById(menu.getAttribute("aria-labelledby"));
            if (!trigger?.matches('main > header.draggable button[aria-label="More"]')) return;
            const share = trigger.closest("header").querySelector('button[aria-label="Share"]');
            const first = menu.querySelector(':scope > [role="menuitem"]');
            if (!share || !first || menu.querySelector(":scope > [data-quick-chat-share]")) return;
            const item = first.cloneNode(true);
            for (const name of ["id", "data-radix-collection-item", "data-highlighted", "aria-haspopup", "aria-expanded", "data-state"]) {
              item.removeAttribute(name);
            }
            item.setAttribute("data-quick-chat-share", "");
            const icon = item.querySelector(".icon-sm");
            const shareIcon = share.querySelector("svg")?.cloneNode(true);
            if (icon && shareIcon) {
              shareIcon.setAttribute("class", "icon-sm shrink-0");
              icon.replaceWith(shareIcon);
            }
            const label = [...item.querySelectorAll("span")].find(span => !span.children.length && span.textContent.trim());
            if (label) label.textContent = share.textContent.trim() || "Share";
            const others = () => [...menu.querySelectorAll(':scope > [role="menuitem"]:not([data-quick-chat-share]):not([data-disabled])')];
            const choose = () => {
              menu.dispatchEvent(new KeyboardEvent("keydown", {key: "Escape", bubbles: true, cancelable: true}));
              setTimeout(() => share.click());
            };
            item.addEventListener("click", event => {
              event.preventDefault();
              event.stopPropagation();
              choose();
            });
            item.addEventListener("pointermove", () => { if (document.activeElement !== item) item.focus(); });
            item.addEventListener("keydown", event => {
              const to = event.key === "Enter" || event.key === " " ? "choose"
                : event.key === "ArrowDown" ? others()[0] : event.key === "End" ? others().at(-1) : null;
              if (!to) return;
              event.preventDefault();
              event.stopPropagation();
              if (to === "choose") choose(); else to.focus();
            });
            menu.addEventListener("keydown", event => {
              if (event.key === "Home" || (event.key === "ArrowUp" && document.activeElement === others()[0])) {
                event.preventDefault();
                event.stopPropagation();
                item.focus();
              }
            }, true);
            first.before(item);
          };
          new MutationObserver(records => {
            for (const record of records) {
              for (const node of record.addedNodes) {
                if (node.nodeType !== Node.ELEMENT_NODE) continue;
                const menu = node.closest('[role="menu"]') ?? node.querySelector('[role="menu"]');
                if (menu) addShare(menu);
              }
            }
          }).observe(document, {childList: true, subtree: true});
        }
        """

    /// Lets chatgpt.com's top bar move the panel, as a title bar would: a press on its empty parts
    /// (around and between its buttons) asks the panel to drag (`QuickChatPanel.dragFromPage`).
    /// The page marks its desktop app's drag areas `.draggable` and their controls `.no-drag`, but
    /// WebKit has no `app-region`. The bar lets the mouse through to the page under it, so this
    /// goes by position: inside a rendered `.draggable` and not on a control.
    private static let dragScript = """
        if (location.hostname === "chatgpt.com") {
          addEventListener("mousedown", event => {
            if (event.button !== 0 || event.shiftKey || event.ctrlKey || event.altKey || event.metaKey) return;
            if (event.target.closest?.('.no-drag, button, a, input, textarea, select, label, [role="button"], [contenteditable="true"]')) return;
            const onBar = [...document.querySelectorAll(".draggable")].some(bar => {
              const r = bar.getBoundingClientRect();
              return event.clientX >= r.left && event.clientX < r.right && event.clientY >= r.top && event.clientY < r.bottom;
            });
            if (!onBar) return;
            event.preventDefault();
            webkit.messageHandlers.\(dragMessage).postMessage(null);
          }, true);
        }
        """

    /// chatgpt.com or a subdomain of it (not e.g. "notchatgpt.com").
    private static func isChatGPTHost(_ host: String) -> Bool {
        let host = host.lowercased()
        return host == "chatgpt.com" || host.hasSuffix(".chatgpt.com")
    }

    /// blob: and data: URLs are page-generated files (exports, images); they're saved, never shown.
    private static func isGeneratedFile(_ url: URL?) -> Bool {
        url?.scheme == "blob" || url?.scheme == "data"
    }

    /// ~/Downloads/<name>, or "<name> 2", "<name> 3", … if that already exists (Finder-style).
    private static func uniqueDownloadURL(suggestedFilename: String) -> URL {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var name = (suggestedFilename as NSString).lastPathComponent
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.hasPrefix(".") { name = "download" + name }
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = downloads.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = "\(base) \(n)" + (ext.isEmpty ? "" : ".\(ext)")
            candidate = downloads.appendingPathComponent(numbered)
            n += 1
        }
        return candidate
    }

    /// Whether a link to `url` opens inside Quick Chat (chatgpt.com's chats and sign-in pages, in
    /// the panel or a popup) rather than in the default browser, or the default app for e.g.
    /// mailto: links. Redirects and scripted navigations aren't links and always stay, as sign-ins
    /// pass through other hosts.
    static func opensInApp(_ url: URL?) -> Bool {
        guard let url, let scheme = url.scheme?.lowercased() else { return true }
        guard scheme == "https" || scheme == "http" else {
            return ["about", "blob", "data", "javascript"].contains(scheme) // page-internal, not for other apps
        }
        let host = url.host?.lowercased() ?? ""
        if host == "chatgpt.com" { return isChatPath(url.path) }
        return signInHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// chatgpt.com's pages that belong in Quick Chat: a new chat (`/`, also temporary), a chat
    /// (`/c/…`) and sign-in (`/auth/…`). GPTs, Library, Codex, projects and the rest open in the
    /// browser (see `chatOnlyScript`). Keep in sync with `chatOnlyScript`'s `isChatPath`.
    static func isChatPath(_ path: String) -> Bool {
        path.isEmpty || path == "/" || path.hasPrefix("/c/") || path.hasPrefix("/auth/")
    }
}

// MARK: - Popup windows

extension QuickChatController: NSWindowDelegate {
    /// A popup closed (by its page or by the user): drop it, which releases its web view.
    func windowWillClose(_ notification: Notification) {
        guard let popup = notification.object as? NSWindow else { return }
        popup.unbind(.title)
        popups.removeAll { $0 === popup }
    }
}

// MARK: - Messages from the page

extension QuickChatController: WKScriptMessageHandler {
    /// `dragScript`: a press on the panel's top bar, away from its buttons. `chatOnlyScript`: a
    /// chatgpt.com page that isn't a chat, for the default browser (nothing else is opened),
    /// from the panel or a popup, which share these scripts.
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let fromPanel = message.webView === webView
        guard fromPanel || popups.contains(where: { $0.contentView === message.webView }) else { return }
        switch message.name {
        case Self.dragMessage:
            if fromPanel { panel?.dragFromPage() }
        case Self.openInBrowserMessage:
            guard let href = message.body as? String, let url = URL(string: href), url.scheme == "https",
                  url.host?.lowercased() == "chatgpt.com", !Self.isChatPath(url.path) else { return }
            NSWorkspace.shared.open(url)
        default:
            break
        }
    }
}

// MARK: - WebKit delegates

extension QuickChatController: WKUIDelegate, WKNavigationDelegate, WKDownloadDelegate {
    /// `window.open` / target=_blank: chatgpt.com and sign-in pages open in a popup window of their
    /// own (see `makePopup`), everything else in the default browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if Self.isGeneratedFile(url) {
            // window.open(blob:/data:) would otherwise replace the chat in the panel.
            webView.startDownload(using: navigationAction.request) { $0.delegate = self }
        } else if Self.opensInApp(url) {
            return makePopup(configuration: configuration, windowFeatures: windowFeatures)
        } else {
            NSWorkspace.shared.open(url)
        }
        return nil
    }

    /// The page called `window.close()` on a popup (e.g. a sign-in popup that has finished).
    func webViewDidClose(_ webView: WKWebView) {
        popups.first { $0.contentView === webView }?.close()
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        let url = navigationAction.request.url
        // <a download>, blob:/data: links: save the file instead of navigating (checked first, as
        // download links often point at file hosts that would otherwise open in the browser).
        if navigationAction.shouldPerformDownload || (navigationAction.targetFrame?.isMainFrame == true && Self.isGeneratedFile(url)) {
            decisionHandler(.download)
            return
        }
        if navigationAction.targetFrame?.isMainFrame == true, navigationAction.navigationType == .linkActivated,
           !Self.opensInApp(url), let url {
            NSWorkspace.shared.open(url)
            decisionHandler(.cancel)
            return
        }
        decisionHandler(.allow)
    }

    /// Responses the web view can't display, or that the server marks as attachments, are saved.
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased()
        let isAttachment = disposition?.hasPrefix("attachment") == true
        decisionHandler(!navigationResponse.canShowMIMEType || isAttachment ? .download : .allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
    }

    /// Popups share the panel's page scripts but not its ⌘\, so they keep chatgpt.com's top bar.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if webView !== self.webView { webView.evaluateJavaScript(Self.topBarScript(hidden: false)) }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        focusComposer()
        if webView === self.webView, let pending = pendingQuestion {
            pendingQuestion = nil
            insertQuestion(pending.text, afterReload: pending.afterReload)
        }
    }

    /// macOS may kill the web content process (often while hidden, under memory pressure), which
    /// leaves the view blank; reload right away so it's ready before the panel is shown again.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log.info("Web content process terminated; reloading")
        if webView.url != nil { webView.reload() } else { webView.load(URLRequest(url: Self.temporaryChatURL)) }
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        guard let window = webView.window else { return completionHandler(nil) } // the panel or a popup
        let open = NSOpenPanel()
        open.allowsMultipleSelection = parameters.allowsMultipleSelection
        open.canChooseDirectories = parameters.allowsDirectories
        open.beginSheetModal(for: window) { response in
            completionHandler(response == .OK ? open.urls : nil)
        }
    }

    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping @MainActor (WKPermissionDecision) -> Void) {
        // Camera and microphone alike: WebKit asks the user (per page load) on chatgpt.com only.
        // macOS's own TCC prompt also appears once per app (NSCamera/NSMicrophoneUsageDescription).
        decisionHandler(origin.protocol == "https" && Self.isChatGPTHost(origin.host) ? .prompt : .deny)
    }

    // MARK: Downloads (WKDownloadDelegate)

    /// Saves straight to ~/Downloads under a unique name (like Safari): no modal sheet on the
    /// floating panel, which may be hidden by the time a slow download asks for a destination.
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                  suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        let destination = Self.uniqueDownloadURL(suggestedFilename: suggestedFilename)
        downloadDestinations[ObjectIdentifier(download)] = destination
        log.info("Downloading to \(destination.path, privacy: .public)")
        completionHandler(destination)
    }

    /// Says so in the panel (now, or when it's shown again) rather than bringing Finder forward;
    /// clicking the message shows the file in Finder.
    func downloadDidFinish(_ download: WKDownload) {
        guard let destination = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        if isVisible { announceDownloads([destination]) } else { unseenDownloads.append(destination) }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        log.error("Download failed: \(error.localizedDescription, privacy: .public)")
        NSSound.beep()
        showToast("Download failed", symbol: "exclamationmark.circle")
    }

    private func announceDownloads(_ files: [URL]) {
        let what = files.count == 1 ? "“\(files[0].lastPathComponent)”" : "\(files.count) files"
        showToast("Saved \(what) to Downloads", symbol: "arrow.down.circle",
                  action: ToastAction(title: "Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(files) })
    }
}

// MARK: - Web view

/// The panel's web view. A first click on an inactive panel normally only activates it; within
/// `firstClickBand` of the top it reaches the page too, so chatgpt.com's top bar drags the panel
/// (`QuickChatController.dragScript`) and its buttons work at once, as a window's title bar and
/// toolbar do.
final class QuickChatWebView: WKWebView {
    /// Height in points from the top edge; 0 while the top bar is hidden.
    var firstClickBand: CGFloat = 0

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        if let event, firstClickBand > 0 {
            let point = convert(event.locationInWindow, from: nil)
            if (isFlipped ? point.y : bounds.maxY - point.y) < firstClickBand { return true }
        }
        return super.acceptsFirstMouse(for: event)
    }

    /// For the find bar (`NSTextFinderClient`): find only, no Replace.
    override var isEditable: Bool { false }
}

// MARK: - Content

/// What the panel holds: chatgpt.com's web view, with AppKit's find bar above it while finding
/// (the web view is the `NSTextFinder`'s client, as in Safari), and short messages
/// (`showToast`) over the top of the page.
final class QuickChatContentView: NSView, @preconcurrency NSTextFinderBarContainer {
    let webView: QuickChatWebView
    let finder = NSTextFinder()
    private var toast: ToastView?
    private var toastTimer: Timer?

    init(webView: QuickChatWebView) {
        self.webView = webView
        super.init(frame: .zero)
        addSubview(webView)
        finder.client = webView
        finder.findBarContainer = self
        finder.isIncrementalSearchingEnabled = true
        finder.incrementalSearchingShouldDimContentView = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    var findBarView: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let findBarView {
                findBarView.isHidden = !findBarShown
                addSubview(findBarView, positioned: .above, relativeTo: webView)
            }
            layoutContent()
        }
    }

    /// `NSTextFinder` hides the bar through the protocol's setFindBarVisible: (which Swift doesn't
    /// map this to by itself), but doesn't show it that way: `find(_:)` does.
    var isFindBarVisible: Bool {
        @objc(isFindBarVisible) get { findBarShown }
        @objc(setFindBarVisible:) set {
            let wasShown = findBarShown
            findBarShown = newValue
            findBarView?.isHidden = !newValue
            layoutContent()
            if wasShown, !newValue { window?.makeFirstResponder(webView) }
        }
    }
    private var findBarShown = false

    func findBarViewDidChangeHeight() { layoutContent() }

    func find(_ action: NSTextFinder.Action) {
        finder.performAction(action)
        if action == .showFindInterface { isFindBarVisible = true }
    }

    /// The find bar's own controls (Return, the arrows) send their action up from the bar.
    override func performTextFinderAction(_ sender: Any?) {
        let tag = (sender as? NSControl)?.tag ?? (sender as? NSMenuItem)?.tag
        if let tag, let action = NSTextFinder.Action(rawValue: tag) { find(action) }
    }

    func contentView() -> NSView? { webView }

    override func resizeSubviews(withOldSize oldSize: NSSize) { layoutContent() }

    /// The find bar (at the height `NSTextFinder` gave it) at the top and the web view below it;
    /// the toast centered near the top.
    private func layoutContent() {
        let barHeight = isFindBarVisible ? findBarView?.frame.height ?? 0 : 0
        if let findBarView {
            findBarView.frame = NSRect(x: 0, y: bounds.height - findBarView.frame.height,
                                       width: bounds.width, height: findBarView.frame.height)
        }
        webView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - barHeight)
        if let toast {
            var size = toast.preferredSize
            size.width = min(size.width, bounds.width - 32)
            toast.frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: bounds.height - barHeight - 12 - size.height,
                                 width: size.width, height: size.height)
        }
    }

    /// Shows `text` (with an SF Symbol) over the top of the page for a moment, replacing any
    /// message still up; with an `action`, longer, ending in its title, and a click on it runs
    /// the action. VoiceOver reads it out.
    func showToast(_ text: String, symbol: String?, action: ToastAction?) {
        toastTimer?.invalidate()
        toast?.removeFromSuperview()
        let toast = ToastView(text: text, symbol: symbol, actionTitle: action?.title)
        if let action { toast.action = { [weak self] in action.run(); self?.hideToast() } }
        addSubview(toast)
        self.toast = toast
        layoutContent()
        let announcement = [text, action?.title].compactMap { $0 }.joined(separator: ". ")
        NSAccessibility.post(element: toast, notification: .announcementRequested,
                             userInfo: [.announcement: announcement, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        toastTimer = Timer.scheduledTimer(withTimeInterval: action == nil ? 1.5 : 5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hideToast() }
        }
    }

    private func hideToast() {
        toastTimer?.invalidate()
        guard let toast else { return }
        self.toast = nil
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return toast.removeFromSuperview() }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; toast.animator().alphaValue = 0 },
                                             completionHandler: { MainActor.assumeIsolated { toast.removeFromSuperview() } })
    }

    var toastText: String? { toast?.text } // for the self-test
}

/// What a click on a toast does, and the words for it at the toast's end ("Show in Finder").
struct ToastAction {
    let title: String
    let run: () -> Void
}

/// A capsule with an icon and a line of text (`QuickChatContentView.showToast`): Liquid Glass
/// on macOS 26 and later, else a blurred material. Clicks go through to the page, unless it
/// has an action. A long text is shortened in its middle; the action's title never is.
private final class ToastView: NSView {
    let text: String
    var action: (() -> Void)? { didSet { window?.invalidateCursorRects(for: self) } }
    private let row: NSStackView
    var preferredSize: NSSize { row.fittingSize }

    init(text: String, symbol: String?, actionTitle: String?) {
        self.text = text
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var views: [NSView] = [label]
        if let actionTitle {
            let title = NSTextField(labelWithString: actionTitle)
            title.font = .systemFont(ofSize: 13, weight: .semibold)
            title.textColor = .controlAccentColor
            title.setContentCompressionResistancePriority(.required, for: .horizontal)
            views.append(title)
        }
        if let symbol, let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) {
            let icon = NSImageView(image: image)
            icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
            icon.contentTintColor = .secondaryLabelColor
            views.insert(icon, at: 0)
        }
        row = NSStackView(views: views)
        super.init(frame: .zero)
        row.spacing = 6
        row.edgeInsets = NSEdgeInsets(top: 7, left: 14, bottom: 7, right: 14)
        let background: NSView
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 15
            glass.contentView = row
            background = glass
        } else {
            let blur = NSVisualEffectView()
            blur.material = .popover
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = 15
            blur.layer?.masksToBounds = true
            row.translatesAutoresizingMaskIntoConstraints = false
            blur.addSubview(row)
            NSLayoutConstraint.activate([
                row.leadingAnchor.constraint(equalTo: blur.leadingAnchor), row.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
                row.topAnchor.constraint(equalTo: blur.topAnchor), row.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
            ])
            background = blur
        }
        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor), background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor), background.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        action != nil && frame.contains(point) ? self : nil
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { action?() }
    override func resetCursorRects() {
        if action != nil { addCursorRect(bounds, cursor: .pointingHand) }
    }
}

// MARK: - Panel

final class QuickChatPanel: NSPanel {
    static let autosaveName = "MiniChat.Panel" // pre-rename name; keeps the saved frame
    /// Default content size (the first open's): a 3:4 portrait panel. Anything under
    /// 640 wide gets chatgpt.com's compact (mobile) layout; 420 sits between Classic's 440-wide
    /// companion chat and `minSize` (400), so the thread reads as a narrow column without the
    /// squat look of the new app's 470-wide window cut down to 560 tall.
    static let defaultSize = NSSize(width: 420, height: 560)
    var onCancel: (() -> Void)?
    /// ⌘− / ⌘= (or ⌘+) / ⌘0: zoom the page out (-1), in (+1), or back to the default (0).
    var onZoom: ((Int) -> Void)?
    /// ⌘[ / ⌘]: thinking effort one level down (-1) or up (+1).
    var onEffort: ((Int) -> Void)?
    /// ⌘N / ⇧⌘N: new chat; `true` for a temporary one (⌘N).
    var onNewChat: ((Bool) -> Void)?
    /// ⌘\: show or hide chatgpt.com's top bar.
    var onToggleTopBar: (() -> Void)?
    /// ⇧⌘F / ⌘G / ⇧⌘G: show the find bar, find the next / previous match.
    var onFind: ((NSTextFinder.Action) -> Void)?
    /// ⇧⌘B: open the chat in the default browser.
    var onOpenInBrowser: (() -> Void)?
    /// Local key combo that calls `resetPosition()` while the panel is key (default ⌘O).
    var resetSizeShortcut: Shortcut? = .commandO
    /// Local key combo that calls `toggleMaximize()` while the panel is key (default ⌘F).
    var maximizeShortcut: Shortcut? = .commandF

    /// The user's frame from before maximizing; non-nil while maximized. Hiding and showing
    /// keep the panel maximized; a relaunch doesn't, as the maximized frame is never autosaved.
    private var restoreFrame: NSRect?
    var isMaximized: Bool { restoreFrame != nil }
    /// Set while the panel changes its own frame, so only user moves/resizes end the maximize.
    private var isSettingFrame = false
    /// The last left mouse-down in the panel, for `dragFromPage()`.
    private var lastMouseDown: NSEvent?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "ChatGPT"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // No full screen or tiling: ⌘F's maximize is the panel's only zoom.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .fullScreenNone, .fullScreenDisallowsTiling]
        // No traffic lights either, so the title bar is invisible and chatgpt.com fills the
        // panel to its top edge (clicks there reach the page).
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        minSize = NSSize(width: 400, height: 400)
        backgroundColor = .windowBackgroundColor
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(frameDidChange),
                                                   name: name, object: self)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Puts the web view (in its `content`) in the panel. On macOS 26 and later, it sits on a
    /// Liquid Glass sheet and draws no background of its own, so the page's see-through parts
    /// (`glassCSS`) show the glass.
    func setContent(_ content: QuickChatContentView) {
        guard #available(macOS 26, *) else { contentView = content; return }
        backgroundColor = .clear
        isOpaque = false
        content.webView.setValue(false, forKey: "drawsBackground") // no public API for a see-through web view
        content.webView.underPageBackgroundColor = .clear
        let glass = NSGlassEffectView()
        glass.contentView = content
        contentView = glass
    }

    /// AppKit's own zoom, if anything still triggers it, toggles maximize instead.
    override func zoom(_ sender: Any?) { toggleMaximize() }

    /// Esc (when the page doesn't handle it) hides the panel.
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    /// Fills the screen's visible frame (menu bar and Dock stay visible), or goes back to the
    /// user's frame from before. The panel stays resizable while maximized.
    func toggleMaximize() {
        if let restoreFrame {
            setOwnFrame(restoreFrame)
            endMaximize()
        } else {
            guard let visible = (screen ?? NSScreen.main)?.visibleFrame else { return }
            restoreFrame = frame
            setFrameAutosaveName("") // keep the user's frame as the one restored on relaunch
            setOwnFrame(visible)
        }
    }

    /// Gap between the panel and the bottom of the screen's visible area (the Dock, if it's there).
    static let bottomMargin: CGFloat = 16

    /// `size` (by default `defaultSize`) at the bottom center of `screen`'s visible area: where the panel first
    /// opens, and, at the panel's own size, where `resetPosition()` puts it back. Kept within
    /// the visible area.
    func bottomCenterFrame(on screen: NSScreen, size: NSSize? = nil) -> NSRect {
        let visible = screen.visibleFrame
        var size = size ?? frameRect(forContentRect: NSRect(origin: .zero, size: Self.defaultSize)).size
        size.width = min(size.width, visible.width)
        size.height = min(size.height, visible.height - Self.bottomMargin)
        return NSRect(x: visible.midX - size.width / 2, y: visible.minY + Self.bottomMargin,
                      width: size.width, height: size.height)
    }

    /// Back to the bottom center of the panel's screen, keeping its size; from maximized, the
    /// size it had before. The frame autosave then persists it.
    func resetPosition() {
        guard let screen = screen ?? NSScreen.main else { return }
        setOwnFrame(bottomCenterFrame(on: screen, size: (restoreFrame ?? frame).size))
        if isMaximized { endMaximize() }
    }

    /// Animated frame change that doesn't count as the user moving or resizing the panel.
    private func setOwnFrame(_ frame: NSRect) {
        isSettingFrame = true
        defer { isSettingFrame = false }
        setFrame(frame, display: true, animate: true)
    }

    /// Leaves the maximized state as is (frame-wise) and resumes autosaving the current frame.
    private func endMaximize() {
        restoreFrame = nil
        setFrameAutosaveName(Self.autosaveName)
        saveFrame(usingName: Self.autosaveName)
    }

    /// The user moved or resized the maximized panel: that frame becomes their own.
    @objc private func frameDidChange() {
        if isMaximized, !isSettingFrame { endMaximize() }
    }

    /// Runs the Reset Position or Maximize action if `event` is its shortcut.
    private func handleLocalShortcut(_ event: NSEvent) -> Bool {
        guard let pressed = Shortcut(event: event) else { return false }
        if pressed == resetSizeShortcut {
            resetPosition()
        } else if pressed == maximizeShortcut {
            toggleMaximize()
        } else {
            return false
        }
        return true
    }

    /// Catches the panel's local shortcuts before the web view sees them. Done here rather
    /// than in `performKeyEquivalent` so combos without ⌘ (e.g. ⌥R, F5) work too.
    /// Besides chatgpt.com's top bar (`dragFromPage`), ⌃⌘-drag anywhere moves the panel (the
    /// gesture macOS's NSWindowShouldDragOnGesture setting uses). Notes the last mouse-down for
    /// `dragFromPage`.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleLocalShortcut(event) { return }
        if event.type == .leftMouseDown { lastMouseDown = event }
        if event.type == .leftMouseDown,
           event.modifierFlags.intersection([.shift, .control, .option, .command]) == [.control, .command] {
            performDrag(with: event)
            return
        }
        super.sendEvent(event)
    }

    /// Moves the panel with the mouse, as from a title bar, after the page reported a press on
    /// its top bar (`QuickChatController.dragScript`). The report comes in after the mouse-down,
    /// so this drags from the last one, and only while the button is still held.
    func dragFromPage() {
        guard let event = lastMouseDown, NSEvent.pressedMouseButtons & 1 != 0 else { return }
        performDrag(with: event)
    }

    override func close() { onCancel?() }

    /// ⌘W hides, ⌘N / ⇧⌘N start a temporary / saved chat, ⌘− / ⌘= / ⌘0 zoom, ⌘[ / ⌘] change the
    /// thinking effort, ⌘\ shows or hides the top bar, ⇧⌘F / ⌘G / ⇧⌘G find and ⇧⌘B opens the
    /// chat in the browser; the local shortcuts are caught here too, ahead of the web view
    /// (which otherwise claims ⌘ combos). `Shortcut.reservedUse` lists these.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleLocalShortcut(event) { return true }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            onCancel?()
            return true
        }
        let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
        if event.charactersIgnoringModifiers?.lowercased() == "n", flags == .command || flags == [.command, .shift] {
            onNewChat?(!flags.contains(.shift))
            return true
        }
        if flags == .command, event.charactersIgnoringModifiers == "\\" {
            onToggleTopBar?()
            return true
        }
        switch (event.charactersIgnoringModifiers?.lowercased(), flags) {
        case ("f", [.command, .shift]): onFind?(.showFindInterface); return true
        case ("g", .command): onFind?(.nextMatch); return true
        case ("g", [.command, .shift]): onFind?(.previousMatch); return true
        case ("b", [.command, .shift]): onOpenInBrowser?(); return true
        default: break
        }
        // Matched by character, Shift allowed, so layouts with a shifted = or + work too.
        if event.modifierFlags.intersection([.control, .option, .command]) == .command {
            let key = event.charactersIgnoringModifiers ?? ""
            if let step = ["-": -1, "=": 1, "+": 1, "0": 0][key] {
                onZoom?(step)
                return true
            }
            if let step = ["[": -1, "]": 1][key] {
                onEffort?(step)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
