# Quick Chat

**The ⌥Space chat bar we all loved in ChatGPT Classic, brought to the new ChatGPT app.**

Press ⌥Space anywhere on your Mac, ask a quick question, and get a plain ChatGPT chat in a small floating panel: no agent task, no Work allowance used.

Quick Chat is a small menu-bar app for macOS. It works alongside the new ChatGPT desktop app (and frees ⌥Space from its Mini shortcut), but it doesn't need it: without any ChatGPT app installed, it runs on its own as a standalone quick chat.

https://github.com/user-attachments/assets/794aeec5-806e-40d9-b5fb-b281d90393a4

*Reading an article, hitting an unfamiliar term, asking about it with ⌥Space, and getting back to reading.*

## Why this exists

ChatGPT Classic for Mac has a chat bar on ⌥Space: press it anywhere, ask a question, get a normal chat.

The new ChatGPT desktop app (Chat, Work and Codex) works differently:

- **⌥Space opens Mini**, which starts Work/Codex agent tasks, not plain chats.
- **The experimental Popout Window** (Settings → Experimental features) also starts Work/Codex agent tasks.
- **Plain chat is only reachable inside the app window.** There is no system-wide shortcut to it.

That matters because the two kinds of usage are metered differently. Work and Codex share one usage allowance with a 5-hour window and a weekly limit, while Chat has its own model availability and message limits ([OpenAI: Managing usage in Work and Codex](https://help.openai.com/en/articles/20001516)). A quick question asked through Mini counts against the agent allowance you may want to keep for real tasks.

Why not just keep using ChatGPT Classic? Its chat bar is great, but Classic is falling behind:

- **New features skip it.** OpenAI still ships model updates and bug fixes, but says new features may come only to the new app ([OpenAI: Moving to the new ChatGPT desktop app](https://help.openai.com/en/articles/20001276)). Classic hasn't had a new build since July 2026, and in daily use its chat bar has become flaky.
- **It can't show Intelligent UI**, GPT-6's answers that mix text, visuals and interactive elements. In OpenAI's words: "The older ChatGPT desktop apps for macOS and Windows do not support these capabilities; use ChatGPT on the web instead." ([OpenAI: GPT-6 and other models in ChatGPT](https://help.openai.com/en/articles/20001354-gpt-6-and-other-models-in-chatgpt))

Quick Chat *is* ChatGPT on the web, so you keep the ⌥Space chat bar and get every new web feature the day it ships.

Quick Chat fills the gap the simple way: it shows chatgpt.com in a small floating panel, so every message is a regular ChatGPT chat.

## What it does

Two features, both off until you turn them on from the menu-bar icon. Your choices are remembered. **Launch at Login**, in the same menu, starts Quick Chat when you log in.

### Quick Chat

- A global shortcut (⌥Space by default; change it with **Change Shortcut…**) toggles a floating panel with chatgpt.com inside.
- The panel opens at the bottom center of the screen, just above the Dock, at 420×560, so chatgpt.com uses its compact layout. It is resizable and movable; the size and position are remembered. It has no title bar, so chatgpt.com fills it to the top edge; to move it, drag the top bar's empty parts (around its buttons, when it's shown with ⌘\), or ⌃⌘-drag anywhere in it. ⌘F maximizes the panel to fill the screen, leaving the menu bar and Dock visible, and restores your size on a second press. ⌘O moves it back to the bottom center, keeping its size.
- The page is zoomed to 90% by default, so text is a little smaller than on chatgpt.com. ⌘− and ⌘= (or ⌘+) zoom out and in, ⌘0 goes back to 90%, and your zoom is remembered. A short message at the top of the panel shows the new zoom (or that it's at 50% or 200% already).
- The panel is just for chats: new, temporary and saved ones, always in Chat mode, never Work. chatgpt.com's sidebar (and its button and ⇧⌘S), the maximized layout's side panel and the Chat/Work switch are gone, and its other pages (GPTs, Library, Codex, projects, help) open in your default browser, also when the page itself moves there (or a chat pop-up does); Back and Forward skip them.
- chatgpt.com's top bar (temporary chat, and in a chat New chat and More) is hidden, so the chat fills the panel. ⌘\ shows or hides it, and your choice is remembered. Shown, it has the chat's title between its buttons, and Share is the first item in its More (…) menu instead of a button of its own. As on chatgpt.com, Share at once makes a public link to the chat and copies it; delete it in chatgpt.com's Settings, Data controls, Shared links. Its main actions have keys anyway: ⌘N and ⇧⌘N for new temporary and saved chats.
- ⌘[ and ⌘] lower and raise the thinking effort (Instant, Medium, High…) without opening the model picker yourself, and a short message shows the new level. They step the effort slider in chatgpt.com's model picker, so they need you signed in and stop working if chatgpt.com changes that picker.
- ⇧⌘F finds text in the chat, in the same find bar as Safari's; Return or ⌘G goes to the next match, ⇧Return or ⇧⌘G to the previous one, and Esc or Done closes it.
- ⇧⌘B (or **Open Chat in Browser** in the menu) opens the saved chat you're in in your default browser and hides the panel, for when a conversation outgrows it. A temporary chat can't be opened elsewhere.
- If you hide the panel while ChatGPT is still answering, the menu-bar icon gets a dot when the answer is done; it goes away when you open the panel.
- It stays on top of other windows and doesn't hide when you click elsewhere. The shortcut, Esc or ⌘W hides it.
- New chats are temporary by default: they don't appear in your chat history (chatgpt.com's Temporary chat). The panel starts on one, and ⌘N opens a new one. For a chat that's saved in your history, press ⇧⌘N (or chatgpt.com's own ⇧⌘O).
- Reopening the panel returns to the conversation you left.
- **Ask About Selection** (⌥⇧Space by default; change it with **Change Shortcut…**): select text in any app and press it. The panel opens with a new temporary chat that has the text in its message box, followed by an empty line for your question; nothing is sent until you send it. Text already typed on the new-chat page stays, before it. A long selection becomes an attachment, as when you paste it into chatgpt.com. With nothing selected, the shortcut just opens the panel. It copies the selection by pressing ⌘C for you and then puts your clipboard back, so it needs Accessibility access (see [Permissions](#permissions)).
- **Ask About Clipboard** (⌥⇧V by default; change it with **Change Shortcut…**, or use the menu item): the same, with the text you've already copied. It needs no Accessibility access, and with no text on the clipboard it just opens the panel and says so.
- Sign in once inside the panel. Sign-in pop-ups, such as Google's "Continue as" card, open in a window of their own that closes when you're done; so do links to chatgpt.com chats that open a new tab. Every other link (sources, websites, openai.com pages, other chatgpt.com pages, email addresses) opens in your default browser or mail app. **Sign Out of Quick Chat…** asks first, then clears the panel's website data.
- Voice works; macOS asks for microphone access the first time.
- It doesn't need the ChatGPT desktop app. If the new app isn't installed, the Show Mini options are simply unavailable and the rest works the same.

#### ChatGPT's own keyboard shortcuts work too

chatgpt.com has built-in keyboard shortcuts, and they all reach the panel. Together they make the panel work almost like a standalone ChatGPT app, without touching the mouse:

| Shortcut | Action |
| --- | --- |
| ⌘K | Switch chat (search your chats) |
| ⇧⌘O | New chat |
| ⌘U | Attach files |
| ⇧⌘⌫ | Delete chat |
| ⌘/ | Show all shortcuts (and change them) |

These come from chatgpt.com's own **Keyboard shortcuts** dialog (⌘/), as of October 2026. Quick Chat only reserves Esc and ⌘W (hide the panel), ⌘N and ⇧⌘N (new temporary chat, new saved chat), ⌘O (move the panel back to the bottom center), ⌘F (maximize or restore the panel), ⌘−, ⌘=, ⌘0 (zoom), ⌘[, ⌘] (thinking effort), ⌘\ (top bar), ⇧⌘F, ⌘G, ⇧⌘G (find) and ⇧⌘B (open in browser), and turns off ⇧⌘S, as there's no sidebar. **Change Shortcut…** won't take any of these fixed keys, the editing keys (⌘C, ⌘V and so on) or chatgpt.com's own shortcuts above.

### Disable Show Mini Shortcut

Unbinds the new ChatGPT app's Show Mini shortcut (⌥Space by default). Mini itself still works from inside the app; only the shortcut is removed.

#### How it interacts with the ChatGPT app's shortcuts

The new ChatGPT app reads its shortcuts from `~/.codex/keybindings.json` (or `$CODEX_HOME/keybindings.json`). To free ⌥Space, Quick Chat adds one entry there:

```json
{"command": "openAvatarOverlay", "key": null}
```

This is the same "unbound" entry the ChatGPT app writes itself when it detects a shortcut clash.

- **Automatic when shortcuts clash.** If Quick Chat's shortcut is the same as Show Mini's, Show Mini is unbound while Quick Chat is on, even if Disable Show Mini Shortcut is off.
- **Restart needed.** ChatGPT reads this file only at launch. Quick Chat offers **Restart ChatGPT to Apply**; it never restarts ChatGPT on its own.
- **Restored on quit.** Turning the features off, or quitting Quick Chat, puts your previous entry back (ChatGPT picks it up at its next restart). A backup in `~/Library/Application Support/ChatGPTCompanion/` restores it on the next launch if Quick Chat crashed.
- If the keymap file isn't valid JSON, Quick Chat leaves it alone.

## Install

**Let an AI assistant walk you through it:** tell Claude, ChatGPT or another assistant
*"Read https://github.com/shuaibird/Quick-Chat/blob/main/INSTALL.md and help me install Quick Chat."*
[INSTALL.md](INSTALL.md) gives it step-by-step instructions for both options below.

### Download (prebuilt)

Get `Quick-Chat-<version>.zip` from the [latest release](https://github.com/shuaibird/Quick-Chat/releases/latest).
It is a universal app (Apple silicon and Intel) and needs macOS 14 Sonoma or later.

1. Double-click the zip to unzip it, then drag **Quick Chat.app** into **Applications**.
   Run it from Applications, not from Downloads.
2. Open Quick Chat. The first time, macOS blocks it with
   *"Apple could not verify 'Quick Chat' is free of malware…"*. Click **Done**.
3. Open **System Settings → Privacy & Security**, scroll down to **Security**, and click
   **Open Anyway** next to "Quick Chat was blocked…". Confirm with **Open Anyway** and your
   login password. The button only appears for about an hour after the blocked launch;
   if it's gone, open the app again first.

   Or, in Terminal, after moving the app to Applications:

   ```sh
   xattr -dr com.apple.quarantine "/Applications/Quick Chat.app"
   ```

Quick Chat then lives in the menu bar (it has no Dock icon).

**Why the warning?** Quick Chat is open source and each release is built by GitHub Actions
from the tagged source, but it isn't signed with an Apple Developer ID or notarized by Apple,
so macOS warns about it like any such app downloaded from the internet. (On macOS 15 and
later, Control-click → Open no longer skips this.) If you'd rather not trust a prebuilt
binary, [build it yourself](#build-from-source).

**Verify the download** (optional): download the matching `.sha256` file to the same folder, then

```sh
cd ~/Downloads && shasum -a 256 -c Quick-Chat-<version>.zip.sha256
```

**Updating:** quit Quick Chat, replace the app in Applications with the new one, and repeat
the Open Anyway step. See [Permissions](#permissions) for why macOS may ask for the
microphone or camera again.

### Build from source

Requirements: macOS 14 or later and Swift 6.0 or later. Xcode 16 or later is recommended
(developed with Xcode 26.3 / Swift 6.2). The Command Line Tools alone (`xcode-select --install`)
can work for single-architecture builds. If `swift build` fails there with "Unknown error parsing
property list", install Xcode. Universal builds (`UNIVERSAL=1`) need Xcode.

```sh
git clone https://github.com/shuaibird/Quick-Chat.git
cd Quick-Chat
make            # build and sign "build/Quick Chat.app"
make run        # build, quit any running copy, open it
make install    # copy to /Applications (or: make install PREFIX=~/Applications)
make uninstall  # remove it again
make clean      # remove .build and build/
```

Apps you build yourself aren't quarantined, so Gatekeeper doesn't block them.

Build options (environment variables for `make` or `scripts/build-app.sh`):

| Variable | Default | Effect |
| --- | --- | --- |
| `CODESIGN_IDENTITY` | first "Apple Development" identity, else ad-hoc | signing identity; `-` forces ad-hoc |
| `UNIVERSAL=1` | off | build for arm64 and x86_64 |
| `VERSION` | latest `v*` git tag, else `0.0.0-dev` | `CFBundleShortVersionString` |
| `BUNDLE_ID` | `dev.shuaibird.quickchat` | bundle identifier |

### Permissions

Only **Ask About Selection** needs **Accessibility** access: it presses ⌘C in the app you're in
to copy the selection (Ask About Clipboard doesn't). The first time you press ⌥⇧Space, macOS asks for it and the panel stays
closed; allow Quick Chat in **System Settings → Privacy & Security → Accessibility**, then press
⌥⇧Space again. Nothing else uses this access, and Quick Chat needs no Automation access. macOS
asks for the **microphone** the first time you use voice, and for the **camera** if you take a
photo or share video.

Release builds, and local builds without an Apple Development certificate, are signed
ad-hoc. macOS identifies an ad-hoc app by the hash of its code, so after every update or
rebuild it treats Quick Chat as a new app and may ask again. To clear stale entries:

```sh
tccutil reset Microphone dev.shuaibird.quickchat
tccutil reset Camera dev.shuaibird.quickchat
tccutil reset Accessibility dev.shuaibird.quickchat
```

A stale Accessibility entry can look switched on in System Settings while ⌥⇧Space does nothing
or opens the panel without the selected text; reset it as above and allow Quick Chat again.

If you build from source, signing with a free Apple Development certificate
(Xcode → Settings → Accounts) keeps the grants across rebuilds. The build script picks it
up automatically.

## Limitations

**It's a web wrapper.**
- It runs chatgpt.com in a web view, not a native ChatGPT client. You sign in separately from any ChatGPT app.
- Google sign-in works only because the panel identifies itself as Safari. Google blocks sign-in from embedded web views and may detect this at any time. Email, Apple or Microsoft sign-in avoid that risk.
- You get the website's interface, not Classic's native chat UI. Your chats are regular ChatGPT conversations in your web history.
- Quick Chat touches up chatgpt.com's browser layout: on macOS 26 and later the panel is Liquid Glass, and the page lets it show through under a light tint of macOS's background color, with a see-through message box and top bar buttons (menus, dialogs and the sliding sidebar stay solid); on earlier versions the page uses macOS's own solid background colors. Both follow ChatGPT's Light/Dark theme and keep your ChatGPT accent color. The space under the message box matches its sides (also on the temporary chat page with a mouse connected, where a reserved scroll bar strip used to push the box off center), a chat's scroll area (and its scroll bar) ends 16px above the message box instead of running behind it, the "ChatGPT can make mistakes" line under a chat and the "For safety…" notice under a temporary chat's message box are hidden (leaving the same space between the last message and the message box), and the top bar is hidden unless you show it with ⌘\. While it's shown, its buttons sit as far from the panel's sides as the chat text and the message box, and a chat scrolls only below them (before macOS 26, the bar gets a solid background instead, so a scrolled chat doesn't show through behind them). When chatgpt.com changes, these touch-ups, the compact layout, focusing the message box, ⌘[ / ⌘], the chat's title in the top bar, Share in the More menu or the answer-ready dot can break.

**Downloads and camera.** Files you download (generated images, exports) are saved straight to ~/Downloads, and the panel says so (click the message to show the file in Finder). Camera capture asks for macOS camera access the first time. Some cases may still fail, such as the right-click "Download Image" item, and `alert()`/`confirm()` dialogs from the site aren't shown.

**It depends on ChatGPT app internals.**
- The Show Mini command id (`openAvatarOverlay`) is undocumented. A ChatGPT update may rename it, and the shortcut handling would stop working until Quick Chat is updated.
- ChatGPT must restart before a shortcut change takes effect.

**The usage benefit may not last.** Chat and Work are expected to move toward one experience. If that brings a shared allowance, Quick Chat loses its main advantage over Mini and becomes just a floating window.

**Ad-hoc signed.** The release isn't signed with an Apple Developer ID or notarized. macOS treats each new build as a different app, so permissions such as microphone access must be granted again after every update.

## Privacy

- Quick Chat has no servers, analytics or telemetry. The panel talks only to chatgpt.com and the sign-in provider you choose; other links open in your default browser.
- Your sign-in session is stored locally in the app's web data. **Sign Out of Quick Chat** deletes it.
- Ask About Clipboard reads your clipboard only when you press it. Ask About Selection briefly keeps a copy of your clipboard in memory, presses ⌘C for you, reads the selection and puts your clipboard back. The selection only goes into the message box. Clipboard managers may still record the copy, and an app that takes over a second to copy leaves the selection on the clipboard.
- Nothing inside the ChatGPT app bundle is modified. The only file Quick Chat changes is the ChatGPT app's own `keybindings.json`, and it restores that file when you turn the features off or quit.

## Not affiliated with OpenAI

Quick Chat is an independent open-source project. It is not affiliated with, endorsed by or sponsored by OpenAI. ChatGPT is a trademark of OpenAI, used here only to describe what the app works with.

## Releasing (maintainers)

The tag is the version. `git tag -a v0.1.0 -m "Quick Chat 0.1.0" && git push origin v0.1.0`
triggers `.github/workflows/release.yml`. It builds a universal, ad-hoc-signed app,
verifies it, and attaches `Quick-Chat-0.1.0.zip` and its `.sha256` to a GitHub release.
Tags with a `-` (e.g. `v0.2.0-beta.1`) become prereleases. To test without releasing, run
the workflow manually (`gh workflow run release.yml -f version=0.1.0-test`); it uploads the
zip as a workflow artifact.

## License

[MIT](LICENSE)
