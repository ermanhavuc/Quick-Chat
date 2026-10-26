import Foundation

/// Everything Quick Chat adds to chatgpt.com's page: the scripts and style sheets the panel's web
/// view runs (`QuickChatController`). All of it depends on chatgpt.com's markup, so when
/// chatgpt.com changes, start here.
enum PageScripts {
    // MARK: chatgpt.com's markup

    // The hooks into chatgpt.com's markup that several scripts share; the others sit next to the
    // one rule or script that uses them. A hook that stops matching quietly turns its touch-up
    // off; chatgpt.com itself keeps working.

    /// The message box in the composer form: once a contenteditable #prompt-textarea, now an
    /// unnamed contenteditable (ProseMirror).
    static let composerSelector = #"form [contenteditable="true"]"#
    static let messageBoxSelector = "#prompt-textarea, \(composerSelector)"
    /// The composer's model picker, whose menu holds the thinking effort slider.
    static let modelPickerSelector = #"button[aria-label="Select ChatGPT model"]"#
    /// A chat's More (…) and Share buttons in the top bar. These go by the buttons' English labels,
    /// as chatgpt.com gives them no other names.
    static let moreLabel = #"[aria-label="More"]"#
    static let shareLabel = #"[aria-label="Share"]"#

    // MARK: Run on demand

    /// Goes to `path` through chatgpt.com's own router (pushState plus the popstate event that
    /// Back/Forward fire), which is quicker than reloading the app, then focuses the new chat's
    /// message box once it's there (throwing after 5 s, so `newChat` reloads instead). Already
    /// there: does nothing if that chat has no messages yet, else reloads so the chat starts
    /// fresh. Loads chatgpt.com when on another site (sign-in).
    static let newChatScript = """
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
    static let messageBoxScript = """
        const sleep = ms => new Promise(r => setTimeout(r, ms));
        const messageBox = () => [...document.querySelectorAll('\(messageBoxSelector)')]
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
    static let hasMessagesScript =
        #"[...document.querySelectorAll("[data-turn-key]")].some(e => e.getClientRects().length)"#

    /// Opens a new chat at `path` like `newChatScript`, but never reloads itself, which would
    /// drop the text: it returns "reload" if that's needed, and `insertQuestion` reloads and
    /// runs it again. Then pastes `text` into the message box as if with ⌘V (so a long text
    /// becomes an attachment, as chatgpt.com does with pastes), followed by an empty line for
    /// the question. The previous chat's message box is never written to (`newMessageBox`).
    static let askScript = """
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

    /// The effort slider sits in the composer's model picker menu ("Power"; Left/Right arrow keys
    /// adjust it, as the menu item's aria-keyshortcuts says). Opens the menu if needed, steps the
    /// slider, closes the menu again and puts focus back in the composer. Returns the level
    /// after the step ("High, 3 of 5.") and whether it changed. Only rendered elements count:
    /// after a new chat the page keeps the previous chat's composer around, hidden, ahead of the
    /// new one. Depends on chatgpt.com's markup.
    static let stepEffortScript = """
        const sleep = ms => new Promise(r => setTimeout(r, ms));
        const shown = selector => [...document.querySelectorAll(selector)].filter(e => e.getClientRects().length);
        const findSlider = () => shown('[role="menu"] [role="menuitem"][aria-keyshortcuts~="ArrowRight"]')[0];
        const level = slider => slider.closest('[role="menu"]').querySelector('[role="status"]')?.textContent;
        const press = (el, key) => el.dispatchEvent(new KeyboardEvent("keydown", {key, code: key, bubbles: true, cancelable: true}));
        let slider = findSlider();
        const opened = !slider;
        if (opened) {
          const trigger = shown('form \(modelPickerSelector)')[0]
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

    /// Whether chatgpt.com is answering: the message box's send button has become Stop (a
    /// plain button rather than the form's submit button; or labeled Stop, in English).
    static let answeringScript = #"""
        [...document.querySelectorAll('form button[class~="bg-composer-primary"][type="button"], form button[aria-label="Stop"]')]
          .some(b => b.getClientRects().length)
        """#

    /// Focuses chatgpt.com's message box: once a contenteditable #prompt-textarea, now an unnamed
    /// contenteditable (ProseMirror) in the composer form. Pages also keep a hidden one (a chat
    /// has the new-chat page's), so it takes the first that's rendered. Best effort, as it
    /// depends on chatgpt.com's markup.
    static let focusComposerScript =
        "[...document.querySelectorAll('\(messageBoxSelector)')].find(e => e.getClientRects().length)?.focus();"

    /// Empties the message box, as if you selected its text and pressed Delete, unless you're
    /// typing in another field (a message you're editing, say). Returns whether it had text to
    /// clear.
    static let clearMessageBoxScript = """
        const box = [...document.querySelectorAll('\(messageBoxSelector)')].find(e => e.getClientRects().length);
        const field = document.activeElement?.closest('input, textarea, [contenteditable="true"]');
        if (!box || (field && field !== box) || !box.innerText.trim()) return false;
        box.focus();
        const all = document.createRange();
        all.selectNodeContents(box);
        getSelection().removeAllRanges();
        getSelection().addRange(all);
        document.execCommand("delete");
        return true;
        """

    // MARK: Page touch-ups

    /// The page touch-ups, run at the start of every chatgpt.com page load (in the panel and its
    /// popups, which share them).
    static var userScripts: [String] {
        [pageStyleScript, dragScript, chatOnlyScript, shareInMenuScript, readyScript, chatListRetryScript]
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
    /// - The message box sat 16px from the panel's sides (--thread-body-inline-padding, as the
    ///   chat text) and 24px from its bottom in a chat; on the new-chat page, 24px plus a
    ///   16px-padded notice slot under the box (empty, or "For safety, we may keep a copy of this
    ///   chat…" in a temporary chat), which showed as a dark strip under the box. The box now
    ///   sits 8px from the sides and the bottom, as the top bar's buttons do from the top and
    ///   sides; the chat text keeps its 16px. The notice is hidden; other banners in that slot
    ///   keep their space.
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
    ///   The scroll area now ends at the box's top edge, and the spacer is cut to 16px, so a
    ///   chat's end stops 16px above the box. The variable is the strip's height plus that
    ///   16px, so the scroll area is the panel minus the variable, plus 16px.
    /// - Text in a chat stopped at the scroll area's edges as if cut off. It now fades out over
    ///   16px: at the bottom, in the gap above the message box; at the top, from where the
    ///   scroll area starts (`--quick-chat-fade-top`: the top bar's buttons, see `glassCSS`), in
    ///   its padding, so a chat's first message isn't faded.
    ///   The scroll area itself can't take the mask: WebKit then also hides the message box,
    ///   which sits inside it in the page but is placed (and drawn) below it. So the mask goes
    ///   on its parent, which holds both and doesn't scroll, and is opaque again from the
    ///   strip down; `pageStyleScript` copies the variable there, as the parent can't read it.
    /// If chatgpt.com renames these hooks, the rules stop matching and the page looks as before.
    private static let pageLayoutCSS = """
        body, body [data-theme] { --thread-composer-bottom-inset: 0.5rem; }
        [class*="footer-"][class~="bottom-0"]:has(form), [class~="max-sm:pb-6"]:has(form) { --thread-body-inline-padding: 0.5rem; }
        @media not all and (min-width: 40rem) {
          [class~="max-sm:pb-6"]:has(form) { padding-bottom: var(--thread-composer-bottom-inset, 0.5rem); }
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
          max-height: calc(100% - var(--thread-scroll-padding-bottom, 0px) + 1rem);
          scroll-padding-bottom: 1rem;
        }
        .thread-scroll-container [class*="h-[calc(var(--thread-scroll-padding-bottom)"] { height: 1rem; }
        :has(> .thread-scroll-container) {
          mask-image: linear-gradient(to bottom,
            transparent var(--quick-chat-fade-top, 0px), #000 calc(var(--quick-chat-fade-top, 0px) + 1rem),
            #000 calc(100% - var(--quick-chat-thread-scroll-padding-bottom)),
            transparent calc(100% - var(--quick-chat-thread-scroll-padding-bottom) + 1rem),
            #000 calc(100% - var(--quick-chat-thread-scroll-padding-bottom) + 1rem));
        }
        """

    /// Liquid Glass (macOS 26 and later; see `QuickChatPanel.setContent`): the page lets the
    /// panel's glass show through instead of painting chatgpt.com's surfaces.
    /// - The page is a 45% tint of the Mac background color over the glass, following the page's
    ///   Light/Dark theme, so text stays readable over a bright window behind the panel. Its body,
    ///   main area and the strip behind the message box (in a chat and on the new-chat page) are
    ///   see-through, and so are the wide layout's page layers and docked sidebar, which
    ///   keeps its own light tint.
    /// - The message box and the top bar's buttons get a see-through white fill: 7% in Dark mode,
    ///   70% in Light mode (chatgpt.com's solid white box looked pasted on). Menus, dialogs and
    ///   the narrow layout's sliding sidebar keep their solid Mac colors.
    /// - A chat's scroll area starts at the top bar's buttons' bottom edge, so text doesn't run
    ///   behind the see-through bar, and mirrors the message box: a chat
    ///   starts 16px under the buttons, and its text fades out in that gap. chatgpt.com's
    ///   floating inset is 16px under the buttons; in the layout that starts the content frame
    ///   below the bar (it's 8px there), the scroll area's parent moves up to reach them.
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
        main:has(> header.draggable) .thread-scroll-container {
          margin-top: var(--quick-chat-fade-top);
          padding-top: 1rem;
          max-height: calc(100% - var(--thread-scroll-padding-bottom, 0px) + 1rem - var(--quick-chat-fade-top));
        }
        main:has(> header.draggable) :has(> .thread-scroll-container) {
          --quick-chat-fade-top: max(0px, calc(var(--thread-floating-content-top-inset, 60px) - 1rem));
          margin-top: min(0px, calc(var(--thread-floating-content-top-inset, 60px) - 1rem));
        }
        """

    /// Quick Chat is just chats (see `chatOnlyScript`), so chatgpt.com's sidebar is gone: its
    /// button in the top bar, the sidebar that slides in over the chat (with its dimmed
    /// backdrop), and in the wide layout the side panel with its icon rail. The Chat/Work
    /// switch on the new-chat page goes too. A group of top bar buttons is hidden only if the
    /// sidebar button is all it holds (in a chat, New chat sits beside it).
    private static let chatOnlyCSS = """
        header.draggable .no-drag:has(button[aria-controls="browser-sidebar-popover"]):not(:has(button:not([aria-controls="browser-sidebar-popover"]))),
        #browser-sidebar-popover, .codex-dialog-overlay:has(~ #browser-sidebar-popover),
        aside.app-shell-left-panel, [class~="@container/home-mode-toggle"] {
          display: none;
        }
        """

    /// A chat's title (`--quick-chat-title`, set by `chatOnlyScript`)
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
        main > header.draggable:has(button\(moreLabel))
          .no-drag:has(> * > button\(shareLabel)):not(:has(button:not(\(shareLabel)))) {
          display: none;
        }
        """

    /// The page's touch-ups, with `glassCSS` where the panel is Liquid Glass.
    private static var pageCSS: String {
        let css = macColorsCSS + pageLayoutCSS + chatOnlyCSS + chatTitleCSS + shareInMenuCSS
        if #available(macOS 26, *) { return css + glassCSS }
        return css
    }

    /// Adds `pageCSS` as a constructed style sheet, which survives the page re-rendering its own
    /// DOM. Its rules aren't in a cascade layer, so they beat chatgpt.com's. Keeps a copy of a
    /// chat's --thread-scroll-padding-bottom, which chatgpt.com sets on its scroll area, on the
    /// scroll area's parent for the chat's fade (`pageLayoutCSS`), as a chat opens and as the
    /// message box grows or shrinks.
    static let pageStyleScript = """
        if (location.hostname === "chatgpt.com") {
          const sheet = new CSSStyleSheet();
          sheet.replaceSync(\(String(decoding: try! JSONEncoder().encode(pageCSS), as: UTF8.self)));
          document.adoptedStyleSheets = [...document.adoptedStyleSheets, sheet];
          const scrollAreas = document.getElementsByClassName("thread-scroll-container");
          new MutationObserver(() => {
            for (const area of scrollAreas) {
              const value = area.style.getPropertyValue("--thread-scroll-padding-bottom"), parent = area.parentElement;
              if (parent && parent.style.getPropertyValue("--quick-chat-thread-scroll-padding-bottom") !== value) {
                parent.style.setProperty("--quick-chat-thread-scroll-padding-bottom", value);
              }
            }
          }).observe(document, {subtree: true, childList: true, attributes: true, attributeFilter: ["style"]});
        }
        """

    /// The page's messages to the app (`QuickChatController`'s WKScriptMessageHandler).
    static let dragMessage = "quickChatDragPanel"
    static let openInBrowserMessage = "quickChatOpenInBrowser"
    static let readyMessage = "quickChatPageReady"

    /// Tells the app when chatgpt.com has built its page (`coverUntilReady`): loaded, its message
    /// box shown and still for 250 ms (before that, the server's first version of the page and
    /// the app taking it over move things around), with the box's model picker, which arrives
    /// last (up to seconds later); without one (signed out), 4 s after the box. Checks every
    /// 50 ms until then (also while the page doesn't draw: hidden or covered), and only on a
    /// page load. Gives up after 10 s, when the app shows the page anyway, so a page without a
    /// message box (an error page) isn't checked for as long as it's open. Depends on
    /// chatgpt.com's markup.
    static let readyScript = """
        if (location.hostname === "chatgpt.com") {
          const started = performance.now();
          let last = "", still = 0, firstBox = 0;
          const check = () => {
            const now = performance.now();
            const box = document.readyState === "complete"
              && [...document.querySelectorAll('\(composerSelector)')].find(e => e.getClientRects().length);
            if (box && !firstBox) firstBox = now;
            const r = box ? box.getBoundingClientRect() : null;
            const place = r ? [r.x, r.y, r.width, r.height].join() : "";
            if (place !== last) { last = place; still = now; }
            const built = box && (box.closest("form").querySelector('\(modelPickerSelector)') || now - firstBox > 4000);
            if (built && now - still >= 250) webkit.messageHandlers.\(readyMessage).postMessage(null);
            else if (now - started < 10000) setTimeout(check, 50);
          };
          check();
        }
        """

    /// ⌘K's recent chats come from your chat list, which chatgpt.com loads once per page; until
    /// then it shows the titles it saved last time. When loading fails (it answers "Too many
    /// requests" at times, for half a minute or so), the titles vanish, and it doesn't try again
    /// until the page loads again, which in the panel can be days. So a failed request for the
    /// list (too many requests, a server error, no connection) is made again after 2, 5, 10 and
    /// 20 s before the page sees it fail, meanwhile showing the saved titles; it stops when the
    /// page gives up on it (⌘K closed).
    static let chatListRetryScript = """
        if (location.hostname === "chatgpt.com") {
          const pageFetch = window.fetch;
          const isChatList = (input, init) => {
            const href = typeof input === "string" ? input : input instanceof URL ? input.href : input?.url;
            const method = init?.method ?? (input instanceof Request ? input.method : "GET");
            const url = href == null ? null : new URL(href, location.href);
            return url?.origin === location.origin && url.pathname === "/backend-api/conversations" && method.toUpperCase() === "GET";
          };
          window.fetch = async function (input, init) {
            if (!isChatList(input, init)) return pageFetch.apply(this, arguments);
            const signal = init && "signal" in init ? init.signal : input instanceof Request ? input.signal : null;
            for (const wait of [2000, 5000, 10000, 20000]) {
              try {
                const response = await pageFetch.apply(this, arguments);
                if (response.status !== 429 && response.status < 500) return response;
              } catch (error) {
                if (signal?.aborted) throw error;
              }
              await new Promise(resolve => setTimeout(resolve, wait));
              signal?.throwIfAborted();
            }
            return pageFetch.apply(this, arguments);
          };
        }
        """

    /// Keeps the panel to chats (`isChatPath`): a link to another chatgpt.com page, or the page
    /// moving there itself (it routes in place with pushState or replaceState, without a page
    /// load the app would see), opens it in the default browser instead, and the panel goes
    /// back; Back/Forward skip such pages. ⇧⌘S (chatgpt.com's sidebar key) does nothing, as the
    /// sidebar is gone (`chatOnlyCSS`). Chats are always Chat, never Work: the Chat/Work switch is
    /// gone too, so its cookie is set to Chat before the page reads it. Puts a chat's title in
    /// `--quick-chat-title` for the top bar (`chatTitleCSS`), in a style sheet of its own:
    /// chatgpt.com names the page after the chat (a temporary one after its first message), and
    /// every other page "ChatGPT".
    static let chatOnlyScript = """
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
              markTitle();
            };
          }
          addEventListener("popstate", event => {
            if (outside(location.href)) {
              event.stopImmediatePropagation();
              history.back();
            }
            markTitle();
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
    static let shareInMenuScript = """
        if (location.hostname === "chatgpt.com") {
          const addShare = menu => {
            const trigger = document.getElementById(menu.getAttribute("aria-labelledby"));
            if (!trigger?.matches('main > header.draggable button\(moreLabel)')) return;
            const share = trigger.closest("header").querySelector('button\(shareLabel)');
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
    static let dragScript = """
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
}
