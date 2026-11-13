import COunce

/// A set of controller buttons.
///
/// The raw values are libnx's `HidNpadButton_*`, which are `1 << n`.
public struct Button: OptionSet, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    public static let a = Button(rawValue: 1 << 0)
    public static let b = Button(rawValue: 1 << 1)
    public static let x = Button(rawValue: 1 << 2)
    public static let y = Button(rawValue: 1 << 3)
    public static let stickL = Button(rawValue: 1 << 4)
    public static let stickR = Button(rawValue: 1 << 5)
    public static let l = Button(rawValue: 1 << 6)
    public static let r = Button(rawValue: 1 << 7)
    public static let zl = Button(rawValue: 1 << 8)
    public static let zr = Button(rawValue: 1 << 9)
    public static let plus = Button(rawValue: 1 << 10)
    public static let minus = Button(rawValue: 1 << 11)
    public static let left = Button(rawValue: 1 << 12)
    public static let up = Button(rawValue: 1 << 13)
    public static let right = Button(rawValue: 1 << 14)
    public static let down = Button(rawValue: 1 << 15)

    /// The left stick pushed far enough to count as a direction.
    public static let stickLLeft = Button(rawValue: 1 << 16)
    public static let stickLUp = Button(rawValue: 1 << 17)
    public static let stickLRight = Button(rawValue: 1 << 18)
    public static let stickLDown = Button(rawValue: 1 << 19)

    /// The right stick pushed far enough to count as a direction.
    public static let stickRLeft = Button(rawValue: 1 << 20)
    public static let stickRUp = Button(rawValue: 1 << 21)
    public static let stickRRight = Button(rawValue: 1 << 22)
    public static let stickRDown = Button(rawValue: 1 << 23)

    /// SL and SR on a detached Joy-Con.
    public static let leftSL = Button(rawValue: 1 << 24)
    public static let leftSR = Button(rawValue: 1 << 25)
    public static let rightSL = Button(rawValue: 1 << 26)
    public static let rightSR = Button(rawValue: 1 << 27)
}

/// An analog stick position, in libnx's raw units.
public struct Stick: Sendable {
    public let x: Int32
    public let y: Int32

    public init(x: Int32, y: Int32) {
        self.x = x
        self.y = y
    }
}

/// Controller input.
///
/// Call ``update()`` once per frame before reading anything; every accessor
/// reports the state as of the last update.
///
/// ```swift
/// let pad = Pad()
/// while Applet.isRunning {
///     pad.update()
///     if pad.buttonsDown.contains(.plus) { break }
/// }
/// ```
public final class Pad {
    private var state = PadState()

    /// Initialises the pad to read from the default input sources.
    public init() {
        ounce_pad_init_default(&state)
    }

    /// Reads the current state. Call once per frame.
    public func update() {
        ounce_pad_update(&state)
    }

    /// Every button currently held.
    public var buttons: Button {
        Button(rawValue: ounce_pad_buttons(&state))
    }

    /// Buttons that went down since the previous update.
    public var buttonsDown: Button {
        Button(rawValue: ounce_pad_buttons_down(&state))
    }

    /// Buttons that came up since the previous update.
    public var buttonsUp: Button {
        Button(rawValue: ounce_pad_buttons_up(&state))
    }

    /// Whether any controller is connected.
    public var isConnected: Bool {
        ounce_pad_connected(&state)
    }

    /// The position of a stick. Index 0 is the left stick, 1 the right.
    public func stick(_ index: Int) -> Stick {
        let position = ounce_pad_stick(&state, UInt32(index))
        return Stick(x: position.x, y: position.y)
    }
}
