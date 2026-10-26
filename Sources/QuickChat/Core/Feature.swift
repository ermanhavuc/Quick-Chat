import AppKit

/// A self-contained augmentation of the ChatGPT app.
///
/// Rules for implementers:
/// - `enable()` must be idempotent and throw a descriptive error if it cannot start
///   (the error is shown to the user via an alert, or at launch in the menu, and the feature
///   stays off).
/// - `disable()` must be idempotent, must not throw, and must restore every piece of
///   state the feature changed (files, hotkeys, event taps, windows...). It is called
///   when the user toggles the feature off AND when the app quits
///   (applicationWillTerminate, SIGTERM, SIGINT).
/// - `isEnabled` reflects the feature's *actual* running state, not the user preference
///   (FeatureManager persists the preference separately).
@MainActor
protocol Feature: AnyObject {
    /// Stable identifier, used as the UserDefaults key suffix. Never change it once shipped.
    var id: String { get }
    /// Title of the checkable menu item.
    var title: String { get }
    var isEnabled: Bool { get }

    func enable() throws
    func disable()

    /// Extra items shown (indented) under this feature's checkbox, e.g. "Set Shortcut…".
    /// Called every time the menu opens. Use `ActionMenuItem` for closure-based actions.
    func menuItems() -> [NSMenuItem]

    /// Optional one-line status shown (greyed, indented) under the feature's checkbox.
    /// Re-read every time the menu opens.
    var statusText: String? { get }

    /// Whether the checkbox shows as ticked. Defaults to `isEnabled`; override when the
    /// effect is also forced on by something else (e.g. another feature).
    var isChecked: Bool { get }

    /// Whether the checkbox can be clicked. Defaults to true; return false when the
    /// toggle can't do anything right now (e.g. ChatGPT isn't installed, or it is locked on).
    var canToggle: Bool { get }
}

extension Feature {
    func menuItems() -> [NSMenuItem] { [] }
    var statusText: String? { nil }
    var isChecked: Bool { isEnabled }
    var canToggle: Bool { true }
}

/// Error type features can throw from `enable()` for a readable alert.
struct FeatureError: LocalizedError {
    let message: String
    var recoverySuggestion: String?

    init(_ message: String, recoverySuggestion: String? = nil) {
        self.message = message
        self.recoverySuggestion = recoverySuggestion
    }

    var errorDescription: String? { message }
}
