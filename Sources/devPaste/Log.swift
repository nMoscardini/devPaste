import os

/// Structured logs with stable event names (principle 8). Never log clipboard content.
/// Read with: log stream --predicate 'subsystem == "com.nino.devPaste"'
enum Log {
    static let capture = Logger(subsystem: "com.nino.devPaste", category: "capture")
    static let paste = Logger(subsystem: "com.nino.devPaste", category: "paste")
    static let store = Logger(subsystem: "com.nino.devPaste", category: "store")
    static let app = Logger(subsystem: "com.nino.devPaste", category: "app")
}
