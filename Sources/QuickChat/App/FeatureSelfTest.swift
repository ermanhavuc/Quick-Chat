#if DEBUG
import AppKit
import Carbon.HIToolbox

/// Self-test of turning features on and off and of the menu (registers global shortcuts and
/// opens windows, so it needs a GUI session):
///   QUICKCHAT_SELFTEST=feature .build/debug/QuickChat
/// Works on temp directories and a throwaway defaults suite; never touches ~/.codex. The
/// shortcuts it registers are F17–F19 with ⌃⌥⇧⌘, which no one else uses.
@MainActor
enum FeatureSelfTest {
    private static var failures = 0

    private static func check(_ cond: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if cond { print("  ok   \(name)") } else { failures += 1; print("  FAIL \(name) \(detail())") }
    }

    /// A feature that can't start, as when another app holds its shortcut.
    private final class FailingFeature: Feature {
        let id = "selfTestFailing"
        let title = "Failing"
        private(set) var isEnabled = false
        func enable() throws { throw FeatureError("its shortcut is taken") }
        func disable() { isEnabled = false }
    }

    static func run() -> Bool {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("feature-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        setenv("CODEX_HOME", root.appendingPathComponent("codex-home").path, 1) // safety net, as in the keymap self-test
        func showMini(_ name: String) -> ShowMiniController {
            let keymap = KeymapOverride(target: ShowMiniController.target,
                                        keymapURL: root.appendingPathComponent("\(name)/codex/keybindings.json"),
                                        stateURL: root.appendingPathComponent("\(name)/state/DisableShowMini.json"))
            return ShowMiniController(keymap: keymap, isChatGPTInstalled: { false })
        }

        print("1. a feature that was on but can't start at launch stays on for the next launch")
        let suite = "QuickChat.FeatureSelfTest.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "feature.selfTestFailing.enabled")
        let failing = FailingFeature()
        let manager = FeatureManager(features: [failing], showMini: showMini("manager"), defaults: defaults)
        manager.start()
        check(!failing.isEnabled, "it's off")
        check(manager.isPreferredOn(failing), "still chosen, so the next launch tries again")
        check(manager.launchFailure(of: failing) == "Couldn't start: its shortcut is taken", "the menu says why",
              manager.launchFailure(of: failing) ?? "nothing")

        print("2. turning Quick Chat off with Change Shortcut… open leaves no shortcut registered")
        let saved = (Shortcut.load(), Shortcut.loadAsk(), Shortcut.loadAskClipboard())
        defer {
            saved.0.save()
            saved.1.saveAsAsk()
            saved.2.saveAsAskClipboard()
        }
        let all = UInt32(cmdKey | optionKey | controlKey | shiftKey)
        let test = [kVK_F17, kVK_F18, kVK_F19].map { Shortcut(keyCode: UInt32($0), carbonModifiers: all) }
        test[0].save()
        test[1].saveAsAsk()
        test[2].saveAsAskClipboard()
        let feature = QuickChatFeature(showMini: showMini("feature"))
        do {
            try feature.enable()
            check(feature.isEnabled && feature.registeredHotKeyCount == 3, "on: its three shortcuts registered",
                  "\(feature.registeredHotKeyCount)")
            feature.openShortcutsForSelfTest()
            check(NSApp.windows.contains { $0.title == "Quick Chat Shortcuts" && $0.isVisible }, "Change Shortcut… is open")
            feature.disable()
            check(!feature.isEnabled && feature.registeredHotKeyCount == 0, "off: no shortcut registered",
                  "\(feature.registeredHotKeyCount) registered")
            check(!NSApp.windows.contains { $0.title == "Quick Chat Shortcuts" && $0.isVisible }, "Change Shortcut… closed")
            check(Shortcut.load() == test[0], "the shortcuts are kept")

            feature.openShortcutsForSelfTest() // opened while off
            try feature.enable()
            check(!NSApp.windows.contains { $0.title == "Quick Chat Shortcuts" && $0.isVisible } && feature.registeredHotKeyCount == 3,
                  "turned on with Change Shortcut… open: it closes, then the shortcuts are registered", "\(feature.registeredHotKeyCount)")
            feature.disable()
        } catch {
            check(false, "enabling threw", "\(error)")
        }

        print("3. the menu: Change Shortcut… also while Quick Chat is off; its panel keys")
        let offItems = feature.menuItems().map(\.title)
        check(offItems.count == 1 && offItems[0].hasPrefix("Change Shortcut…"), "off: just Change Shortcut…", "\(offItems)")
        check(Shortcut.commandO.menuKeyEquivalent.map { $0.key == "o" && $0.modifiers == .command } == true, "⌘O shows as ⌘O")
        check(Shortcut.optionSpace.menuKeyEquivalent.map { $0.key == " " && $0.modifiers == .option } == true, "⌥Space shows as ⌥Space")
        check(test[2].menuKeyEquivalent?.key == String(Character(UnicodeScalar(UInt32(NSF19FunctionKey))!)), "F19 shows as F19")
        check(Shortcut(keyCode: 0x7F, carbonModifiers: UInt32(cmdKey)).menuKeyEquivalent == nil, "a key a menu can't show: none")

        print("4. the panel moves to the display you're on, keeping its place")
        let small = NSRect(x: 0, y: 0, width: 1440, height: 875)
        let large = NSRect(x: 1440, y: 25, width: 2560, height: 1390)
        let panel = NSSize(width: 420, height: 560)
        func moved(_ x: CGFloat, _ y: CGFloat, _ size: NSSize = panel) -> NSRect {
            QuickChatPanel.frame(NSRect(origin: NSPoint(x: x, y: y), size: size), movedFrom: small, to: large)
        }
        check(moved(510, 16) == NSRect(x: 2510, y: 41, width: 420, height: 560),
              "bottom center (16 pt up) → bottom center (16 pt up)", "\(moved(510, 16))")
        check(moved(1000, 285) == NSRect(x: 3560, y: 825, width: 420, height: 560),
              "20 pt from the right, 30 pt from the top → the same", "\(moved(1000, 285))")
        check(moved(20, 100).minX == 1460, "20 pt from the left → the same", "\(moved(20, 100))")
        check(QuickChatPanel.frame(NSRect(x: 1540, y: 75, width: 420, height: 1300), movedFrom: large, to: small)
              == NSRect(x: 100, y: 0, width: 420, height: 875), "taller than the screen: shrunk to fit, inside it")

        print(failures == 0 ? "feature self-test: ALL PASSED" : "feature self-test: \(failures) FAILED")
        return failures == 0
    }
}
#endif
