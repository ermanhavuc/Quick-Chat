import AppKit
import ApplicationServices

@MainActor
enum Permissions {
    /// Whether this process is trusted for Accessibility (AX API, posting CGEvents, event taps).
    static var isAccessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Checks trust and, if `prompt` is true and not trusted, shows the system prompt.
    @discardableResult
    static func checkAccessibility(prompt: Bool) -> Bool {
        // "AXTrustedCheckOptionPrompt" == kAXTrustedCheckOptionPrompt (avoids a Swift 6 global-var warning).
        let options = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    enum Pane: String {
        case accessibility = "Privacy_Accessibility"
        case automation = "Privacy_Automation"
        case inputMonitoring = "Privacy_ListenEvent"
    }

    static func openSettings(_ pane: Pane) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane.rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}
