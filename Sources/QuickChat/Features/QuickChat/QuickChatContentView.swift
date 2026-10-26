import AppKit

// MARK: - Content

/// What the panel holds: chatgpt.com's web view, with AppKit's find bar above it while finding
/// (the web view is the `NSTextFinder`'s client, as in Safari), and short messages
/// (`showToast`) over the top of the page.
final class QuickChatContentView: NSView, @preconcurrency NSTextFinderBarContainer {
    let webView: QuickChatWebView
    let finder = NSTextFinder()
    private var toast: ToastView?
    private var toastTimer: Timer?
    /// The spinner or the error (`setCover`).
    private var cover: NSView?

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

    /// While the page loads, it's invisible (it still loads and lays out as usual) and a spinner
    /// sits in its place; then the spinner goes and the page fades in.
    var isLoading: Bool { cover is LoadingView }

    /// Whether an error (`showError`) stands in for a page that didn't load.
    var isShowingError: Bool { cover is ErrorView }

    func setLoading(_ loading: Bool) {
        if loading {
            if !isLoading { setCover(LoadingView()) }
        } else if isLoading {
            setCover(nil)
        }
    }

    /// In place of a page that didn't load: why, and Try Again, which runs `retry`.
    func showError(_ message: String, retry: @escaping () -> Void) {
        setCover(ErrorView(message: message, retry: retry))
    }

    /// The spinner or the error, over the page, which is invisible meanwhile; without one, the
    /// page fades in.
    private func setCover(_ view: NSView?) {
        let hadCover = cover != nil
        cover?.removeFromSuperview()
        cover = view
        if let view {
            addSubview(view, positioned: .above, relativeTo: webView)
            webView.alphaValue = 0
            layoutContent()
        } else if hadCover {
            if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return webView.alphaValue = 1 }
            NSAnimationContext.runAnimationGroup { $0.duration = 0.25; webView.animator().alphaValue = 1 }
        }
    }

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
        cover?.frame = webView.frame
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

/// The spinner `QuickChatContentView.setLoading` shows in place of a loading page. A press on
/// it moves the panel, rather than reaching buttons on the hidden page.
private final class LoadingView: NSView {
    private let spinner = NSProgressIndicator()

    init() {
        super.init(frame: .zero)
        spinner.style = .spinning
        spinner.isIndeterminate = true
        spinner.setAccessibilityLabel("Loading ChatGPT")
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor), spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        spinner.startAnimation(nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { frame.contains(point) ? self : nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
}

/// What `QuickChatContentView.showError` shows in place of a page that didn't load: what went
/// wrong and Try Again. A press around them moves the panel, as on the spinner.
private final class ErrorView: NSView {
    private let retry: () -> Void

    init(message: String, retry: @escaping () -> Void) {
        self.retry = retry
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: "wifi.exclamationmark", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 28, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        let title = NSTextField(labelWithString: "Couldn't load ChatGPT")
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        let detail = NSTextField(wrappingLabelWithString: message)
        detail.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.preferredMaxLayoutWidth = 280
        let button = NSButton(title: "Try Again", target: self, action: #selector(tryAgain))
        button.bezelStyle = .push
        let stack = NSStackView(views: [icon, title, detail, button])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.setCustomSpacing(16, after: detail)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor), stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func tryAgain() { retry() }

    /// The button gets its clicks; the rest of the view takes them, so they don't reach the page.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSButton ? hit : self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
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
