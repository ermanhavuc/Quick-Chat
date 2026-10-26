import AppKit

/// Shared helpers for talking to the new ChatGPT app (Electron, bundle id com.openai.codex).
/// Shared file: feature implementers should not edit it; put feature-specific helpers
/// in their own Features/<Name>/ folder.
@MainActor
enum ChatGPTApp {
    nonisolated static let bundleIdentifier = "com.openai.codex"
    private static let log = Log.make("ChatGPTApp")

    static var runningApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first { !$0.isTerminated }
    }

    static var isRunning: Bool { runningApp != nil }

    /// Location of the installed app, if any.
    static var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    }

    /// Whether the app is installed: LaunchServices knows it (the lookup `launch()` relies on)
    /// and it's still on disk (LaunchServices remembers deleted apps for a while). `~/.codex` is
    /// no sign of it: the Codex CLI uses that folder too.
    static var isInstalled: Bool {
        guard let url = appURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Gracefully quits ChatGPT (if running), waits for it to exit, then relaunches it.
    /// If ChatGPT was not running it is simply launched.
    static func restart(timeout: TimeInterval = 15) async throws {
        if let app = runningApp {
            log.info("Terminating ChatGPT (pid \(app.processIdentifier))")
            app.terminate()
            let deadline = Date().addingTimeInterval(timeout)
            while !app.isTerminated {
                if Date() > deadline {
                    throw FeatureError("ChatGPT did not quit within \(Int(timeout)) seconds.",
                                       recoverySuggestion: "Quit ChatGPT manually and reopen it.")
                }
                try await Task.sleep(for: .milliseconds(200))
            }
        }
        try await launch()
    }

    /// Launches (or activates) ChatGPT.
    @discardableResult
    static func launch(activate: Bool = true) async throws -> NSRunningApplication {
        guard let url = appURL else {
            throw FeatureError("ChatGPT (\(bundleIdentifier)) is not installed.")
        }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = activate
        log.info("Launching ChatGPT at \(url.path, privacy: .public)")
        return try await NSWorkspace.shared.openApplication(at: url, configuration: config)
    }

    /// Opens a URL (e.g. `codex://threads/new?prompt=...`) with the system handler.
    @discardableResult
    static func open(url: URL) -> Bool {
        log.info("Opening URL \(url.absoluteString, privacy: .private)")
        return NSWorkspace.shared.open(url)
    }

    /// Observe ChatGPT launches/terminations. Keep the returned token and pass it to
    /// `removeObserver(_:)` when the feature is disabled.
    static func observeLifecycle(launched: (@MainActor (NSRunningApplication) -> Void)? = nil,
                                 terminated: (@MainActor (NSRunningApplication) -> Void)? = nil) -> [NSObjectProtocol] {
        let center = NSWorkspace.shared.notificationCenter
        var tokens: [NSObjectProtocol] = []
        func add(_ name: Notification.Name, _ block: (@MainActor (NSRunningApplication) -> Void)?) {
            guard let block else { return }
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == bundleIdentifier else { return }
                MainActor.assumeIsolated { block(app) }
            })
        }
        add(NSWorkspace.didLaunchApplicationNotification, launched)
        add(NSWorkspace.didTerminateApplicationNotification, terminated)
        return tokens
    }

    static func removeObservers(_ tokens: [NSObjectProtocol]) {
        tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
    }
}
