import COunce

/// HEN's status, from `henGetStatus`.
public struct HenStatus: Sendable {
    /// HEN's process ID.
    public let processID: UInt64

    /// The version of HEN's protocol. `HEN_PROTOCOL_VERSION` is 5.
    public let protocolVersion: UInt32

    /// The result of HEN's own startup. Success means HEN is healthy.
    public let initializationResult: ResultCode
}

/// A session with OunceHEN.
///
/// A program started from hbloader gets RO's `ldr:ro` session as a service
/// override, and opens a HEN homebrew session through it. A program started
/// from the plain homebrew menu has no such override, so ``init()`` throws.
/// Check ``isAvailable`` first if that is a normal case for your program.
///
/// ```swift
/// guard Hen.isAvailable else {
///     Console.print("Not running under OunceHEN")
///     return
/// }
///
/// let hen = try Hen()
/// let status = try hen.status
/// Console.print("HEN protocol \(status.protocolVersion)")
/// ```
///
/// The session is closed when the object is released.
public final class Hen {
    private var service = Service()
    private var isOpen = false

    /// True when the program is running under OunceHEN.
    public static var isAvailable: Bool {
        HosVersion.isOunceHEN
    }

    /// Opens a HEN homebrew session.
    ///
    /// Throws when the program did not start from hbloader, because there is
    /// no `ldr:ro` override to open the session through.
    public init() throws {
        var opened = Service()
        let rc = ounce_hen_open(&opened)

        guard ounce_result_succeeded(rc) else {
            throw OunceError("opening a HEN session", rc)
        }

        service = opened
        isOpen = true
    }

    deinit {
        close()
    }

    /// Closes the session. Calling it twice is harmless; the object is
    /// unusable afterwards.
    public func close() {
        guard isOpen else { return }
        ounce_service_close(&service)
        isOpen = false
    }

    /// HEN's status.
    public var status: HenStatus {
        get throws {
            var raw = COunce.HenStatus()
            let rc = ounce_hen_status(&service, &raw)

            guard ounce_result_succeeded(rc) else {
                throw OunceError("reading HEN status", rc)
            }

            return HenStatus(
                processID: raw.process_id,
                protocolVersion: raw.protocol_version,
                initializationResult: ResultCode(raw.initialization_result)
            )
        }
    }

    /// A new clone of HEN's filesystem proxy root session.
    ///
    /// The caller owns the returned handle and must close it.
    public func filesystemRoot() throws -> UInt32 {
        try handle("getting HEN's filesystem root") { ounce_hen_filesystem_root(&service, $0) }
    }

    /// A new clone of HEN's `set:sys` session.
    ///
    /// The caller owns the returned handle and must close it.
    public func settingsSession() throws -> UInt32 {
        try handle("getting HEN's settings session") { ounce_hen_settings_session(&service, $0) }
    }

    /// A copy of this program's process handle.
    ///
    /// The caller owns the returned handle and must close it.
    public func processHandle() throws -> UInt32 {
        try handle("getting the process handle") { ounce_hen_process_handle(&service, $0) }
    }

    /// A borrowed service-manager session, by copy.
    ///
    /// The caller owns the kernel handle but must not send SM Initialize or
    /// Close on this session.
    public func serviceManager() throws -> UInt32 {
        try handle("getting HEN's service manager") { ounce_hen_service_manager(&service, $0) }
    }

    private func handle(_ operation: String,
                        _ call: (UnsafeMutablePointer<UInt32>) -> UInt32) throws -> UInt32 {
        var value: UInt32 = 0
        let rc = call(&value)

        guard ounce_result_succeeded(rc) else {
            throw OunceError(operation, rc)
        }
        return value
    }
}
