#if DEBUG
import AppKit
import Carbon.HIToolbox
import WebKit

/// Self-test of the Quick Chat panel's layout (opens a real panel, so it needs a GUI session):
///   QUICKCHAT_SELFTEST=panel .build/debug/QuickChat
@MainActor
enum PanelSelfTest {
    private static var failures = 0
    /// `QuickChatController.unseenAnswerDidChange` posts seen by section 16.
    private static var unseenPosts = 0

    private static func check(_ cond: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if cond { print("  ok   \(name)") } else { failures += 1; print("  FAIL \(name) \(detail())") }
    }

    /// Runs the main run loop until `done` or `seconds` pass.
    private static func spin(until done: () -> Bool, seconds: TimeInterval) {
        let deadline = Date(timeIntervalSinceNow: seconds)
        while !done(), Date() < deadline { RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05)) }
    }

    static func run() -> Bool {
        // Start from the default zoom and top bar and no saved panel frame; put the saved ones
        // back afterwards.
        let defaults = UserDefaults.standard, zoomKey = QuickChatController.pageZoomDefaultsKey
        let frameKey = "NSWindow Frame \(QuickChatPanel.autosaveName)", topBarKey = QuickChatController.hidesTopBarDefaultsKey
        let saved = [zoomKey, frameKey, topBarKey].map { ($0, defaults.object(forKey: $0)) }
        for (key, _) in saved { defaults.removeObject(forKey: key) }
        defer { for (key, value) in saved { defaults.set(value, forKey: key) } }

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
        func press(_ key: String, _ flags: NSEvent.ModifierFlags = .command, keyCode: UInt16 = 0) -> Bool {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                         windowNumber: panel.windowNumber, context: nil, characters: key,
                                         charactersIgnoringModifiers: key, isARepeat: false, keyCode: keyCode)!
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

        print("5. starts on a temporary chat; ⌘N / ⇧⌘N start a new temporary / saved chat")
        let start = webView.url?.absoluteString ?? "none"
        check(start == "https://chatgpt.com/?temporary-chat=true", "first page: a new temporary chat", start)
        var newChats: [Bool] = []
        panel.onNewChat = { newChats.append($0) }
        check(press("n") && press("N", [.command, .shift]), "⌘N and ⇧⌘N handled")
        _ = press("n", [])
        _ = press("n", [.command, .option])
        check(newChats == [true, false], "⌘N → temporary, ⇧⌘N → saved; plain n and ⌥⌘N ignored", "\(newChats)")

        print("6. opens at the bottom center of the screen; ⌘O goes back there")
        func atBottomCenter(_ name: String) {
            guard let visible = panel.screen?.visibleFrame else { return check(false, name, "no screen") }
            let f = panel.frame
            check(abs(f.midX - visible.midX) < 1 && abs(f.minY - (visible.minY + QuickChatPanel.bottomMargin)) < 1
                  && f.size == QuickChatPanel.defaultSize, name, "\(f) in \(visible)")
        }
        atBottomCenter("first open: 420×560, centered, 16 pt above the Dock")
        panel.setFrame(NSRect(x: 100, y: 300, width: 600, height: 700), display: false)
        check(press("o", keyCode: 31), "⌘O handled") // kVK_ANSI_O
        atBottomCenter("⌘O after moving and resizing")
        panel.toggleMaximize()
        _ = press("o", keyCode: 31)
        atBottomCenter("⌘O while maximized")
        check(!panel.isMaximized, "… and no longer maximized")

        print("7. links open in the default browser, except chatgpt.com's chats and sign-in pages")
        let inApp = ["https://chatgpt.com/c/123", "https://chatgpt.com/", "https://chatgpt.com/?temporary-chat=true",
                     "https://chatgpt.com", "https://chatgpt.com/auth/login_with?connection=google-oauth2",
                     "https://auth.openai.com/log-in", "https://accounts.google.com/o/oauth2",
                     "https://appleid.apple.com/auth/authorize", "https://login.microsoftonline.com/common",
                     "about:blank", "blob:https://chatgpt.com/abc"]
        let inBrowser = ["https://chatgpt.com/gpts", "https://chatgpt.com/library", "https://chatgpt.com/codex",
                         "https://chatgpt.com/g/g-abc/c/123", "https://help.chatgpt.com/x",
                         "https://openai.com/terms", "https://help.openai.com/en/articles/1", "https://www.google.com/search?q=x",
                         "https://support.apple.com/kb", "https://learn.microsoft.com/x", "https://notchatgpt.com/",
                         "https://example.com/", "http://example.com/", "mailto:someone@example.com"]
        for link in inApp { check(QuickChatController.opensInApp(URL(string: link)), "in app: \(link)") }
        for link in inBrowser { check(!QuickChatController.opensInApp(URL(string: link)), "browser: \(link)") }

        print("8. ⌘\\ shows or hides chatgpt.com's top bar, remembered")
        func topBar(hidden: Bool, _ name: String) {
            let scripts = webView.configuration.userContentController.userScripts.map(\.source)
            let flag = scripts.first { $0.contains("toggleAttribute(\"data-quick-chat-hide-top-bar\"") }
            let saved = defaults.object(forKey: topBarKey) as? Bool ?? true // nothing saved yet: the default
            check(chat.hidesTopBar == hidden && saved == hidden && scripts.count == 4
                  && flag?.hasSuffix(", \(hidden));") == true, name, "\(scripts.count) scripts, flag: \(flag ?? "none")")
        }
        topBar(hidden: true, "hidden by default")
        check(press("\\"), "⌘\\ handled")
        topBar(hidden: false, "⌘\\ → shown (next page loads too)")
        func firstClick(_ fromTop: CGFloat) -> Bool {
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 80, y: frameView.bounds.maxY - fromTop),
                                           modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                           eventNumber: 0, clickCount: 1, pressure: 1)!
            return webView.acceptsFirstMouse(for: event)
        }
        let band = 52 * webView.pageZoom
        check((webView as? QuickChatWebView)?.firstClickBand == band && firstClick(4) && firstClick(band - 2),
              "a first click on the shown top bar reaches the page (it drags the panel)", "band \((webView as? QuickChatWebView)?.firstClickBand ?? -1)")
        _ = press("\\")
        topBar(hidden: true, "⌘\\ again → hidden")
        check((webView as? QuickChatWebView)?.firstClickBand == 0, "… and first clicks there only activate the panel again")
        _ = press("\\", [])
        _ = press("\\", [.command, .option])
        topBar(hidden: true, "plain \\ and ⌥⌘\\ ignored")

        print("9. Ask About Selection puts the clipboard back as it was")
        let board = NSPasteboard(name: .init("QuickChat.SelfTest"))
        defer { board.releaseGlobally() }
        let custom = NSPasteboard.PasteboardType("dev.shuaibird.quickchat.test")
        let first = NSPasteboardItem(), second = NSPasteboardItem()
        first.setString("<b>rich</b>", forType: .html)
        first.setString("rich", forType: .string)
        second.setData(Data([0, 1, 2, 255]), forType: custom)
        board.clearContents()
        board.writeObjects([first, second])
        let snapshot = PasteboardSnapshot(board)
        board.clearContents()
        board.setString("the selection", forType: .string) // what ⌘C put there
        snapshot.restore(to: board)
        let items = board.pasteboardItems ?? []
        check(items.count == 2 && items[0].types == [.html, .string] && items[0].string(forType: .html) == "<b>rich</b>"
              && items[0].string(forType: .string) == "rich" && items[1].data(forType: custom) == Data([0, 1, 2, 255]),
              "both items, every type in order, same data", "\(items.map(\.types))")
        board.clearContents()
        let empty = PasteboardSnapshot(board)
        board.setString("the selection", forType: .string)
        empty.restore(to: board)
        check(board.pasteboardItems?.isEmpty != false, "an empty clipboard stays empty", "\(board.pasteboardItems?.map(\.types) ?? [])")

        print("10. Liquid Glass behind a see-through page (macOS 26 and later)")
        let pageStyle = webView.configuration.userContentController.userScripts.first?.source ?? ""
        if #available(macOS 26, *) {
            let glass = panel.contentView as? NSGlassEffectView
            check((glass?.contentView as? QuickChatContentView)?.webView === webView, "the web view sits on a glass view",
                  "\(panel.contentView.map { "\(type(of: $0))" } ?? "nil")")
            check(!panel.isOpaque && panel.backgroundColor == .clear, "the panel is see-through")
            check(webView.value(forKey: "drawsBackground") as? Bool == false, "the web view draws no background")
            check(pageStyle.contains("--quick-chat-glass-fill"), "the page style has the glass rules")
        } else {
            check((panel.contentView as? QuickChatContentView)?.webView === webView && panel.isOpaque, "a solid panel")
            check(!pageStyle.contains("--quick-chat-glass-fill"), "no glass rules in the page style")
        }

        guard let content = webView.superview as? QuickChatContentView else {
            print("panel self-test: FAILED (the web view isn't in a QuickChatContentView)")
            return false
        }
        func evaluate(_ js: String) -> Any? {
            var result: Any?, done = false
            webView.evaluateJavaScript(js) { value, _ in result = value; done = true }
            spin(until: { done }, seconds: 3)
            return result
        }

        print("11. zoom and thinking effort say what they did")
        _ = press("0")
        _ = press("=")
        check(content.toastText == "Zoom 100%", "⌘= → \"Zoom 100%\"", content.toastText ?? "no toast")
        for _ in 0..<10 { _ = press("=") }
        check(content.toastText == "Zoom 200%, the largest", "at 200%, ⌘= says it's the largest", content.toastText ?? "no toast")
        _ = press("0")
        check(content.toastText == "Zoom 90%", "⌘0 → \"Zoom 90%\"", content.toastText ?? "no toast")

        print("12. ⇧⌘F finds in the chat, in AppKit's find bar above the page")
        var findActions: [NSTextFinder.Action] = []
        let find = panel.onFind
        panel.onFind = { findActions.append($0) }
        check(press("F", [.command, .shift]) && press("g") && press("G", [.command, .shift]) && press("B", [.command, .shift]),
              "⇧⌘F, ⌘G, ⇧⌘G and ⇧⌘B handled")
        _ = press("f", [.command, .option])
        check(findActions == [.showFindInterface, .nextMatch, .previousMatch], "⇧⌘F → find bar, ⌘G → next, ⇧⌘G → previous; ⌥⌘F ignored",
              "\(findActions.map(\.rawValue))")
        panel.onFind = find
        _ = press("F", [.command, .shift])
        let bar = content.findBarView?.frame ?? .zero
        check(content.isFindBarVisible && bar.height > 0 && bar.maxY == content.bounds.maxY && webView.frame.maxY == bar.minY,
              "the find bar shows at the top, the page below it", "bar \(bar), page \(webView.frame)")
        content.find(.hideFindInterface)
        check(!content.isFindBarVisible && webView.frame == content.bounds, "hiding it gives the page its room back", "\(webView.frame)")

        print("13. ⇧⌘B opens a saved chat in the browser, not a temporary or new one")
        let savedChat = URL(string: "https://chatgpt.com/c/6ad6156c-7574")!
        for (link, expected) in [("https://chatgpt.com/c/6ad6156c-7574", savedChat), ("https://chatgpt.com/c/6ad6156c-7574?model=x#end", savedChat),
                                 ("https://chatgpt.com/c/6ad6156c-7574?temporary-chat=true", nil),
                                 ("https://chatgpt.com/c/local-chatgpt%3A35823b96", nil), ("https://chatgpt.com/", nil),
                                 ("https://chatgpt.com/?temporary-chat=true", nil), ("https://chatgpt.com/library", nil),
                                 ("https://example.com/c/1", nil), ("http://chatgpt.com/c/1", nil)] as [(String, URL?)] {
            let url = QuickChatController.browserURL(for: URL(string: link)!)
            check(url == expected, "\(link) → \(expected?.absoluteString ?? "nothing")", url?.absoluteString ?? "nothing")
        }

        print("14. no shortcut can take the panel's or chatgpt.com's keys")
        for (combo, carbon, key) in [("⌘V", cmdKey, kVK_ANSI_V), ("⌘K", cmdKey, kVK_ANSI_K), ("⇧⌘F", cmdKey | shiftKey, kVK_ANSI_F),
                                     ("⌘W", cmdKey, kVK_ANSI_W), ("⌘↩", cmdKey, kVK_Return)] {
            check(Shortcut.reservedUse(of: Shortcut(keyCode: UInt32(key), carbonModifiers: UInt32(carbon))) != nil, "\(combo) is taken")
        }
        let dvorakPaste = Shortcut(keyCode: UInt32(kVK_ANSI_Period), carbonModifiers: UInt32(cmdKey), keyLabel: "V")
        check(Shortcut.reservedUse(of: dvorakPaste) == "Paste", "⌘V on another layout (Dvorak's V key) is taken too")
        for shortcut in [Shortcut.optionSpace, .optionShiftSpace, .optionShiftV, .commandO, .commandF] {
            check(Shortcut.reservedUse(of: shortcut) == nil, "\(shortcut.displayString) (a default) is free")
        }

        print("15. on chatgpt.com: chats are Chat and a temporary one is marked")
        spin(until: { !webView.isLoading && evaluate("document.readyState") as? String == "complete" }, seconds: 20)
        check(evaluate(#"document.documentElement.hasAttribute("data-quick-chat-temporary")"#) as? Bool == true,
              "the temporary chat is marked (dashed message box)")
        check((evaluate("document.cookie") as? String)?.contains("codex_composer_mode=chat") == true, "Chat mode, not Work")

        print("16. an answer that finishes while the panel is hidden puts a dot on the menu-bar icon")
        let observer = NotificationCenter.default.addObserver(forName: QuickChatController.unseenAnswerDidChange, object: chat,
                                                              queue: .main) { _ in MainActor.assumeIsolated { unseenPosts += 1 } }
        defer { NotificationCenter.default.removeObserver(observer) }
        // A stand-in for chatgpt.com's Stop button (its send button while answering).
        _ = evaluate(#"""
            const form = document.createElement("form");
            form.id = "quick-chat-self-test";
            form.innerHTML = '<button type="button" class="bg-composer-primary" style="width: 20px; height: 20px">Stop</button>';
            document.body.append(form);
            """#)
        check(evaluate(QuickChatController.answeringScript) as? Bool == true, "the stand-in reads as answering")
        chat.hide(restoreFocus: false)
        spin(until: { false }, seconds: 1.5)
        check(!chat.hasUnseenAnswer, "hidden while answering: no dot yet")
        _ = evaluate(#"document.getElementById("quick-chat-self-test").remove()"#)
        spin(until: { chat.hasUnseenAnswer }, seconds: 3)
        check(chat.hasUnseenAnswer && unseenPosts == 1, "the answer is done: a dot", "posts \(unseenPosts)")
        chat.show()
        check(!chat.hasUnseenAnswer && unseenPosts == 2, "shown again: no dot", "posts \(unseenPosts)")
        chat.hide(restoreFocus: false)
        spin(until: { false }, seconds: 1.5)
        check(!chat.hasUnseenAnswer, "hidden with nothing answering: no dot")

        print(failures == 0 ? "panel self-test: ALL PASSED" : "panel self-test: \(failures) FAILED")
        return failures == 0
    }
}
#endif
