import Foundation
import os

enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "dev.shuaibird.quickchat"

    static func make(_ category: String) -> Logger {
        Logger(subsystem: subsystem, category: category)
    }

    static let app = make("App")
}
