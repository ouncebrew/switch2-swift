import COunce

/// Which custom firmware, if any, the program is running under.
public enum HosVersion {
    /// True when the program is running under OunceHEN.
    ///
    /// This is the check to make before using ``Hen``: a program started from
    /// the plain homebrew menu has no HEN session to open.
    public static var isOunceHEN: Bool {
        ounce_hosversion_is_ouncehen()
    }
}
