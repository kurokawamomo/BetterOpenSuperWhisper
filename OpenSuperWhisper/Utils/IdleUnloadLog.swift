import os

/// Diagnostics for idle model unloading. `print` output is lost when the app is
/// launched from the Dock, so these go to the unified log:
/// `log show --last 30m --predicate 'subsystem == "ru.starmel.OpenSuperWhisper" AND category == "IdleUnload"'`
enum IdleUnloadLog {
    static let logger = Logger(subsystem: "ru.starmel.OpenSuperWhisper", category: "IdleUnload")
}
