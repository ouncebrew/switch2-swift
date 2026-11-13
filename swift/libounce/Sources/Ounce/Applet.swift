import COunce

/// The applet lifecycle.
public enum Applet {
    /// False once the system has asked the program to exit, which happens when
    /// the user presses HOME or the console goes to sleep in a way the applet
    /// cannot survive.
    ///
    /// ```swift
    /// while Applet.isRunning {
    ///     // ...
    /// }
    /// ```
    public static var isRunning: Bool {
        ounce_applet_main_loop()
    }
}
