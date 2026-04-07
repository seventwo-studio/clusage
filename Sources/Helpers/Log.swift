import OSLog

enum Log {
    static let subsystem = "studio.seventwo.clusage"

    static let api = Logger(subsystem: subsystem, category: "api")
    static let keychain = Logger(subsystem: subsystem, category: "keychain")
    static let accounts = Logger(subsystem: subsystem, category: "accounts")
    static let poller = Logger(subsystem: subsystem, category: "poller")
    static let history = Logger(subsystem: subsystem, category: "history")
    static let widget = Logger(subsystem: subsystem, category: "widget")
    static let app = Logger(subsystem: subsystem, category: "app")
    static let momentum = Logger(subsystem: subsystem, category: "momentum")
    static let pattern = Logger(subsystem: subsystem, category: "pattern")
    static let update = Logger(subsystem: subsystem, category: "update")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    static let tokens = Logger(subsystem: subsystem, category: "tokens")
}
