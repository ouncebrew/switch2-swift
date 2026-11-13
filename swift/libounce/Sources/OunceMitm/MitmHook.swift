import COunceMitm
import Ounce

/// The context passed to a hook handler.
///
/// The pointer refers to the framework's own context and is only valid for the
/// duration of the handler call.
public struct MitmHookContext {
    let pointer: UnsafeMutablePointer<COunceMitm.MitmHookContext>

    /// The interface the request was routed to.
    public var interface: UInt32 { pointer.pointee.interface }

    /// The command ID within ``interface``.
    public var commandID: UInt32 { pointer.pointee.command_id }

    /// The CMIF domain object ID, or 0 for the root.
    public var objectID: UInt32 { pointer.pointee.object_id }

    /// The TIPC object session, or ``MitmService/invalidHandle`` for the root.
    public var session: Handle { pointer.pointee.session }

    /// The user pointer from the hook entry.
    public var user: UnsafeMutableRawPointer? { pointer.pointee.user }

    /// The user pointer from the tracked object or session.
    public var objectUser: UnsafeMutableRawPointer? { pointer.pointee.object_user }

    /// True once ``beginResponse(result:payloadSize:numHandles:)`` has run.
    public var responded: Bool { pointer.pointee.responded }

    /// The session the request arrived on.
    public var service: MitmService? {
        guard let raw = pointer.pointee.service else { return nil }
        return MitmService(borrowing: raw.pointee)
    }

    /// Builds a response for this request.
    ///
    /// - Returns: The payload area, and the handle array to fill when
    ///   `numHandles` is not zero.
    public func beginResponse(result: ResultCode, payloadSize: Int = 0,
                              numHandles: Int = 0)
        -> (payload: UnsafeMutableRawPointer?, handles: UnsafeMutablePointer<Handle>?) {
        var handles: UnsafeMutablePointer<Handle>?
        let payload = mitmHookBeginResponse(pointer, result.rawValue,
                                            UInt32(payloadSize),
                                            UInt32(numHandles), &handles)
        return (payload, handles)
    }

    /// Hands the client a session of its own and tracks it under `interface`.
    public func returnSession(interface: UInt32, user: UnsafeMutableRawPointer? = nil,
                              forward: Handle) throws {
        let rc = mitmHookReturnSession(pointer, interface, user, forward)
        guard ounce_result_succeeded(rc) else {
            throw OunceError("returning a session", rc)
        }
    }

    /// Proxies an object the real service returned, tracking it under
    /// `interface`.
    public func proxyObject(interface: UInt32,
                            user: UnsafeMutableRawPointer? = nil) throws {
        let rc = mitmHookProxyObject(pointer, interface, user)
        guard ounce_result_succeeded(rc) else {
            throw OunceError("proxying an object", rc)
        }
    }
}

/// A Swift hook handler.
///
/// Return ``MitmHookTable/forwardToSession`` to have the framework forward the
/// request verbatim to the real service. Returning anything else answers the
/// client with that result, unless the handler already called
/// ``MitmHookContext/beginResponse(result:payloadSize:numHandles:)``.
public typealias MitmHookHandler = (MitmHookContext) -> ResultCode

private final class MitmHandlerBox {
    let body: MitmHookHandler

    init(_ body: @escaping MitmHookHandler) {
        self.body = body
    }
}

private let mitmHandlerTrampoline: @convention(c)
    (UnsafeMutablePointer<COunceMitm.MitmHookContext>?, UnsafeMutableRawPointer?) -> UInt32 = { context, user in
        guard let context, let user else {
            return ounce_mitmErrorHookNotSupported()
        }
        let box = Unmanaged<MitmHandlerBox>.fromOpaque(user).takeUnretainedValue()
        return box.body(MitmHookContext(pointer: context)).rawValue
    }

/// The storage a hook table is built on.
///
/// The framework keeps raw pointers into these arrays, so they are allocated
/// once and never moved.
final class MitmHookStorage {
    let entries: UnsafeMutablePointer<COunceMitm.MitmHookEntry>
    let objects: UnsafeMutablePointer<COunceMitm.MitmHookObject>
    let sessions: UnsafeMutablePointer<COunceMitm.MitmHookSession>
    let entryCapacity: Int
    let objectCapacity: Int
    let sessionCapacity: Int

    init(entryCapacity: Int, objectCapacity: Int, sessionCapacity: Int) {
        self.entryCapacity = entryCapacity
        self.objectCapacity = objectCapacity
        self.sessionCapacity = sessionCapacity

        entries = .allocate(capacity: entryCapacity)
        entries.initialize(repeating: COunceMitm.MitmHookEntry(), count: entryCapacity)
        objects = .allocate(capacity: objectCapacity)
        objects.initialize(repeating: COunceMitm.MitmHookObject(), count: objectCapacity)
        sessions = .allocate(capacity: sessionCapacity)
        sessions.initialize(repeating: COunceMitm.MitmHookSession(), count: sessionCapacity)
    }

    deinit {
        entries.deinitialize(count: entryCapacity)
        entries.deallocate()
        objects.deinitialize(count: objectCapacity)
        objects.deallocate()
        sessions.deinitialize(count: sessionCapacity)
        sessions.deallocate()
    }

    var config: COunceMitm.MitmHookConfig {
        COunceMitm.MitmHookConfig(entries: entries,
                                  entry_capacity: UInt32(entryCapacity),
                                  objects: objects,
                                  object_capacity: UInt32(objectCapacity),
                                  sessions: sessions,
                                  session_capacity: UInt32(sessionCapacity))
    }
}

/// A table mapping (interface, command) pairs to handlers.
///
/// The table owns its storage and the sessions it serves. Handlers are Swift
/// closures; the framework calls them through a C trampoline.
public final class MitmHookTable {
    /// The result a handler returns to have the request forwarded verbatim.
    public static let forwardToSession = ResultCode(ounce_mitmResultForwardToSession())

    let storage: MitmHookStorage
    private var boxes: [UnsafeMutableRawPointer] = []
    private var raw = COunceMitm.MitmHookTable()

    /// Creates a table.
    public init(entryCapacity: Int = 64, objectCapacity: Int = 64,
                sessionCapacity: Int = Int(MITM_HOOK_MAX_SESSIONS)) {
        storage = MitmHookStorage(entryCapacity: entryCapacity,
                                  objectCapacity: objectCapacity,
                                  sessionCapacity: sessionCapacity)
        var config = storage.config
        _ = mitmHookTableInit(&raw, &config)
        ounce_mitmSetHandler(mitmHandlerTrampoline)
    }

    deinit {
        for box in boxes {
            Unmanaged<MitmHandlerBox>.fromOpaque(box).release()
        }
    }

    /// Installs a handler for one (interface, command) pair.
    public func install(interface: UInt32, command: UInt32,
                        handler: @escaping MitmHookHandler) throws {
        try withRaw { table in
            let box = Unmanaged.passRetained(MitmHandlerBox(handler)).toOpaque()
            let rc = mitmHookInstall(table, interface, command,
                                     ounce_mitmHandlerTrampoline(), box)
            guard ounce_result_succeeded(rc) else {
                Unmanaged<MitmHandlerBox>.fromOpaque(box).release()
                throw OunceError("installing a hook", rc)
            }
            boxes.append(box)
        }
    }

    /// Removes the handler for one (interface, command) pair.
    public func uninstall(interface: UInt32, command: UInt32) {
        withRaw { mitmHookUninstall($0, interface, command) }
    }

    /// Dispatches one request that is already in the thread's TLS buffer.
    public func dispatch(_ service: MitmService) throws {
        let rc = withRaw { table in
            service.withRaw { mitmHookDispatch(table, $0) }
        }
        guard ounce_result_succeeded(rc) else {
            throw OunceError("dispatching a request", rc)
        }
    }

    /// Serves the root session and every object session the hooks create.
    public func serveAll(_ root: MitmService) throws {
        let rc = withRaw { table in
            root.withRaw { mitmHookServeAll(table, $0) }
        }
        guard ounce_result_succeeded(rc) else {
            throw OunceError("serving the hook table", rc)
        }
    }

    /// Serves every session in the table and returns when none are left.
    public func serveSessions() throws {
        let rc = withRaw { mitmHookServeSessions($0) }
        guard ounce_result_succeeded(rc) else {
            throw OunceError("serving the hook sessions", rc)
        }
    }

    /// Creates a session pair for a loader to hand to another process.
    ///
    /// - Returns: The client end. The caller owns it.
    public func createSession(interface: UInt32,
                              user: UnsafeMutableRawPointer? = nil) throws -> Handle {
        var client: Handle = 0
        let rc = withRaw { mitmHookCreateSession($0, interface, user, &client) }
        guard ounce_result_succeeded(rc) else {
            throw OunceError("creating a hook session", rc)
        }
        return client
    }

    /// The number of hooks installed.
    public var hookCount: Int { Int(raw.entry_count) }

    /// The number of domain objects tracked.
    public var objectCount: Int { Int(raw.object_count) }

    /// The number of object sessions active.
    public var sessionCount: Int { Int(raw.session_count) }

    /// Runs `body` with a pointer to the underlying table.
    func withRaw<R>(_ body: (UnsafeMutablePointer<COunceMitm.MitmHookTable>) throws -> R) rethrows -> R {
        try withUnsafeMutablePointer(to: &raw, body)
    }
}

/// A process-local service override server.
///
/// This is the no-SM path: it installs the override in the current process, so
/// every `smGetService` for the name returns this server's session instead of
/// the real one.
public final class MitmHookOverride {
    private var raw = COunceMitm.MitmHookOverride()
    private let storage: MitmHookStorage
    private var boxes: [UnsafeMutableRawPointer] = []
    private var isOpen = false

    /// Creates an override server with its own hook storage.
    public init(entryCapacity: Int = 64, objectCapacity: Int = 64,
                sessionCapacity: Int = Int(MITM_HOOK_MAX_SESSIONS)) throws {
        storage = MitmHookStorage(entryCapacity: entryCapacity,
                                  objectCapacity: objectCapacity,
                                  sessionCapacity: sessionCapacity)
        var config = storage.config
        let rc = mitmHookOverrideInit(&raw, &config)
        guard ounce_result_succeeded(rc) else {
            throw OunceError("initializing the override", rc)
        }
        ounce_mitmSetHandler(mitmHandlerTrampoline)
        isOpen = true
    }

    deinit {
        stop()
        for box in boxes {
            Unmanaged<MitmHandlerBox>.fromOpaque(box).release()
        }
    }

    /// Installs a handler on the override's own table.
    public func install(interface: UInt32, command: UInt32,
                        handler: @escaping MitmHookHandler) throws {
        let box = Unmanaged.passRetained(MitmHandlerBox(handler)).toOpaque()
        let rc = withTable { table in
            mitmHookInstall(table, interface, command,
                            ounce_mitmHandlerTrampoline(), box)
        }
        guard ounce_result_succeeded(rc) else {
            Unmanaged<MitmHandlerBox>.fromOpaque(box).release()
            throw OunceError("installing a hook", rc)
        }
        boxes.append(box)
    }

    /// Opens the real service, creates a session pair, and installs the
    /// override.
    ///
    /// The real service is opened before the override is installed, so the
    /// forward session cannot recurse.
    public func start(service name: String) throws {
        let rc = name.withCString { mitmHookOverrideStart(&raw, $0) }
        guard ounce_result_succeeded(rc) else {
            throw OunceError("starting the override for \(name)", rc)
        }
    }

    /// Serves the root session and every object session in the table.
    public func serve() throws {
        let rc = mitmHookOverrideServe(&raw)
        guard ounce_result_succeeded(rc) else {
            throw OunceError("serving the override", rc)
        }
    }

    /// Closes the server side of the override.
    ///
    /// The client handle stays in the override table; there is no remove API.
    public func stop() {
        guard isOpen else { return }
        mitmHookOverrideStop(&raw)
        isOpen = false
    }

    private func withTable<R>(_ body: (UnsafeMutablePointer<COunceMitm.MitmHookTable>) throws -> R) rethrows -> R {
        try withUnsafeMutablePointer(to: &raw.table, body)
    }
}

/// The loader side of the hook framework: a server the loader connects to for
/// sessions it hands to other processes.
public final class MitmHookLoaderServer {
    private var raw = COunceMitm.MitmHookLoaderServer()
    private let table: MitmHookTable
    private var isOpen = false

    public init(table: MitmHookTable) {
        self.table = table
    }

    deinit {
        stop()
    }

    /// Starts the server for `service`.
    public func start(service name: String) throws {
        let rc = name.withCString { name in
            table.withRaw { mitmHookLoaderServerStart(&raw, $0, name) }
        }
        guard ounce_result_succeeded(rc) else {
            throw OunceError("starting the hook loader server for \(name)", rc)
        }
        isOpen = true
    }

    /// Handles one request from the loader.
    public func handle(session: Handle) throws {
        let rc = mitmHookLoaderServerHandle(&raw, session)
        guard ounce_result_succeeded(rc) else {
            throw OunceError("handling a loader request", rc)
        }
    }

    /// Serves the loader port until it closes.
    public func serve() throws {
        let rc = mitmHookLoaderServerServe(&raw)
        guard ounce_result_succeeded(rc) else {
            throw OunceError("serving the hook loader port", rc)
        }
    }

    /// Stops the server.
    public func stop() {
        guard isOpen else { return }
        mitmHookLoaderServerStop(&raw)
        isOpen = false
    }
}
