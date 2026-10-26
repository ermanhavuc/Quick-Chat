import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let manager = FeatureManager()
    private var statusItem: NSStatusItem?
    private var menuController: MenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("QuickChat launched")

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = MenuBarIcon.make()
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        let controller = MenuController(manager: manager)
        statusItem = item
        menuController = controller

        manager.start()
        NotificationCenter.default.addObserver(self, selector: #selector(unseenAnswerDidChange(_:)),
                                               name: QuickChatController.unseenAnswerDidChange, object: nil)
    }

    /// A click on the menu-bar icon shows or hides the Quick Chat panel; a right-click or
    /// ⌃-click shows the menu, as does any click while Quick Chat is off.
    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        let wantsMenu = event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true
        if !wantsMenu, let quickChat = manager.quickChat, quickChat.isEnabled {
            quickChat.togglePanel()
        } else {
            showMenu()
        }
    }

    /// Opens the menu under the icon. It's attached only meanwhile: an attached menu would take
    /// every click.
    private func showMenu() {
        guard let statusItem, let menuController else { return }
        statusItem.menu = menuController.menu
        statusItem.button?.performClick(nil) // returns once the menu has closed
        statusItem.menu = nil
    }

    /// A dot on the icon while Quick Chat has an answer you haven't seen (it finished while the
    /// panel was hidden).
    @objc private func unseenAnswerDidChange(_ notification: Notification) {
        let unseen = (notification.object as? QuickChatController)?.hasUnseenAnswer == true
        statusItem?.button?.image = MenuBarIcon.make(dot: unseen)
        statusItem?.button?.toolTip = unseen ? "Quick Chat: your answer is ready" : nil
    }

    func applicationWillTerminate(_ notification: Notification) {
        Log.app.info("QuickChat terminating; restoring ChatGPT state")
        manager.disableAll()
    }
}
