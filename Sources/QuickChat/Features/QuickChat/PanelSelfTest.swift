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
        // Start from the default zoom and no saved panel frame; put the saved ones back afterwards.
        let defaults = UserDefaults.standard, zoomKey = QuickChatController.pageZoomDefaultsKey
        let frameKey = "NSWindow Frame \(QuickChatPanel.autosaveName)"
        let saved = [zoomKey, frameKey].map { ($0, defaults.object(forKey: $0)) }
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
        // Once it's shown: while it loads, a spinner takes the clicks (section 18).
        spin(until: { (webView.superview as? QuickChatContentView)?.isLoading == false }, seconds: 15)
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
        var reloads = 0
        let reload = panel.onReload
        panel.onReload = { reloads += 1 }
        check(press("r") && reloads == 1, "⌘R reloads")
        _ = press("r", [.command, .shift])
        check(reloads == 1, "⇧⌘R doesn't")
        panel.onReload = reload
        var clears = 0
        let clear = panel.onClearMessage
        panel.onClearMessage = { clears += 1 }
        func sendC(_ flags: NSEvent.ModifierFlags) { // through sendEvent, where the panel catches ⌃C
            panel.sendEvent(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                             windowNumber: panel.windowNumber, context: nil, characters: "c",
                                             charactersIgnoringModifiers: "c", isARepeat: false, keyCode: UInt16(kVK_ANSI_C))!)
        }
        panel.makeFirstResponder(webView)
        sendC(.control)
        check(clears == 1, "⌃C in the page clears the message box")
        sendC([.control, .shift])
        sendC([.control, .option])
        check(clears == 1, "⌃⇧C and ⌃⌥C don't")
        panel.makeFirstResponder(nil)
        sendC(.control)
        check(clears == 1, "⌃C with focus outside the page (the find bar, say) doesn't")
        panel.makeFirstResponder(webView)
        panel.onClearMessage = clear

        print("5. starts on a new saved chat; ⌘N / ⇧⌘N start a new saved / temporary chat")
        let start = webView.url?.absoluteString ?? "none"
        check(start == "https://chatgpt.com/", "first page: a new saved chat", start)
        var newChats: [Bool] = []
        panel.onNewChat = { newChats.append($0) }
        check(press("n") && press("N", [.command, .shift]), "⌘N and ⇧⌘N handled")
        _ = press("n", [])
        _ = press("n", [.command, .option])
        check(newChats == [false, true], "⌘N → saved, ⇧⌘N → temporary; plain n and ⌥⌘N ignored", "\(newChats)")

        print("6. opens at the bottom center of the screen; ⌘O moves it back there, keeping its size; nothing fills the screen")
        func atBottomCenter(_ size: NSSize, _ name: String) {
            guard let visible = panel.screen?.visibleFrame else { return check(false, name, "no screen") }
            let f = panel.frame
            check(abs(f.midX - visible.midX) < 1 && abs(f.minY - (visible.minY + QuickChatPanel.bottomMargin)) < 1
                  && f.size == size, name, "\(f) in \(visible)")
        }
        atBottomCenter(QuickChatPanel.defaultSize, "first open: 420×560, centered, 16 pt above the Dock")
        panel.setFrame(NSRect(x: 100, y: 300, width: 600, height: 700), display: false)
        check(press("o", keyCode: 31), "⌘O handled") // kVK_ANSI_O
        atBottomCenter(NSSize(width: 600, height: 700), "⌘O after moving and resizing: back at the bottom center, still 600×700")
        let before = panel.frame
        _ = press("f", keyCode: 3) // kVK_ANSI_F, once Maximize
        panel.zoom(nil)
        spin(until: { false }, seconds: 0.5)
        check(panel.frame == before, "⌘F and AppKit's zoom leave the panel's size and place alone", "\(panel.frame)")
        check(panel.collectionBehavior.contains(.fullScreenNone) && panel.collectionBehavior.contains(.fullScreenDisallowsTiling),
              "no macOS full screen or tiling")

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

        print("8. a first click on chatgpt.com's top bar reaches the page")
        let scripts = webView.configuration.userContentController.userScripts
        check(scripts.count == 6, "the page scripts are in place", "\(scripts.count) scripts")
        func firstClick(_ fromTop: CGFloat) -> Bool {
            let event = NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 80, y: frameView.bounds.maxY - fromTop),
                                           modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber, context: nil,
                                           eventNumber: 0, clickCount: 1, pressure: 1)!
            return webView.acceptsFirstMouse(for: event)
        }
        let band = QuickChatController.topBarHeight * webView.pageZoom
        check((webView as? QuickChatWebView)?.firstClickBand == band && firstClick(4) && firstClick(band - 2),
              "a first click on the top bar reaches the page (it drags the panel)", "band \((webView as? QuickChatWebView)?.firstClickBand ?? -1)")

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
                                     ("⌘W", cmdKey, kVK_ANSI_W), ("⌘↩", cmdKey, kVK_Return), ("⌘R", cmdKey, kVK_ANSI_R),
                                     ("⌃C", controlKey, kVK_ANSI_C)] {
            check(Shortcut.reservedUse(of: Shortcut(keyCode: UInt32(key), carbonModifiers: UInt32(carbon))) != nil, "\(combo) is taken")
        }
        let dvorakPaste = Shortcut(keyCode: UInt32(kVK_ANSI_Period), carbonModifiers: UInt32(cmdKey), keyLabel: "V")
        check(Shortcut.reservedUse(of: dvorakPaste) == "Paste", "⌘V on another layout (Dvorak's V key) is taken too")
        for shortcut in [Shortcut.optionSpace, .optionShiftSpace, .optionShiftV, .commandO] {
            check(Shortcut.reservedUse(of: shortcut) == nil, "\(shortcut.displayString) (a default) is free")
        }

        print("15. on chatgpt.com: chats are Chat, a chat's title is in the top bar")
        spin(until: { !webView.isLoading && evaluate("document.readyState") as? String == "complete" }, seconds: 20)
        check((evaluate("document.cookie") as? String)?.contains("codex_composer_mode=chat") == true, "Chat mode, not Work")
        // The narrow layout (section 6 left the panel at 600 pt), with chatgpt.com done building
        // the page: a loaded page can take a while to show its message box, and to lay out again
        // after the zoom changes above. So these measurements are retried until they settle.
        panel.setContentSize(QuickChatPanel.defaultSize)
        spin(until: { evaluate(#"!!document.querySelector('form [contenteditable="true"]')"#) as? Bool == true }, seconds: 20)
        let barEdgesScript = #"""
            (() => {
              const shown = e => e.getClientRects().length && getComputedStyle(e).visibility !== "hidden";
              const bar = [...document.querySelectorAll("main > header.draggable")].find(shown);
              const button = bar && [...bar.querySelectorAll("button")].filter(shown).at(-1);
              const box = [...document.querySelectorAll('form [class*="ComposerLayoutRoot-"]')].filter(shown).pop();
              const [b, m] = [button?.getBoundingClientRect(), box?.getBoundingClientRect()];
              const gap = b && m ? [m.right - b.right, b.top - (innerHeight - m.bottom)].map(d => Math.abs(d).toFixed(0)).join(" ") : "no bar";
              return gap;
            })()
            """#
        var barEdges: String?
        spin(until: { barEdges = evaluate(barEdgesScript) as? String; return barEdges == "0 0" }, seconds: 5)
        check(barEdges == "0 0", "the top bar's buttons sit as far from the panel's top and side as the message box from its bottom and side",
              "\(barEdges ?? "nothing") px off (side, top)")
        // The side spacing chatgpt.com gives the chat text and the message box alike: the chat's, and the box's.
        let sidesScript = #"""
            (() => {
              const probe = parent => {
                const div = document.createElement("div");
                div.style.paddingLeft = "var(--thread-body-inline-padding)";
                parent.append(div);
                const value = getComputedStyle(div).paddingLeft;
                div.remove();
                return value;
              };
              const strip = [...document.querySelectorAll('[class~="max-sm:pb-6"]')].find(e => e.querySelector("form") && e.getClientRects().length);
              return [probe(document.body), strip ? probe(strip) : "no message box"].join(" ");
            })()
            """#
        var sides: String?
        spin(until: { sides = evaluate(sidesScript) as? String; return sides == "16px 8px" }, seconds: 5)
        check(sides == "16px 8px", "the chat keeps chatgpt.com's 16px at the sides; the message box sits 8px in",
              "chat, box: \(sides ?? "nothing")")
        let titleInBar = #"getComputedStyle(document.documentElement).getPropertyValue("--quick-chat-title")"#
        check(evaluate(titleInBar) as? String == "", "no title in the top bar on the new-chat page")
        _ = evaluate(#"""
            window.quickChatSelfTest = [location.href, document.title];
            history.replaceState(history.state, "", "/c/quick-chat-self-test");
            document.title = 'A "quoted" \\ title';
            """#)
        spin(until: { false }, seconds: 0.3)
        let shownTitle = evaluate(titleInBar) as? String ?? ""
        check(shownTitle.contains("quoted") && shownTitle.hasSuffix(#"title""#), "a chat's title goes in the top bar", shownTitle)
        _ = evaluate(#"history.replaceState(history.state, "", quickChatSelfTest[0]); document.title = quickChatSelfTest[1];"#)
        spin(until: { false }, seconds: 0.3)
        check(evaluate(titleInBar) as? String == "", "back on the new-chat page: no title")

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
        check(evaluate(PageScripts.answeringScript) as? Bool == true, "the stand-in reads as answering")
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

        print("17. Share moves from the top bar into its More menu")
        // A stand-in top bar and More menu, so no real chat gets shared (Share makes a public link).
        _ = evaluate(#"""
            const main = document.createElement("main");
            main.id = "quick-chat-self-test-bar";
            main.innerHTML = '<header class="draggable"><div class="no-drag" id="quick-chat-self-test-more-pill"><div>'
              + '<button aria-label="More" id="quick-chat-self-test-more">More</button></div></div>'
              + '<div class="no-drag" id="quick-chat-self-test-share-pill"><div><button aria-label="Share"><svg></svg>Share</button></div></div></header>';
            document.body.append(main);
            window.quickChatSelfTestShares = 0;
            main.querySelector('[aria-label="Share"]').addEventListener("click", () => quickChatSelfTestShares++);
            const menu = document.createElement("div");
            menu.id = "quick-chat-self-test-menu";
            menu.setAttribute("role", "menu");
            menu.setAttribute("aria-labelledby", "quick-chat-self-test-more");
            menu.innerHTML = '<div role="menuitem" tabindex="-1" data-radix-collection-item=""><span class="icon-sm"></span><span>Rename</span></div>';
            document.body.append(menu);
            true
            """#)
        spin(until: { false }, seconds: 0.3)
        let added = evaluate(#"""
            const item = document.getElementById("quick-chat-self-test-menu").firstElementChild;
            const display = id => getComputedStyle(document.getElementById(id)).display;
            [item.hasAttribute("data-quick-chat-share"), item.textContent.trim(), !!item.querySelector("svg"),
             item.hasAttribute("data-radix-collection-item"), display("quick-chat-self-test-share-pill") === "none",
             display("quick-chat-self-test-more-pill") !== "none"].join(" ")
            """#) as? String
        check(added == "true Share true false true true", "the menu gets a Share item first, with the button's icon; the button goes",
              added ?? "nothing")
        _ = evaluate(#"document.getElementById("quick-chat-self-test-menu").firstElementChild.click(); true"#)
        spin(until: { false }, seconds: 0.3)
        check(evaluate("quickChatSelfTestShares") as? Int == 1, "choosing it clicks the Share button once")
        _ = evaluate(#"""
            document.getElementById("quick-chat-self-test-bar").remove();
            document.getElementById("quick-chat-self-test-menu").remove();
            true
            """#)

        print("18. a loading page hides behind a spinner until chatgpt.com has built it")
        chat.show() // section 16 left it hidden, where the page doesn't draw
        let reloadStart = Date()
        webView.reload()
        spin(until: { content.isLoading }, seconds: 5)
        let middle = content.convert(NSPoint(x: content.bounds.midX, y: content.bounds.midY), to: content.superview)
        let hit = content.hitTest(middle).map { "\(type(of: $0))" } ?? "nothing"
        check(content.isLoading && webView.alphaValue == 0 && hit == "LoadingView",
              "while it loads: the page hidden, a spinner in its place that takes the clicks", "\(content.isLoading), \(webView.alphaValue), \(hit)")
        spin(until: { !content.isLoading }, seconds: 12)
        let took = Date().timeIntervalSince(reloadStart)
        check(!content.isLoading && took < 9, "shown once built, well before the 10 s fallback", String(format: "%.1f s", took))
        spin(until: { webView.alphaValue == 1 }, seconds: 1)
        check(webView.alphaValue == 1, "… and the page is fully there")

        print("19. a chat's text fades out at its scroll area's top and bottom, not over the message box")
        // A stand-in for a chat's scroll area: its parent takes the fade, which needs the height
        // chatgpt.com gives the scroll area for the strip under it (the message box's).
        let fade = #"""
            (() => {
              const parent = document.getElementById("quick-chat-self-test-thread");
              return parent.style.getPropertyValue("--quick-chat-thread-scroll-padding-bottom") + " " + (getComputedStyle(parent).maskImage !== "none");
            })()
            """#
        _ = evaluate(#"""
            const parent = document.createElement("div");
            parent.id = "quick-chat-self-test-thread";
            parent.innerHTML = '<div class="thread-scroll-container" style="--thread-scroll-padding-bottom: 100px"></div>';
            document.body.append(parent);
            true
            """#)
        spin(until: { false }, seconds: 0.2)
        let opened = evaluate(fade) as? String
        check(opened == "100px true", "a chat opens: its scroll area's parent gets the strip's height and the fade", opened ?? "nothing")
        _ = evaluate(#"""
            document.getElementById("quick-chat-self-test-thread").firstElementChild.style.setProperty("--thread-scroll-padding-bottom", "150px");
            true
            """#)
        spin(until: { false }, seconds: 0.2)
        let grown = evaluate(fade) as? String
        check(grown == "150px true", "the message box grows: the fade's bottom follows it", grown ?? "nothing")
        _ = evaluate(#"document.getElementById("quick-chat-self-test-thread").remove(); true"#)

        print("20. ⌘K's chat list: a request chatgpt.com turns down is made again")
        // A stand-in for chatgpt.com's answers, under the page's scripts (no request leaves):
        // "Too many requests" for the chat list once, then the list; always for other addresses,
        // also the same path on another site.
        let userContent = webView.configuration.userContentController
        let pageScripts = userContent.userScripts.map { $0 }
        userContent.removeAllUserScripts()
        userContent.addUserScript(WKUserScript(source: #"""
            const realFetch = window.fetch;
            window.quickChatSelfTestCalls = {list: 0, other: 0, otherSite: 0};
            window.fetch = function (input, init) {
              const url = new URL(input instanceof Request ? input.url : String(input), location.href);
              if (!url.search.includes("quick-chat-self-test")) return realFetch.apply(this, arguments);
              const kind = url.origin !== location.origin ? "otherSite" : url.pathname === "/backend-api/conversations" ? "list" : "other";
              const calls = ++quickChatSelfTestCalls[kind];
              return Promise.resolve(new Response("{}", {status: kind === "list" && calls > 1 ? 200 : 429}));
            };
            """#, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        for script in pageScripts { userContent.addUserScript(script) }
        webView.reload()
        spin(until: { content.isLoading }, seconds: 5)
        spin(until: { !content.isLoading }, seconds: 12)
        var retried: String?
        webView.callAsyncJavaScript(#"""
            const list = await fetch("/backend-api/conversations?quick-chat-self-test=1");
            const other = await fetch("/backend-api/me?quick-chat-self-test=1");
            const otherSite = await fetch("https://example.com/backend-api/conversations?quick-chat-self-test=1");
            // A request whose own signal is aborted but overridden: still asked for again.
            quickChatSelfTestCalls.list = 0;
            const aborted = AbortSignal.abort();
            const overridden = await fetch(new Request("/backend-api/conversations?quick-chat-self-test=2", {signal: aborted}), {signal: null});
            const calls = quickChatSelfTestCalls;
            return [list.status, other.status, calls.other, otherSite.status, calls.otherSite, overridden.status, calls.list].join(" ");
            """#, in: nil, in: .page) { retried = (try? $0.get()) as? String ?? "failed: \($0)" }
        spin(until: { retried != nil }, seconds: 9)
        check(retried == "200 429 1 429 1 200 2", "the chat list is asked for again after \"Too many requests\"; other requests aren't",
              "list; another address, another site, a list request with its signal overridden (status, calls): \(retried ?? "nothing")")
        userContent.removeAllUserScripts()
        for script in pageScripts { userContent.addUserScript(script) }

        print("21. the page's confirm() asks in a sheet; not while the panel is hidden")
        func texts(in view: NSView?) -> [String] {
            guard let view else { return [] }
            return ((view as? NSTextField).map { [$0.stringValue] } ?? []) + view.subviews.flatMap(texts(in:))
        }
        var confirmed: Any?
        webView.evaluateJavaScript("confirm('Quick Chat self-test')") { value, _ in confirmed = value }
        spin(until: { panel.attachedSheet != nil }, seconds: 3)
        let sheetTexts = texts(in: panel.attachedSheet?.contentView)
        check(sheetTexts.contains("chatgpt.com says:") && sheetTexts.contains("Quick Chat self-test"),
              "a sheet says which site asks, and what", "\(sheetTexts)")
        if let sheet = panel.attachedSheet { panel.endSheet(sheet, returnCode: .alertFirstButtonReturn) }
        spin(until: { confirmed != nil }, seconds: 3)
        check(confirmed as? Bool == true, "OK → true", "\(confirmed ?? "nothing")")
        chat.hide(restoreFocus: false)
        confirmed = nil
        webView.evaluateJavaScript("confirm('Quick Chat self-test')") { value, _ in confirmed = value }
        spin(until: { confirmed != nil }, seconds: 3)
        check(confirmed as? Bool == false && panel.attachedSheet == nil, "hidden: no sheet, false", "\(confirmed ?? "nothing")")
        chat.show()
        confirmed = nil
        webView.evaluateJavaScript("confirm('Quick Chat self-test')") { value, _ in confirmed = value }
        spin(until: { panel.attachedSheet != nil }, seconds: 3)
        chat.hide(restoreFocus: false)
        spin(until: { confirmed != nil }, seconds: 3)
        check(confirmed as? Bool == false && panel.attachedSheet == nil, "hiding the panel answers an open one: false",
              "\(confirmed ?? "nothing")")

        print("22. the shortcut brings an open panel to the front from another window, and hides a focused one")
        chat.show()
        spin(until: { NSApp.isActive && panel.isKeyWindow }, seconds: 2)
        if NSApp.isActive {
            let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
                                 backing: .buffered, defer: false)
            other.isReleasedWhenClosed = false
            other.level = .floating
            other.makeKeyAndOrderFront(nil)
            spin(until: { !panel.isKeyWindow }, seconds: 2)
            check(panel.isVisible && !panel.isKeyWindow, "another window has focus, the panel stays up")
            chat.toggle()
            spin(until: { panel.isKeyWindow }, seconds: 2)
            check(panel.isVisible && panel.isKeyWindow, "the shortcut focuses the panel")
            chat.toggle()
            check(!panel.isVisible, "pressed again: hidden")
            other.close()
        } else {
            // macOS lets a process started from a shell become active only while it's frontmost.
            print("  skip macOS didn't let the self-test become the active app")
        }

        print("23. Ask About Selection that can't put its text in a chat offers to copy it")
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        spin(until: { webView.url?.absoluteString == "about:blank" && !webView.isLoading && !content.isLoading }, seconds: 5)
        chat.ask(about: "Quick Chat self-test text")
        spin(until: { content.toastText != nil }, seconds: 5)
        check(content.toastText == "Couldn't put the text in a new chat", "it says so, with Copy Text", content.toastText ?? "no toast")

        print("24. a page that doesn't load: a message over a page that's there, Try Again in place of one that isn't")
        let unreachable = URLRequest(url: URL(string: "https://quick-chat-self-test.invalid/")!)
        webView.load(unreachable)
        spin(until: { content.toastText?.hasPrefix("Couldn't load") == true }, seconds: 10)
        check(content.toastText?.hasPrefix("Couldn't load") == true && !content.isShowingError, "over a page: a message, the page stays",
              content.toastText ?? "no toast")
        content.setLoading(true) // as while a page is on its way
        webView.load(unreachable)
        spin(until: { content.isShowingError }, seconds: 10)
        func buttons(in view: NSView) -> [NSButton] { ((view as? NSButton).map { [$0] } ?? []) + view.subviews.flatMap(buttons(in:)) }
        let tryAgain = buttons(in: content).first { $0.title == "Try Again" }
        check(content.isShowingError && tryAgain != nil && webView.alphaValue == 0, "in place of the page: an error with Try Again")
        tryAgain?.performClick(nil)
        spin(until: { !content.isShowingError && !content.isLoading }, seconds: 10)
        check(!content.isShowingError && !content.isLoading && webView.url?.absoluteString == "about:blank",
              "Try Again loads the page again", webView.url?.absoluteString ?? "no page")
        content.setLoading(true)
        webView.load(unreachable)
        chat.ask(about: "Quick Chat self-test text") // waits for the page, which won't load
        spin(until: { content.isShowingError }, seconds: 10)
        check(content.isShowingError && content.toastText == "Couldn't put the text in a new chat",
              "text waiting for a page that doesn't load: offered to copy", content.toastText ?? "no toast")

        print("25. a preloaded panel loads chatgpt.com before it's shown")
        let warm = QuickChatController()
        warm.preload()
        let warmPanel = NSApp.windows.lazy.compactMap { $0 as? QuickChatPanel }.first { $0 !== panel }
        let warmPage = warmPanel.flatMap { $0.contentView?.superview }.flatMap(webView(in:))
        check(warmPanel?.isVisible == false && warmPage?.url?.host == "chatgpt.com", "built, hidden, on chatgpt.com",
              warmPage?.url?.absoluteString ?? "no page")
        warm.tearDown()

        print("26. ⌃C empties the message box, but not while you type in another field")
        webView.loadHTMLString("""
            <form><div contenteditable="true">Quick Chat self-test draft</div></form>
            <textarea id="other">another field</textarea>
            """, baseURL: nil)
        let boxText = "document.querySelector('form [contenteditable]')?.innerText.trim()"
        spin(until: { evaluate(boxText) as? String == "Quick Chat self-test draft" }, seconds: 5)
        func clearScript() -> Bool? {
            var cleared: Bool?, done = false
            webView.callAsyncJavaScript(PageScripts.clearMessageBoxScript, arguments: [:], in: nil, in: .page) {
                cleared = try? $0.get() as? Bool
                done = true
            }
            spin(until: { done }, seconds: 3)
            return cleared
        }
        _ = evaluate("document.getElementById('other').focus()")
        check(clearScript() == false && evaluate(boxText) as? String == "Quick Chat self-test draft",
              "typing in another field: the message box stays", evaluate(boxText) as? String ?? "no box")
        _ = evaluate("document.activeElement.blur()")
        chat.clearMessageBox()
        spin(until: { evaluate(boxText) as? String == "" }, seconds: 3)
        check(evaluate(boxText) as? String == "", "emptied", evaluate(boxText) as? String ?? "no box")
        check(evaluate("document.getElementById('other').value") as? String == "another field", "the other field is left alone")
        check(clearScript() == false, "an empty message box: nothing to clear")

        print(failures == 0 ? "panel self-test: ALL PASSED" : "panel self-test: \(failures) FAILED")
        return failures == 0
    }
}
#endif
