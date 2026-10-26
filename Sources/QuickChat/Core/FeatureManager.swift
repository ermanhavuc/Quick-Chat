import AppKit

/// Owns all features, persists the user's on/off choice per feature id, and guarantees
/// every feature is disabled (state restored) when the app exits.
@MainActor
final class FeatureManager {
    /// The single place where features are registered. Order = menu order.
    let features: [any Feature]

    convenience init() {
        // Both features share the single owner of ChatGPT's Show Mini keymap entry.
        let showMini = ShowMiniController()
        self.init(features: [
            QuickChatFeature(showMini: showMini), // core feature, listed first
            DisableShowMiniFeature(showMini: showMini),
        ], showMini: showMini)
    }

    /// `defaults`: where the on/off choices live (replaceable for the self-tests).
    init(features: [any Feature], showMini: ShowMiniController, defaults: UserDefaults = .standard) {
        self.features = features
        self.showMini = showMini
        self.defaults = defaults
    }

    private let showMini: ShowMiniController
    private let defaults: UserDefaults
    private let log = Log.make("FeatureManager")
    private var signalSources: [DispatchSourceSignal] = []
    /// Why a feature that was on last time couldn't start at launch, by feature id.
    private var launchFailures: [String: String] = [:]

    private func key(_ id: String) -> String { "feature.\(id).enabled" }

    func isPreferredOn(_ feature: any Feature) -> Bool { defaults.bool(forKey: key(feature.id)) }

    /// The Quick Chat feature, for the menu-bar icon's click.
    var quickChat: QuickChatFeature? { features.lazy.compactMap { $0 as? QuickChatFeature }.first }

    /// Why `feature` couldn't start at launch, for the menu; nil once it's toggled.
    func launchFailure(of feature: any Feature) -> String? { launchFailures[feature.id] }

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
        launchFailures[feature.id] = nil
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

    /// `persist`: the user turned it on (save the choice; say so in an alert if it can't start).
    /// Otherwise it's launch, restoring last time's choice: one that can't start now stays
    /// chosen, so the next launch tries again, and the menu says why rather than an alert at login.
    private func enable(_ feature: any Feature, persist: Bool) {
        log.info("Enabling \(feature.id, privacy: .public)")
        do {
            try feature.enable()
            if persist { defaults.set(true, forKey: key(feature.id)) }
        } catch {
            log.error("Enable \(feature.id, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            feature.disable() // undo any partial work
            if persist {
                defaults.set(false, forKey: key(feature.id))
                showError(error, feature: feature)
            } else {
                launchFailures[feature.id] = "Couldn't start: \(error.localizedDescription)"
            }
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
