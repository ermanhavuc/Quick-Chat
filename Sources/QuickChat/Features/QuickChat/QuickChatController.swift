import AppKit
import WebKit

/// Floating Quick Chat in the spirit of ChatGPT Classic's companion chat: chatgpt.com in a
/// web view, which uses its compact layout at this width.
@MainActor
final class QuickChatController: NSObject {
    /// A new chat, saved in your chat history: what the panel starts on, and what ⌘N and Ask
    /// About Selection open.
    private static let chatURL = URL(string: "https://chatgpt.com/")!
    /// A new temporary chat (not saved in your chat history), for ⇧⌘N.
    static let temporaryChatPath = "/?temporary-chat=true"
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

    /// Moves the panel back to the bottom center of its screen, keeping its size (no-op if it
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

    /// chatgpt.com's top bar height (its --height-toolbar), in CSS pixels.
    static let topBarHeight: CGFloat = 52

    /// A first click on the top bar's band reaches the page (see `QuickChatWebView`).
    private func updateFirstClickBand() {
        webView?.firstClickBand = Self.topBarHeight * pageZoom
    }

    /// ⌘N / ⇧⌘N: a new saved chat, or a new temporary one (chatgpt.com's `?temporary-chat=true`).
    /// Both are Chat, never Work (`chatOnlyScript`).
    func newChat(temporary: Bool) {
        let path = temporary ? Self.temporaryChatPath : "/"
        webView?.callAsyncJavaScript(PageScripts.newChatScript, arguments: ["path": path],
                                     in: nil, in: .page) { [weak self] result in
            guard case .failure(let error) = result, let self else { return }
            self.log.error("New chat: \(error.localizedDescription, privacy: .public)")
            self.webView?.load(URLRequest(url: URL(string: path, relativeTo: Self.chatURL)!))
        }
    }

    /// Text for `ask(about:)` that waits for the page to finish loading; `afterReload` once the
    /// page was reloaded for it.
    private var pendingQuestion: (text: String, afterReload: Bool)?

    /// Shows the panel with a new chat that has `text` in its message box (after
    /// anything already typed there), ready for a question about it.
    func ask(about text: String) {
        show()
        guard let webView else { return }
        if webView.isLoading { pendingQuestion = (text, false) } else { insertQuestion(text, afterReload: false) }
    }

    private func insertQuestion(_ text: String, afterReload: Bool) {
        webView?.callAsyncJavaScript(PageScripts.askScript, arguments: ["text": text, "path": "/"],
                                     in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value as String) where value == "reload" && !afterReload:
                // A chat with messages at the new chat's own address: only a reload leaves it.
                self.pendingQuestion = (text, true)
                self.webView?.load(URLRequest(url: Self.chatURL))
            case .success(let value as String) where value == "reload":
                self.log.error("Ask about selection: still in a chat after reloading")
                self.askFailed(text)
            case .success:
                break
            case .failure(let error):
                let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String
                self.log.error("Ask about selection: \(message ?? error.localizedDescription, privacy: .public)")
                self.askFailed(text)
            }
        }
    }

    /// The text couldn't go in a new chat (signed out, say, or chatgpt.com changed): says so and
    /// offers to copy it, so it isn't lost.
    private func askFailed(_ text: String) {
        NSSound.beep()
        showToast("Couldn't put the text in a new chat", symbol: "exclamationmark.bubble",
                  action: ToastAction(title: "Copy Text") {
                      NSPasteboard.general.clearContents()
                      NSPasteboard.general.setString(text, forType: .string)
                  })
    }

    /// Set while `stepEffort` runs, so a held ⌘] can't open and close the picker over itself.
    private var isSteppingEffort = false

    /// Moves chatgpt.com's thinking effort (Instant, Medium, High…) one level down (`step` < 0)
    /// or up (> 0) and shows the new level. Beeps when there's no effort control or it's already
    /// at that end.
    func stepEffort(_ step: Int) {
        guard let webView, !isSteppingEffort else { return }
        isSteppingEffort = true
        webView.callAsyncJavaScript(PageScripts.stepEffortScript, arguments: ["step": step],
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

    /// Hides the panel when you're in it, giving focus back to the previous app; otherwise shows
    /// it, also when it's open but another app has focus (it stays up over other apps).
    func toggle() {
        if let panel, panel.isVisible, panel.isKeyWindow, NSApp.isActive {
            hide(restoreFocus: true)
        } else {
            show()
        }
    }

    /// A click on the menu-bar icon: hides the panel if it's up (it's in sight, over other apps),
    /// otherwise shows it. Unlike the shortcut, a click on the icon doesn't let Quick Chat become
    /// the active app by just asking (macOS keeps the app you're in), so once the panel is up it
    /// asks harder; without that, typing would still go to the other app.
    func toggleFromMenuBar() {
        if let panel, panel.isVisible {
            hide(restoreFocus: panel.isKeyWindow && NSApp.isActive)
        } else {
            show()
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    /// Shows the panel and focuses its message box, on the display you're working on (the one
    /// with the mouse): it moves there from another display, keeping its place on the screen.
    func show() {
        let panel = self.panel ?? makePanel()
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        if let screen = Self.screenWithMouse { panel.move(to: screen) }
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
        // The page didn't load while it was hidden (no network at login, say): try again now.
        if content?.isShowingError == true { retry() }
    }

    /// Builds the panel and starts loading chatgpt.com without showing it, so the panel opens on
    /// a page that's ready. Like a panel that has been shown, it then keeps its page.
    func preload() {
        if panel == nil { _ = makePanel() }
    }

    private static var screenWithMouse: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
    }

    /// `restoreFocus`: give focus back to the app that was frontmost before showing.
    func hide(restoreFocus: Bool) {
        guard let panel, panel.isVisible else { return }
        Self.cancelSheet(on: panel)
        panel.orderOut(nil)
        if restoreFocus { previousApp?.activate() }
        watchAnswer()
    }

    /// Closes the panel and releases the web view (the sign-in session stays in the data store).
    func tearDown() {
        for popup in popups {
            Self.cancelSheet(on: popup)
            popup.close()
        }
        if let panel { Self.cancelSheet(on: panel) }
        panel?.orderOut(nil)
        webView?.stopLoading()
        content?.finder.client = nil
        panel?.contentView = nil
        panel = nil
        webView = nil
        content = nil
        revealTimer?.invalidate()
        revealTimer = nil
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
        webView?.evaluateJavaScript(PageScripts.answeringScript) { [weak self] answering, _ in
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
        webView.evaluateJavaScript(PageScripts.answeringScript) { [weak self] answering, _ in
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
        panel.onFind = { [weak self] in self?.find($0) }
        panel.onOpenInBrowser = { [weak self] in self?.openChatInBrowser() }
        panel.onReload = { [weak self] in self?.reload() }
        panel.resetSizeShortcut = resetSizeShortcut

        let webView = makeWebView()
        let content = QuickChatContentView(webView: webView)
        panel.setContent(content)
        self.content = content
        coverUntilReady()

        if !panel.setFrameUsingName(QuickChatPanel.autosaveName) {
            // First open: the bottom center of the screen with the mouse.
            if let screen = Self.screenWithMouse {
                panel.setFrame(panel.bottomCenterFrame(on: screen), display: false)
            }
        }
        panel.setFrameAutosaveName(QuickChatPanel.autosaveName)

        self.panel = panel
        self.webView = webView
        webView.load(URLRequest(url: Self.chatURL))
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
        config.userContentController.add(self, name: PageScripts.dragMessage)
        config.userContentController.add(self, name: PageScripts.openInBrowserMessage)
        config.userContentController.add(self, name: PageScripts.readyMessage)
        let webView = QuickChatWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.safariUserAgent
        webView.pageZoom = pageZoom
        webView.firstClickBand = Self.topBarHeight * pageZoom
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.underPageBackgroundColor = .windowBackgroundColor
        return webView
    }

    private func addUserScripts(to controller: WKUserContentController) {
        for source in PageScripts.userScripts {
            controller.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
    }

    private func focusComposer() {
        webView?.evaluateJavaScript(PageScripts.focusComposerScript)
    }

    // MARK: Loading

    private var revealTimer: Timer?

    /// Shows the spinner instead of a page that's loading (chatgpt.com builds its page in steps
    /// that move things around) until it's ready (`reveal`), and at most 10 s.
    private func coverUntilReady() {
        content?.setLoading(true)
        revealTimer?.invalidate()
        revealTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Usually chatgpt.com's markup changed, so `readyScript` no longer sees its page built.
                self.log.notice("Page not ready after 10 s, shown anyway: \(self.webView?.url?.host ?? "no page", privacy: .public)")
                self.reveal()
            }
        }
    }

    private func reveal() {
        revealTimer?.invalidate()
        revealTimer = nil
        content?.setLoading(false)
    }

    /// ⌘R: loads the page again, or chatgpt.com if nothing has loaded yet.
    func reload() {
        guard let webView else { return }
        if webView.backForwardList.currentItem == nil {
            webView.load(URLRequest(url: Self.chatURL))
        } else {
            webView.reload()
        }
    }

    /// Try Again: the spinner, and the page loads again.
    private func retry() {
        coverUntilReady()
        reload()
    }

    /// The panel's page didn't load. In place of a page that isn't there yet (still covered, or
    /// never loaded), an error with Try Again; over one that's showing, which stays (⌘R while
    /// offline, say), a short message. A load that another one replaced, or that turned into a
    /// download, didn't fail.
    private func loadFailed(_ error: Error) {
        let error = error as NSError
        let replaced = error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
        // WebKitErrorFrameLoadInterruptedByPolicyChange, WebKitErrorPlugInWillHandleLoad.
        let handedOff = error.domain == "WebKitErrorDomain" && [102, 204].contains(error.code)
        guard !replaced, !handedOff else { return reveal() }
        log.error("Load failed: \(error.localizedDescription, privacy: .public) (\(error.domain, privacy: .public) \(error.code))")
        revealTimer?.invalidate()
        revealTimer = nil
        if content?.isLoading == true || webView?.backForwardList.currentItem == nil {
            content?.showError(error.localizedDescription) { [weak self] in self?.retry() }
            // Text waiting for this page: offered to copy now, and still added once Try Again works.
            if let pending = pendingQuestion { askFailed(pending.text) }
        } else {
            NSSound.beep()
            showToast("Couldn't load: \(error.localizedDescription)", symbol: "wifi.exclamationmark")
            // Text waiting for this page goes in the page that stayed.
            if let pending = pendingQuestion {
                pendingQuestion = nil
                insertQuestion(pending.text, afterReload: pending.afterReload)
            }
        }
    }

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
    /// from the panel or a popup, which share these scripts. `readyScript`: the panel's page is
    /// built.
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        let fromPanel = message.webView === webView
        guard fromPanel || popups.contains(where: { $0.contentView === message.webView }) else { return }
        switch message.name {
        case PageScripts.dragMessage:
            if fromPanel { panel?.dragFromPage() }
        case PageScripts.readyMessage:
            if fromPanel { reveal() }
        case PageScripts.openInBrowserMessage:
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

    /// A new page in the panel: hidden until it's built (`coverUntilReady`).
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if webView === self.webView { coverUntilReady() }
    }

    /// The panel's page is loaded: one that isn't chatgpt.com (signing in) shows now;
    /// chatgpt.com's when its page is built (`readyScript`).
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === self.webView, webView.url?.host?.lowercased() != "chatgpt.com" { reveal() }
        focusComposer()
        if webView === self.webView, let pending = pendingQuestion {
            pendingQuestion = nil
            insertQuestion(pending.text, afterReload: pending.afterReload)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView { loadFailed(error) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if webView === self.webView { loadFailed(error) }
    }

    /// macOS may kill the web content process (often while hidden, under memory pressure), which
    /// leaves the view blank; reload right away so it's ready before the panel is shown again.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log.info("Web content process terminated; reloading")
        if webView.url != nil { webView.reload() } else { webView.load(URLRequest(url: Self.chatURL)) }
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

    // MARK: alert(), confirm(), prompt()

    /// The page's `alert()`, as a sheet on its window.
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        guard let (alert, window) = pageDialog(message, from: frame, in: webView) else { return completionHandler() }
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { _ in completionHandler() }
    }

    /// The page's `confirm()`: true for OK.
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        guard let (alert, window) = pageDialog(message, from: frame, in: webView) else { return completionHandler(false) }
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    /// The page's `prompt()`: the text typed, or nil for Cancel.
    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        guard let (alert, window) = pageDialog(prompt, from: frame, in: webView) else { return completionHandler(nil) }
        let field = NSTextField(string: defaultText ?? "")
        field.frame.size.width = 280
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil) }
    }

    /// Ends the sheet a page put on `window` (a dialog or the file chooser) as Cancel, which
    /// answers the page: WebKit raises an exception if a dialog's web view goes away unanswered,
    /// and the page waits for its answer while the panel is hidden.
    private static func cancelSheet(on window: NSWindow) {
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
    }

    /// An alert saying which site shows `message`, for a sheet on `webView`'s window. Nil (the
    /// dialog is dismissed at once, as WebKit does without a delegate) while that window is
    /// hidden or already shows a sheet, so a page can't stack them up.
    private func pageDialog(_ message: String, from frame: WKFrameInfo, in webView: WKWebView) -> (NSAlert, NSWindow)? {
        guard let window = webView.window, window.isVisible, window.attachedSheet == nil else { return nil }
        let alert = NSAlert()
        let host = frame.securityOrigin.host
        alert.messageText = host.isEmpty ? "This page says:" : "\(host) says:"
        alert.informativeText = String(message.prefix(1000))
        return (alert, window)
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
