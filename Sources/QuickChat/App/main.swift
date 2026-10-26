import AppKit

MainActor.assumeIsolated {
    #if DEBUG
    if let suite = ProcessInfo.processInfo.environment["QUICKCHAT_SELFTEST"], ["keymap", "showmini"].contains(suite) {
        exit(KeymapSelfTest.run() ? 0 : 1)
    }
    if ProcessInfo.processInfo.environment["QUICKCHAT_SELFTEST"] == "panel" {
        NSApplication.shared.setActivationPolicy(.accessory)
        exit(PanelSelfTest.run() ? 0 : 1)
    }
    if ProcessInfo.processInfo.environment["QUICKCHAT_SELFTEST"] == "feature" {
        NSApplication.shared.setActivationPolicy(.accessory)
        EditMenu.install()
        exit(FeatureSelfTest.run() ? 0 : 1)
    }
    // Opens Quick Chat panel without enabling any feature (no keymap changes).
    if ProcessInfo.processInfo.environment["QUICKCHAT_DEBUG"] == "panel" {
        NSApplication.shared.setActivationPolicy(.accessory) // creates NSApp, which EditMenu needs
        EditMenu.install()
        let chat = QuickChatController()
        DispatchQueue.main.async { chat.show() }
        withExtendedLifetime(chat) { NSApplication.shared.run() }
    }
    #endif

    LegacyCleanup.run()

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory) // menu-bar only (LSUIElement is also set in Info.plist)
    EditMenu.install()
    withExtendedLifetime(delegate) { app.run() }
}
