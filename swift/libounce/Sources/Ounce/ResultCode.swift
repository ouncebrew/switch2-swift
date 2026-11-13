import COunce

/// A libnx result code.
///
/// libnx packs a module, a description and a value into one `u32`, and treats
/// zero as success. `R_SUCCEEDED` is `(res) == 0`, so there is no sign bit to
/// test.
public struct ResultCode: RawRepresentable, Equatable, Hashable, Sendable {
    public var rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public init(_ raw: UInt32) {
        self.rawValue = raw
    }

    /// True when the call succeeded.
    public var isSuccess: Bool {
        ounce_result_succeeded(rawValue)
    }

    /// The module that produced the result, from `R_MODULE`.
    public var module: UInt32 {
        rawValue & 0x1FF
    }

    /// The description within the module, from `R_DESCRIPTION`.
    public var descriptionCode: UInt32 {
        (rawValue >> 9) & 0x1FFF
    }

    /// The value, from `R_VALUE`.
    public var value: UInt32 {
        rawValue & 0x3F_FFFF
    }
}

extension ResultCode: CustomStringConvertible {
    public var description: String {
        if isSuccess {
            return "success"
        }
        return "\(hex(rawValue)) (module \(module), description \(descriptionCode), value \(value))"
    }
}

/// An error carrying the libnx result code of the call that failed.
public struct OunceError: Error, CustomStringConvertible {
    /// The result code.
    public let code: ResultCode

    /// What was being attempted, for the message.
    public let operation: String

    public init(_ operation: String, _ code: UInt32) {
        self.operation = operation
        self.code = ResultCode(code)
    }

    public var description: String {
        "\(operation) failed: \(code)"
    }
}

/// Formats a value as eight uppercase hex digits.
///
/// `String(format:)` is Foundation, which this port does not have.
func hex(_ value: UInt32) -> String {
    let digits = String(value, radix: 16, uppercase: true)
    return "0x" + String(repeating: "0", count: max(0, 8 - digits.count)) + digits
}
