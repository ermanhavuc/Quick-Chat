#if DEBUG
import AppKit
import WebKit

/// Self-test of the Quick Chat panel's layout (opens a real panel, so it needs a GUI session):
///   QUICKCHAT_SELFTEST=panel .build/debug/QuickChat
@MainActor
enum PanelSelfTest {
    private static var failures = 0

    private static func check(_ cond: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if cond { print("  ok   \(name)") } else { failures += 1; print("  FAIL \(name) \(detail())") }
    }

    static func run() -> Bool {
        // Start from the default zoom; put the saved one back afterwards.
        let defaults = UserDefaults.standard, zoomKey = QuickChatController.pageZoomDefaultsKey
        let savedZoom = defaults.object(forKey: zoomKey)
        defaults.removeObject(forKey: zoomKey)
        defer { defaults.set(savedZoom, forKey: zoomKey) }

        let chat = QuickChatController()
        chat.show()
        defer { chat.tearDown() }
        func webView(in view: NSView) -> WKWebView? {
            view as? WKWebView ?? view.subviews.lazy.compactMap(webView(in:)).first
        }
        guard let panel = NSApp.windows.lazy.compactMap({ $0 as? QuickChatPanel }).first,
              let frameView = panel.contentView?.superview, let webView = webView(in: frameView) else {
            print("panel self-test: FAILED (no panel with a web view)")
            return false
        }

        print("1. no title strip")
        for (name, button) in [("close", NSWindow.ButtonType.closeButton), ("minimize", .miniaturizeButton),
                               ("zoom", .zoomButton)] {
            check(panel.standardWindowButton(button)?.isHidden != false, "\(name) button hidden")
        }
        let webFrame = webView.convert(webView.bounds, to: frameView)
        check(webFrame == frameView.bounds, "web view fills the panel", "\(webFrame) vs \(frameView.bounds)")

        print("2. clicks at the top of the panel reach the page")
        for y in [4.0, 14, 24, 40] {
            let point = NSPoint(x: 40, y: frameView.bounds.maxY - y)
            let hit = frameView.hitTest(point)
            check(hit?.isDescendant(of: webView) == true, "\(Int(y)) pt from the top hits the web view",
                  hit.map { "\(type(of: $0))" } ?? "nil")
        }

        print("3. ⌘− / ⌘= / ⌘0 zoom the page, remembered")
        func press(_ key: String, _ flags: NSEvent.ModifierFlags = .command) -> Bool {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                         windowNumber: panel.windowNumber, context: nil, characters: key,
                                         charactersIgnoringModifiers: key, isARepeat: false, keyCode: 0)!
            return panel.performKeyEquivalent(with: event)
        }
        func zoomIs(_ expected: CGFloat, _ name: String) {
            let page = Double(webView.pageZoom)
            let saved = defaults.object(forKey: zoomKey) as? Double ?? page // nothing saved yet: the default
            check(abs(page - expected) < 0.001 && abs(saved - expected) < 0.001, name, "page \(page), saved \(saved)")
        }
        zoomIs(QuickChatController.defaultPageZoom, "starts at the default (90%)")
        check(press("-"), "⌘− handled")
        zoomIs(0.8, "⌘− → 80%")
        _ = press("=")
        zoomIs(0.9, "⌘= → 90%")
        _ = press("+", [.command, .shift])
        zoomIs(1, "⇧⌘= (⌘+) → 100%")
        _ = press("0")
        zoomIs(0.9, "⌘0 → back to 90%")
        for _ in 0..<10 { _ = press("-") }
        zoomIs(0.5, "stops at 50%")
        _ = press("0", [])
        _ = press("0", [.command, .option])
        zoomIs(0.5, "plain 0 and ⌥⌘0 don't zoom")

        print("4. ⌘[ / ⌘] step the thinking effort")
        var steps: [Int] = []
        panel.onEffort = { steps.append($0) } // the page needs a signed-in session; check the routing only
        check(press("[") && press("]"), "⌘[ and ⌘] handled")
        _ = press("[", [])
        _ = press("]", [.command, .control])
        check(steps == [-1, 1], "⌘[ → down, ⌘] → up; plain [ and ⌃⌘] ignored", "\(steps)")

        print("5. ⌘N / ⇧⌘N start a new (temporary) chat")
        var newChats: [Bool] = []
        panel.onNewChat = { newChats.append($0) }
        check(press("n") && press("N", [.command, .shift]), "⌘N and ⇧⌘N handled")
        _ = press("n", [])
        _ = press("n", [.command, .option])
        check(newChats == [false, true], "⌘N → new chat, ⇧⌘N → temporary; plain n and ⌥⌘N ignored", "\(newChats)")

        print("6. links open in the default browser, except chatgpt.com and sign-in pages")
        let inApp = ["https://chatgpt.com/c/123", "https://chatgpt.com/auth/login_with?connection=google-oauth2",
                     "https://help.chatgpt.com/x", "https://auth.openai.com/log-in", "https://accounts.google.com/o/oauth2",
                     "https://appleid.apple.com/auth/authorize", "https://login.microsoftonline.com/common",
                     "about:blank", "blob:https://chatgpt.com/abc"]
        let inBrowser = ["https://openai.com/terms", "https://help.openai.com/en/articles/1", "https://www.google.com/search?q=x",
                         "https://support.apple.com/kb", "https://learn.microsoft.com/x", "https://notchatgpt.com/",
                         "https://example.com/", "http://example.com/", "mailto:someone@example.com"]
        for link in inApp { check(QuickChatController.opensInApp(URL(string: link)), "in app: \(link)") }
        for link in inBrowser { check(!QuickChatController.opensInApp(URL(string: link)), "browser: \(link)") }

        print(failures == 0 ? "panel self-test: ALL PASSED" : "panel self-test: \(failures) FAILED")
        return failures == 0
    }
}
#endif
