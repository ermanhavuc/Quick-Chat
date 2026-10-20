import AppKit
import WebKit

/// Floating Quick Chat in the spirit of ChatGPT Classic's companion chat: chatgpt.com in a
/// web view, which uses its compact layout at this width.
@MainActor
final class QuickChatController: NSObject {
    private static let chatURL = URL(string: "https://chatgpt.com/")!
    /// Hosts that stay inside the panel (chat + sign-in flows); other links open in the browser.
    private static let inPanelHosts = ["chatgpt.com", "openai.com", "auth0.com", "google.com", "apple.com",
                                       "microsoftonline.com", "live.com", "microsoft.com"]
    private static let safariUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15"

    private let log = Log.make("QuickChat")
    private var panel: QuickChatPanel?
    private var webView: WKWebView?
    /// Open popup windows (see `makePopup`); each one leaves this list when it closes.
    private var popups: [NSWindow] = []
    private var previousApp: NSRunningApplication?
    /// Where each in-flight download is being written, for "reveal in Finder" when it finishes.
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]

    var isVisible: Bool { panel?.isVisible == true }

    /// Local shortcut (only while the panel is key) that triggers `resetSize()`.
    var resetSizeShortcut = Shortcut.loadResetSize() {
        didSet { panel?.resetSizeShortcut = resetSizeShortcut }
    }

    /// Local shortcut (only while the panel is key) that toggles maximize.
    var maximizeShortcut = Shortcut.loadMaximize() {
        didSet { panel?.maximizeShortcut = maximizeShortcut }
    }

    /// Resizes the panel back to `QuickChatPanel.defaultSize` (no-op if it was never built).
    func resetSize() { panel?.resetSize() }

    static let pageZoomDefaultsKey = "quickChat.pageZoom"
    /// Below 100% so text is smaller than chatgpt.com's own; ⌘0 comes back here.
    static let defaultPageZoom: CGFloat = 0.9
    /// The ⌘− / ⌘= steps (Chrome's zoom levels).
    private static let pageZoomLevels: [CGFloat] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]

    /// chatgpt.com's zoom in the panel, remembered across launches.
    private var pageZoom = UserDefaults.standard.object(forKey: pageZoomDefaultsKey) as? CGFloat ?? defaultPageZoom {
        didSet {
            webView?.pageZoom = pageZoom
            UserDefaults.standard.set(Double(pageZoom), forKey: Self.pageZoomDefaultsKey)
        }
    }

    /// Zooms one level out (`step` < 0) or in (> 0), or back to the default (0).
    func zoom(_ step: Int) {
        if step == 0 { pageZoom = Self.defaultPageZoom; return }
        let next = step > 0 ? Self.pageZoomLevels.first { $0 > pageZoom + 0.001 }
                            : Self.pageZoomLevels.last { $0 < pageZoom - 0.001 }
        if let next { pageZoom = next } else { NSSound.beep() }
    }

    /// ⌘N / ⇧⌘N: a new chat, or a new temporary chat (chatgpt.com's `?temporary-chat=true`).
    /// Like chatgpt.com's own New chat, it stays in the current Chat or Work mode; a temporary
    /// chat is always Chat.
    func newChat(temporary: Bool) {
        let path = temporary ? "/?temporary-chat=true" : "/"
        webView?.callAsyncJavaScript(Self.newChatScript, arguments: ["path": path],
                                     in: nil, in: .page) { [weak self] result in
            guard case .failure(let error) = result, let self else { return }
            self.log.error("New chat: \(error.localizedDescription, privacy: .public)")
            self.webView?.load(URLRequest(url: URL(string: path, relativeTo: Self.chatURL)!))
        }
    }

    /// Goes to `path` through chatgpt.com's own router (pushState plus the popstate event that
    /// Back/Forward fire), which is quicker than reloading the app. Reloads when already there,
    /// so the chat still starts fresh, and loads chatgpt.com when on another site (sign-in).
    private static let newChatScript = """
        if (location.host !== "chatgpt.com") { location.href = "https://chatgpt.com" + path; return; }
        if (location.pathname + location.search === path) { location.reload(); return; }
        history.pushState(null, "", path);
        dispatchEvent(new PopStateEvent("popstate", {state: null}));
        await new Promise(r => setTimeout(r, 300));
        \(focusComposerScript)
        """

    /// Set while `stepEffort` runs, so a held ⌘] can't open and close the picker over itself.
    private var isSteppingEffort = false

    /// Moves chatgpt.com's thinking effort (Instant, Medium, High…) one level down (`step` < 0)
    /// or up (> 0). Beeps when there's no effort control or it's already at that end.
    func stepEffort(_ step: Int) {
        guard let webView, !isSteppingEffort else { return }
        isSteppingEffort = true
        webView.callAsyncJavaScript(Self.stepEffortScript, arguments: ["step": step],
                                    in: nil, in: .page) { [weak self] result in
            guard let self else { return }
            self.isSteppingEffort = false
            switch result {
            case .success(let level as String):
                self.log.info("Thinking effort: \(level, privacy: .public)")
            case .success:
                NSSound.beep()
            case .failure(let error):
                self.log.error("Thinking effort: \(error.localizedDescription, privacy: .public)")
                NSSound.beep()
            }
        }
    }

    /// The effort slider sits in the composer's model picker menu ("Power"; Left/Right arrow keys
    /// adjust it, as the menu item's aria-keyshortcuts says). Opens the menu if needed, steps the
    /// slider, closes the menu again and puts focus back in the composer. Returns the new level
    /// ("High, 3 of 5."), or null if it didn't change. Depends on chatgpt.com's markup.
    private static let stepEffortScript = """
        const sleep = ms => new Promise(r => setTimeout(r, ms));
        const findSlider = () => document.querySelector('[role="menu"] [role="menuitem"][aria-keyshortcuts~="ArrowRight"]');
        const level = slider => slider.closest('[role="menu"]').querySelector('[role="status"]')?.textContent;
        const press = (el, key) => el.dispatchEvent(new KeyboardEvent("keydown", {key, code: key, bubbles: true, cancelable: true}));
        let slider = findSlider();
        const opened = !slider;
        if (opened) {
          const trigger = document.querySelector('form button[aria-label="Select ChatGPT model"]')
            ?? [...document.querySelectorAll('form button[aria-haspopup="menu"]')].pop();
          if (!trigger) throw new Error("no model picker in the composer");
          // Radix menus open on pointerdown, not click.
          trigger.dispatchEvent(new PointerEvent("pointerdown", {bubbles: true, cancelable: true, button: 0, pointerType: "mouse", isPrimary: true}));
          for (let i = 0; i < 20 && !(slider = findSlider()); i++) await sleep(25);
          if (!slider) {
            const menu = document.querySelector('[role="menu"]');
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
        return after !== before ? after : null;
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
    }

    /// `restoreFocus`: give focus back to the app that was frontmost before showing.
    func hide(restoreFocus: Bool) {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        if restoreFocus { previousApp?.activate() }
    }

    /// Closes the panel and releases the web view (the sign-in session stays in the data store).
    func tearDown() {
        for popup in popups { popup.close() }
        panel?.orderOut(nil)
        webView?.stopLoading()
        panel?.contentView = nil
        panel = nil
        webView = nil
    }

    /// Signs out by clearing the panel's website data (cookies, storage).
    func signOut() {
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
        panel.resetSizeShortcut = resetSizeShortcut
        panel.maximizeShortcut = maximizeShortcut

        let webView = makeWebView()
        panel.contentView = webView

        if !panel.setFrameUsingName(QuickChatPanel.autosaveName) {
            center(panel)
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

    private func center(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: visible.midX - size.width / 2,
                                     y: visible.minY + (visible.height - size.height) * 0.6))
    }

    private func makeWebView() -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = []
        config.userContentController.addUserScript(WKUserScript(source: Self.pageStyleScript,
                                                                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.safariUserAgent
        webView.pageZoom = pageZoom
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.underPageBackgroundColor = .windowBackgroundColor
        return webView
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
    ///   of list gap, 20px and 32px of padding, and the 24px "ChatGPT can make mistakes" line.
    ///   That line is hidden and the padding cut to leave 16px, as at the box's sides.
    /// If chatgpt.com renames these hooks, the rules stop matching and the page looks as before.
    private static let pageLayoutCSS = """
        body, body [data-theme] { --thread-composer-bottom-inset: var(--thread-body-inline-padding, 1rem); }
        @media not all and (min-width: 40rem) {
          [class~="max-sm:pb-6"]:has(form) { padding-bottom: var(--thread-body-inline-padding, 1rem); }
        }
        [class*="ComposerBannerPortal-"] [class~="text-codex-description"] { display: none; }
        [class*="ComposerBannerPortal-"]:has(> * > [class~="text-codex-description"]):not(:has(> * > :not([class~="text-codex-description"]))) {
          padding-bottom: 0;
        }
        header.draggable { background-color: var(--color-surface); }
        [class~="text-codex-description"][class~="min-h-6"] { display: none; }
        [class*="transcriptContent-"] { padding-bottom: 0; }
        [class*="transcriptContent-"] > [class~="pb-5"] { padding-bottom: 10px; }
        """

    /// Adds `macColorsCSS` and `pageLayoutCSS` as a constructed style sheet, which survives the
    /// page re-rendering its own DOM. Its rules aren't in a cascade layer, so they beat chatgpt.com's.
    private static let pageStyleScript = """
        if (location.hostname === "chatgpt.com") {
          const sheet = new CSSStyleSheet();
          sheet.replaceSync(\(String(decoding: try! JSONEncoder().encode(macColorsCSS + pageLayoutCSS), as: UTF8.self)));
          document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
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

    private static func staysInPanel(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return true } // about:blank, data:, etc.
        return inPanelHosts.contains { host == $0 || host.hasSuffix("." + $0) }
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

// MARK: - WebKit delegates

extension QuickChatController: WKUIDelegate, WKNavigationDelegate, WKDownloadDelegate {
    /// `window.open` / target=_blank: sign-in pages open in a popup window of their own (see
    /// `makePopup`), everything else goes to the browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if Self.isGeneratedFile(url) {
            // window.open(blob:/data:) would otherwise replace the chat in the panel.
            webView.startDownload(using: navigationAction.request) { $0.delegate = self }
        } else if Self.staysInPanel(url) {
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
           !Self.staysInPanel(url), let url {
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

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        focusComposer()
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

    func downloadDidFinish(_ download: WKDownload) {
        guard let destination = downloadDestinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        downloadDestinations.removeValue(forKey: ObjectIdentifier(download))
        log.error("Download failed: \(error.localizedDescription, privacy: .public)")
        NSSound.beep()
    }
}

// MARK: - Panel

final class QuickChatPanel: NSPanel {
    static let autosaveName = "MiniChat.Panel" // pre-rename name; keeps the saved frame
    /// Default content size (also the "reset size" target): a 3:4 portrait panel. Anything under
    /// 640 wide gets chatgpt.com's compact (mobile) layout; 420 sits between Classic's 440-wide
    /// companion chat and `minSize` (400), so the thread reads as a narrow column without the
    /// squat look of the new app's 470-wide window cut down to 560 tall.
    static let defaultSize = NSSize(width: 420, height: 560)
    var onCancel: (() -> Void)?
    /// ⌘− / ⌘= (or ⌘+) / ⌘0: zoom the page out (-1), in (+1), or back to the default (0).
    var onZoom: ((Int) -> Void)?
    /// ⌘[ / ⌘]: thinking effort one level down (-1) or up (+1).
    var onEffort: ((Int) -> Void)?
    /// ⌘N / ⇧⌘N: new chat; `true` for a temporary one.
    var onNewChat: ((Bool) -> Void)?
    /// Local key combo that calls `resetSize()` while the panel is key (default ⌘O).
    var resetSizeShortcut: Shortcut? = .commandO
    /// Local key combo that calls `toggleMaximize()` while the panel is key (default ⌘F).
    var maximizeShortcut: Shortcut? = .commandF

    /// The user's frame from before maximizing; non-nil while maximized. Hiding and showing
    /// keep the panel maximized; a relaunch doesn't, as the maximized frame is never autosaved.
    private var restoreFrame: NSRect?
    var isMaximized: Bool { restoreFrame != nil }
    /// Set while the panel changes its own frame, so only user moves/resizes end the maximize.
    private var isSettingFrame = false

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

    /// Resizes to `defaultSize`, keeping the top-left corner put (the pre-maximize one if
    /// maximized) but staying on the visible part of the screen. The frame autosave then
    /// persists the new size.
    func resetSize() {
        let anchor = restoreFrame ?? frame
        let size = frameRect(forContentRect: NSRect(origin: .zero, size: Self.defaultSize)).size
        var frame = NSRect(x: anchor.minX, y: anchor.maxY - size.height,
                           width: size.width, height: size.height)
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        setOwnFrame(frame)
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

    /// Runs the Reset Window Size or Maximize action if `event` is its shortcut.
    private func handleLocalShortcut(_ event: NSEvent) -> Bool {
        guard let pressed = Shortcut(event: event) else { return false }
        if pressed == resetSizeShortcut {
            resetSize()
        } else if pressed == maximizeShortcut {
            toggleMaximize()
        } else {
            return false
        }
        return true
    }

    /// Catches the panel's local shortcuts before the web view sees them. Done here rather
    /// than in `performKeyEquivalent` so combos without ⌘ (e.g. ⌥R, F5) work too.
    /// With no title bar to drag, ⌃⌘-drag anywhere moves the panel (the gesture macOS's
    /// NSWindowShouldDragOnGesture setting uses).
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, handleLocalShortcut(event) { return }
        if event.type == .leftMouseDown,
           event.modifierFlags.intersection([.shift, .control, .option, .command]) == [.control, .command] {
            performDrag(with: event)
            return
        }
        super.sendEvent(event)
    }

    override func close() { onCancel?() }

    /// ⌘W hides, ⌘N / ⇧⌘N start a (temporary) chat, ⌘− / ⌘= / ⌘0 zoom and ⌘[ / ⌘] change the
    /// thinking effort; the local shortcuts are caught here too, ahead of the web view (which
    /// otherwise claims ⌘ combos).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if handleLocalShortcut(event) { return true }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            onCancel?()
            return true
        }
        if event.charactersIgnoringModifiers?.lowercased() == "n" {
            let flags = event.modifierFlags.intersection([.shift, .control, .option, .command])
            if flags == .command || flags == [.command, .shift] {
                onNewChat?(flags.contains(.shift))
                return true
            }
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
