import OSLog

enum AppLog {
    static let transport = Logger(subsystem: "dev.herdr.menubar", category: "transport")
    static let synchronization = Logger(subsystem: "dev.herdr.menubar", category: "synchronization")
    static let systemActions = Logger(subsystem: "dev.herdr.menubar", category: "system-actions")
}
