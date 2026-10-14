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
    private var previousApp: NSRunningApplication?
    /// Where each in-flight download is being written, for "reveal in Finder" when it finishes.
    private var downloadDestinations: [ObjectIdentifier: URL] = [:]

    var isVisible: Bool { panel?.isVisible == true }

    /// Local shortcut (only while the panel is key) that triggers `resetSize()`.
    var resetSizeShortcut = Shortcut.loadResetSize() {
        didSet { panel?.resetSizeShortcut = resetSizeShortcut }
    }

    /// Resizes the panel back to `QuickChatPanel.defaultSize` (no-op if it was never built).
    func resetSize() { panel?.resetSize() }

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
        panel.resetSizeShortcut = resetSizeShortcut

        let header = DraggableView() // drag strip under the transparent title bar
        let webView = makeWebView()
        let stack = NSStackView(views: [header, webView])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets()
        header.heightAnchor.constraint(equalToConstant: 28).isActive = true
        panel.contentView = stack

        if !panel.setFrameUsingName(QuickChatPanel.autosaveName) {
            center(panel)
        }
        panel.setFrameAutosaveName(QuickChatPanel.autosaveName)

        self.panel = panel
        self.webView = webView
        webView.load(URLRequest(url: Self.chatURL))
        return panel
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
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.customUserAgent = Self.safariUserAgent
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.underPageBackgroundColor = .windowBackgroundColor
        return webView
    }

    private func focusComposer() {
        // Best effort: chatgpt.com's composer is a contenteditable #prompt-textarea.
        webView?.evaluateJavaScript("document.querySelector('#prompt-textarea')?.focus()")
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

    private static func staysInPanel(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return true } // about:blank, data:, etc.
        return inPanelHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

// MARK: - WebKit delegates

extension QuickChatController: WKUIDelegate, WKNavigationDelegate, WKDownloadDelegate {
    /// `window.open` / target=_blank: sign-in pages stay in the panel, everything else goes to the browser.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let url = navigationAction.request.url else { return nil }
        if Self.isGeneratedFile(url) {
            // window.open(blob:/data:) would otherwise replace the chat in the panel.
            webView.startDownload(using: navigationAction.request) { $0.delegate = self }
        } else if Self.staysInPanel(url) {
            webView.load(navigationAction.request)
        } else {
            NSWorkspace.shared.open(url)
        }
        return nil
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
        guard let panel else { return completionHandler(nil) }
        let open = NSOpenPanel()
        open.allowsMultipleSelection = parameters.allowsMultipleSelection
        open.canChooseDirectories = parameters.allowsDirectories
        open.beginSheetModal(for: panel) { response in
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
    /// Local key combo that calls `resetSize()` while the panel is key (default ⌘O).
    var resetSizeShortcut: Shortcut? = .commandO {
        didSet { updateZoomTooltip() }
    }

    /// System traffic-light buttons shown in the title bar's top-left cluster (the rest stay
    /// hidden). Red close goes through `close()` below, so it hides rather than destroys; green
    /// zoom is rerouted to `resetSize()` (see `configureZoomButton()`).
    static let trafficLights: [NSWindow.ButtonType] = [.closeButton, .zoomButton]

    /// Where the green button sits when minimize is hidden: minimize's slot, so there's no gap.
    private var zoomButtonOrigin: NSPoint?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "ChatGPT"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // No full screen or tiling: the green button shows the plain zoom glyph and only resets size.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .fullScreenNone, .fullScreenDisallowsTiling]
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = !Self.trafficLights.contains(button)
        }
        configureZoomButton()
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovableByWindowBackground = false
        minSize = NSSize(width: 400, height: 400)
        backgroundColor = .windowBackgroundColor
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// Points the green button at `resetSize()` and, if minimize is hidden, slides it into
    /// minimize's slot next to close. AppKit re-lays out the title bar buttons (resize, key
    /// changes), so the button's frame changes are watched and the slot re-applied.
    private func configureZoomButton() {
        guard let zoom = standardWindowButton(.zoomButton), !zoom.isHidden else { return }
        zoom.target = self
        zoom.action = #selector(resetSizeButtonClicked(_:))
        updateZoomTooltip()

        guard !Self.trafficLights.contains(.miniaturizeButton),
              let mini = standardWindowButton(.miniaturizeButton) else { return }
        zoomButtonOrigin = mini.frame.origin
        pinZoomButton()
        zoom.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(pinZoomButton),
                                               name: NSView.frameDidChangeNotification, object: zoom)
    }

    /// Deferred a turn: moving the button synchronously inside AppKit's title bar layout pass
    /// gets overwritten by the rest of that pass.
    @objc private func pinZoomButton() {
        DispatchQueue.main.async { [weak self] in
            guard let self, let zoomButtonOrigin = self.zoomButtonOrigin,
                  let zoom = self.standardWindowButton(.zoomButton),
                  zoom.frame.origin != zoomButtonOrigin else { return }
            zoom.setFrameOrigin(zoomButtonOrigin)
        }
    }

    private func updateZoomTooltip() {
        var tip = "Reset Window Size"
        if let resetSizeShortcut { tip += " (\(resetSizeShortcut.displayString))" }
        standardWindowButton(.zoomButton)?.toolTip = tip
    }

    @objc private func resetSizeButtonClicked(_ sender: Any?) { resetSize() }

    /// Title bar double-click / Window ▸ Zoom also reset rather than maximize.
    override func zoom(_ sender: Any?) { resetSize() }

    /// Esc (when the page doesn't handle it) hides the panel.
    override func cancelOperation(_ sender: Any?) { onCancel?() }

    /// Resizes to `defaultSize`, keeping the top-left corner put but staying on the visible
    /// part of the screen. The frame autosave then persists the new size.
    func resetSize() {
        let size = frameRect(forContentRect: NSRect(origin: .zero, size: Self.defaultSize)).size
        var frame = NSRect(x: self.frame.minX, y: self.frame.maxY - size.height,
                           width: size.width, height: size.height)
        if let visible = (screen ?? NSScreen.main)?.visibleFrame {
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        setFrame(frame, display: true, animate: true)
    }

    /// Catches the Reset Window Size shortcut before the web view sees it. Done here rather
    /// than in `performKeyEquivalent` so combos without ⌘ (e.g. ⌥R, F5) work too.
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, let resetSizeShortcut, Shortcut(event: event) == resetSizeShortcut {
            resetSize()
            return
        }
        super.sendEvent(event)
    }

    override func close() { onCancel?() }

    /// ⌘W hides; the Reset Window Size shortcut is caught here too, ahead of the web view
    /// (which otherwise claims ⌘ combos).
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let resetSizeShortcut, Shortcut(event: event) == resetSizeShortcut {
            resetSize()
            return true
        }
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           event.charactersIgnoringModifiers == "w" {
            onCancel?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Header strip that drags the window.
private final class DraggableView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}
