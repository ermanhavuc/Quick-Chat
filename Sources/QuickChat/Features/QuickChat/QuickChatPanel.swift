import AppKit
import WebKit

// MARK: - Web view

/// The panel's web view. A first click on an inactive panel normally only activates it; within
/// `firstClickBand` of the top it reaches the page too, so chatgpt.com's top bar drags the panel
/// (`QuickChatController.dragScript`) and its buttons work at once, as a window's title bar and
/// toolbar do.
final class QuickChatWebView: WKWebView {
    /// Height in points from the top edge: the top bar's.
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
    /// ⌘N / ⇧⌘N: new chat; `true` for a temporary one (⇧⌘N).
    var onNewChat: ((Bool) -> Void)?
    /// ⇧⌘F / ⌘G / ⇧⌘G: show the find bar, find the next / previous match.
    var onFind: ((NSTextFinder.Action) -> Void)?
    /// ⇧⌘B: open the chat in the default browser.
    var onOpenInBrowser: (() -> Void)?
    /// ⌘R: load the page again.
    var onReload: (() -> Void)?
    /// Local key combo that calls `resetPosition()` while the panel is key (default ⌘O).
    var resetSizeShortcut: Shortcut? = .commandO
    /// The last left mouse-down in the panel, for `dragFromPage()`.
    private var lastMouseDown: NSEvent?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
                   backing: .buffered, defer: false)
        title = "ChatGPT"
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        // No full screen or tiling.
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

    /// No zoom to fill the screen, whatever asks for it (a double-click where the title bar
    /// would be, the Window menu): the panel keeps the size you give it.
    override func zoom(_ sender: Any?) {}

    /// Esc (when the page doesn't handle it) hides the panel.
    override func cancelOperation(_ sender: Any?) { onCancel?() }

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

    /// Back to the bottom center of the panel's screen, keeping its size. The frame autosave
    /// then persists it.
    func resetPosition() {
        guard let screen = screen ?? NSScreen.main else { return }
        setFrame(bottomCenterFrame(on: screen, size: frame.size), display: true, animate: true)
    }

    /// Moves the panel to `screen` (if it's on another one), keeping its size and its place:
    /// centered stays centered, and otherwise it keeps its distance from the nearer edge, on each
    /// axis, within the screen's visible area.
    func move(to screen: NSScreen) {
        guard let current = self.screen, current.frame != screen.frame else { return }
        let target = Self.frame(frame, movedFrom: current.visibleFrame, to: screen.visibleFrame)
        setFrame(target, display: false)
    }

    /// `frame`'s place in `from`, carried over to `to` (see `move(to:)`); shrunk to fit.
    static func frame(_ frame: NSRect, movedFrom from: NSRect, to: NSRect) -> NSRect {
        func place(_ origin: CGFloat, _ length: CGFloat, _ fromMin: CGFloat, _ fromLength: CGFloat,
                   _ toMin: CGFloat, _ toLength: CGFloat) -> (CGFloat, CGFloat) {
            let size = min(length, toLength)
            let before = origin - fromMin, after = fromMin + fromLength - (origin + length)
            let offCenter = origin + length / 2 - (fromMin + fromLength / 2)
            let placed = abs(offCenter) <= min(before, after) ? toMin + toLength / 2 + offCenter - size / 2
                : before <= after ? toMin + before
                : toMin + toLength - after - size
            return (min(max(placed, toMin), toMin + toLength - size), size)
        }
        let (x, width) = place(frame.minX, frame.width, from.minX, from.width, to.minX, to.width)
        let (y, height) = place(frame.minY, frame.height, from.minY, from.height, to.minY, to.height)
        return NSRect(x: x, y: y, width: width, height: height)
    }

    /// Runs Reset Position if `event` is its shortcut.
    private func handleLocalShortcut(_ event: NSEvent) -> Bool {
        guard let pressed = Shortcut(event: event), pressed == resetSizeShortcut else { return false }
        resetPosition()
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

    /// ⌘W hides, ⌘N / ⇧⌘N start a saved / temporary chat, ⌘− / ⌘= / ⌘0 zoom, ⌘[ / ⌘] change the
    /// thinking effort, ⇧⌘F / ⌘G / ⇧⌘G find, ⇧⌘B opens the chat in the browser and ⌘R
    /// reloads; the local shortcuts are caught here too, ahead of the web view
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
            onNewChat?(flags.contains(.shift))
            return true
        }
        switch (event.charactersIgnoringModifiers?.lowercased(), flags) {
        case ("f", [.command, .shift]): onFind?(.showFindInterface); return true
        case ("g", .command): onFind?(.nextMatch); return true
        case ("g", [.command, .shift]): onFind?(.previousMatch); return true
        case ("b", [.command, .shift]): onOpenInBrowser?(); return true
        case ("r", .command): onReload?(); return true
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
