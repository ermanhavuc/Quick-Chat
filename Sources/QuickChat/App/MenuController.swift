import AppKit

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

        let header = NSMenuItem(title: "Quick Chat", action: nil, keyEquivalent: "")
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

            if let status = feature.statusText {
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
        menu.addItem(NSMenuItem(title: "Quit Quick Chat",
                                action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: ""))
    }
}
