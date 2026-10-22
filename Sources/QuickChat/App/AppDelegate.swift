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
        }
        let controller = MenuController(manager: manager)
        item.menu = controller.menu
        statusItem = item
        menuController = controller

        manager.start()
        NotificationCenter.default.addObserver(self, selector: #selector(unseenAnswerDidChange(_:)),
                                               name: QuickChatController.unseenAnswerDidChange, object: nil)
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
