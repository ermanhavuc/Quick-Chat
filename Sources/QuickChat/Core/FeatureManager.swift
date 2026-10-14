import AppKit

/// Owns all features, persists the user's on/off choice per feature id, and guarantees
/// every feature is disabled (state restored) when the app exits.
@MainActor
final class FeatureManager {
    /// The single place where features are registered. Order = menu order.
    let features: [any Feature]

    init() {
        // Both features share the single owner of ChatGPT's Show Mini keymap entry.
        let showMini = ShowMiniController()
        self.showMini = showMini
        features = [
            QuickChatFeature(showMini: showMini), // core feature, listed first
            DisableShowMiniFeature(showMini: showMini),
        ]
    }

    private let showMini: ShowMiniController
    private let defaults = UserDefaults.standard
    private let log = Log.make("FeatureManager")
    private var signalSources: [DispatchSourceSignal] = []

    private func key(_ id: String) -> String { "feature.\(id).enabled" }

    func isPreferredOn(_ feature: any Feature) -> Bool { defaults.bool(forKey: key(feature.id)) }

    /// Enables every feature the user left switched on last time.
    func start() {
        installSignalHandlers()
        for feature in features where isPreferredOn(feature) {
            enable(feature, persist: false)
        }
        showMini.clearRestartOffer() // restoring last session's state never prompts
    }

    /// User toggled a feature from the menu.
    func toggle(_ feature: any Feature) {
        if feature.isEnabled {
            log.info("Disabling \(feature.id, privacy: .public)")
            feature.disable()
            defaults.set(false, forKey: key(feature.id))
        } else {
            enable(feature, persist: true)
        }
        // Either feature may flip Show Mini's binding, which ChatGPT reads only at launch.
        showMini.offerRestartIfNeeded()
    }

    private func enable(_ feature: any Feature, persist: Bool) {
        log.info("Enabling \(feature.id, privacy: .public)")
        do {
            try feature.enable()
            if persist { defaults.set(true, forKey: key(feature.id)) }
        } catch {
            log.error("Enable \(feature.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            feature.disable() // undo any partial work
            defaults.set(false, forKey: key(feature.id))
            showError(error, feature: feature)
        }
    }

    /// Restores ChatGPT to its untouched state. Does not change persisted preferences,
    /// so features come back on next launch. Safe to call more than once.
    func disableAll() {
        for feature in features where feature.isEnabled {
            log.info("Restoring \(feature.id, privacy: .public) on exit")
            feature.disable()
        }
    }

    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN) // let the dispatch source handle it instead of the default action
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated {
                    self?.log.info("Received signal \(sig), restoring and exiting")
                    self?.disableAll()
                    exit(0)
                }
            }
            source.resume()
            signalSources.append(source)
        }
    }

    private func showError(_ error: Error, feature: any Feature) {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Couldn't enable “\(feature.title)”"
        var info = error.localizedDescription
        if let suggestion = (error as? LocalizedError)?.recoverySuggestion { info += "\n\n" + suggestion }
        alert.informativeText = info
        alert.runModal()
    }
}
