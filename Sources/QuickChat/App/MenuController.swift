import AppKit
import ServiceManagement

/// Builds the status-item menu. Rebuilt every time it opens so feature state/status stay fresh.
///
/// Layout per feature:
///   [✓] <feature.title>
///         <feature.statusText>          (greyed, if non-nil)
///         <feature.menuItems()...>      (indented)
@MainActor
final class MenuController: NSObject, NSMenuDelegate {
    let menu = NSMenu()
    private let manager: FeatureManager

    init(manager: FeatureManager) {
        self.manager = manager
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        rebuild()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { rebuild() }

    private func rebuild() {
        menu.removeAllItems()

        let header = NSMenuItem(title: Self.nameAndVersion, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        for (index, feature) in manager.features.enumerated() {
            if index > 0 { menu.addItem(.separator()) }

            let toggle = ActionMenuItem(feature.title) { [weak self] in
                self?.manager.toggle(feature)
            }
            toggle.state = feature.isChecked ? .on : .off
            toggle.isEnabled = feature.canToggle
            menu.addItem(toggle)

            if let status = manager.launchFailure(of: feature) ?? feature.statusText {
                let item = NSMenuItem(title: status, action: nil, keyEquivalent: "")
                item.isEnabled = false
                item.indentationLevel = 1
                menu.addItem(item)
            }

            for item in feature.menuItems() {
                item.indentationLevel = max(item.indentationLevel, 1)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        let launchAtLogin = ActionMenuItem("Launch at Login") { [weak self] in self?.toggleLaunchAtLogin() }
        launchAtLogin.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(launchAtLogin)
        menu.addItem(NSMenuItem(title: "Quit Quick Chat",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: ""))
    }

    /// "Quick Chat 0.2.0 (49)", or just the name where there's no version (a debug build).
    private static var nameAndVersion: String {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let version = info["CFBundleShortVersionString"] as? String else { return "Quick Chat" }
        let build = (info["CFBundleVersion"] as? String).map { " (\($0))" } ?? ""
        return "Quick Chat \(version)\(build)"
    }

    /// Adds Quick Chat to, or removes it from, macOS's login items. If macOS wants the user to
    /// approve it first (e.g. it was switched off in System Settings), opens Login Items there.
    private func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
            Log.app.info("Launch at Login: \(service.status == .enabled ? "on" : "off", privacy: .public)")
        } catch {
            Log.app.error("Launch at Login: \(error.localizedDescription, privacy: .public)")
            NSApp.activate()
            NSAlert(error: error).runModal()
        }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}
