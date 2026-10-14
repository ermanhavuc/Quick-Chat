import Foundation

/// One-time cleanups of state left by earlier versions. Runs before features start.
@MainActor
enum LegacyCleanup {
    private static let log = Log.make("LegacyCleanup")

    static func run() {
        restoreCodexPopoutBinding()
        migratePreferences()
    }

    /// The removed Codex hand-off bound ChatGPT's Popout Window (`hotkeyWindow`) to a hidden
    /// `Control+Alt+Shift+F19`. Put the user's previous entry back and drop its state file.
    private static func restoreCodexPopoutBinding() {
        let popout = KeymapOverride(target: .init(commandID: "hotkeyWindow", key: "Control+Alt+Shift+F19",
                                                  displayName: "Popout Window", stateName: "PopoutWindow"))
        guard FileManager.default.fileExists(atPath: popout.stateURL.path) else { return }
        do {
            let outcome = try popout.restore()
            log.info("Restored legacy Popout Window binding (\(String(describing: outcome), privacy: .public))")
            try FileManager.default.removeItem(at: popout.stateURL)
        } catch {
            log.error("Legacy Popout cleanup failed; will retry next launch: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// "Replace Mini" (Mini Chat + Codex) became "ChatGPT Mini Chat".
    private static func migratePreferences() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "feature.replaceMini.enabled") != nil {
            if defaults.object(forKey: "feature.miniChat.enabled") == nil {
                defaults.set(defaults.bool(forKey: "feature.replaceMini.enabled"), forKey: "feature.miniChat.enabled")
            }
            defaults.removeObject(forKey: "feature.replaceMini.enabled")
        }
        if let data = defaults.data(forKey: "replaceMini.shortcut") {
            if defaults.object(forKey: "miniChat.shortcut") == nil { defaults.set(data, forKey: "miniChat.shortcut") }
            defaults.removeObject(forKey: "replaceMini.shortcut")
        }
        for stale in ["feature.chatBar.enabled", "feature.popoutWindow.enabled", "KeyboardShortcuts_toggleChatBar"] {
            defaults.removeObject(forKey: stale)
        }
    }
}
