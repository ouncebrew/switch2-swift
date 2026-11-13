import COunce

/// The libnx text console.
///
/// The console is double buffered: writing to it only fills the buffer, and
/// nothing appears on screen until ``update()`` runs. ``print(_:)`` does both.
///
/// ```swift
/// Console.initialize()
/// Console.print("Hello from Swift")
/// Console.exit()
/// ```
public enum Console {
    /// Initialises the default console. Call once, before anything else.
    public static func initialize() {
        _ = ounce_console_init()
    }

    /// Draws everything written since the last update.
    public static func update() {
        ounce_console_update()
    }

    /// Clears the console buffer.
    public static func clear() {
        ounce_console_clear()
    }

    /// Restores the console and releases it.
    public static func exit() {
        ounce_console_exit()
    }

    /// Writes one line to the buffer without drawing it.
    public static func write(_ line: String) {
        line.withCString { ounce_console_puts($0) }
    }

    /// Writes one line and draws it.
    public static func print(_ line: String) {
        write(line)
        update()
    }
}
