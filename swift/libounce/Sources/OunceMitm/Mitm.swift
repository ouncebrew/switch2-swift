import COunceMitm
import Ounce

/// Information about the process on the other end of a mitm session.
public struct MitmProcessInfo: Sendable {
    /// Process ID of the client.
    public var processID: UInt64

    /// Program ID of the client.
    public var programID: UInt64

    /// Program ID of the override the client was launched from, or 0.
    public var overrideProgramID: UInt64

    /// Override flags of the client, or 0.
    public var overrideFlags: UInt64

    public init(processID: UInt64 = 0, programID: UInt64 = 0,
                overrideProgramID: UInt64 = 0, overrideFlags: UInt64 = 0) {
        self.processID = processID
        self.programID = programID
        self.overrideProgramID = overrideProgramID
        self.overrideFlags = overrideFlags
    }

    var raw: COunceMitm.MitmProcessInfo {
        COunceMitm.MitmProcessInfo(process_id: processID, program_id: programID,
                                   override_program_id: overrideProgramID,
                                   override_flags: overrideFlags)
    }
}

/// The serialization a mitm session uses.
public enum MitmProtocol: UInt32, Sendable {
    /// Tiny IPC. Used by HOS 12.0.0+ and by Switch 2.
    case tipc = 0

    /// Common Message Interface Framework. Used by HOS before 12.0.0.
    case cmif = 1
}

/// A parsed mitm request.
///
/// The pointers refer into the thread's TLS buffer and are only valid until the
/// next request is received. Copy anything you need to keep.
public struct MitmRequest {
    /// The raw HIPC request.
    public let raw: COunceMitm.MitmRequest

    init(raw: COunceMitm.MitmRequest) {
        self.raw = raw
    }

    /// The raw HIPC message type.
    public var type: UInt32 { raw.type }

    /// True when the client dropped the session.
    public var isClose: Bool { raw.type == 15 }

    /// The command ID, or nil for a close request.
    public var commandID: UInt32? {
        raw.command_id == UInt32.max ? nil : raw.command_id
    }

    /// The request payload.
    public var data: UnsafeMutableRawPointer? { raw.data }

    /// The request payload size in bytes.
    public var dataSize: Int { Int(raw.data_size) }

    /// The CMIF header, or nil for TIPC.
    public var cmifHeader: UnsafeMutablePointer<CmifInHeader>? { raw.cmif_header }

    /// The CMIF domain header, or nil.
    public var domainHeader: UnsafeMutablePointer<CmifDomainInHeader>? { raw.domain_header }

    /// The CMIF domain input object IDs, or nil.
    public var objects: UnsafeMutablePointer<UInt32>? { raw.objects }
}

/// A mitm service session.
///
/// The session owns both handles and closes them when it is released, or when
/// ``close()`` is called.
public final class MitmService {
    private var raw = COunceMitm.MitmService()
    private var isOpen = false

    /// The value libnx uses for "no handle".
    public static let invalidHandle: Handle = 0

    /// Initializes a session.
    ///
    /// - Parameters:
    ///   - session: The client session handle. Ownership is taken.
    ///   - forwardSession: A session to the real service, or
    ///     ``invalidHandle``. Ownership is taken.
    ///   - clientInfo: Information about the client process, if known.
    public init(session: Handle, forwardSession: Handle = MitmService.invalidHandle,
                clientInfo: MitmProcessInfo? = nil) {
        if var info = clientInfo?.raw {
            ounce_mitmServiceCreate(&raw, session, forwardSession, &info)
        } else {
            ounce_mitmServiceCreate(&raw, session, forwardSession, nil)
        }
        isOpen = true
    }

    deinit {
        close()
    }

    /// Wraps a session the framework owns. The wrapper does not close it.
    init(borrowing raw: COunceMitm.MitmService) {
        self.raw = raw
        isOpen = false
    }

    /// Runs `body` with a pointer to the underlying session.
    func withRaw<R>(_ body: (UnsafeMutablePointer<COunceMitm.MitmService>) throws -> R) rethrows -> R {
        try withUnsafeMutablePointer(to: &raw, body)
    }

    /// Closes the session and releases both handles. Calling it twice is
    /// harmless.
    public func close() {
        guard isOpen else { return }
        ounce_mitmServiceClose(&raw)
        isOpen = false
    }

    /// The serialization of the current request.
    public var protocolKind: MitmProtocol {
        MitmProtocol(rawValue: raw.protocol) ?? .tipc
    }

    /// The CMIF token of the current request.
    public var token: UInt32 { raw.token }

    /// The CMIF domain object ID of the current request, or 0.
    public var domainObjectID: UInt32 { raw.domain_object_id }

    /// True when the client converted this session to a domain.
    public var isDomain: Bool {
        get { raw.flags & UInt32(MitmServiceFlag_IsDomain) != 0 }
        set {
            if newValue {
                raw.flags |= UInt32(MitmServiceFlag_IsDomain)
            } else {
                raw.flags &= ~UInt32(MitmServiceFlag_IsDomain)
            }
        }
    }

    /// The client process information.
    public var clientInfo: MitmProcessInfo {
        MitmProcessInfo(processID: raw.client_info.process_id,
                        programID: raw.client_info.program_id,
                        overrideProgramID: raw.client_info.override_program_id,
                        overrideFlags: raw.client_info.override_flags)
    }

    /// Parses the request currently in the thread's TLS buffer.
    ///
    /// Call this once per request, before deciding whether to handle or forward
    /// it.
    public func parseRequest() -> MitmRequest {
        MitmRequest(raw: ounce_mitmServiceParseRequest(&raw))
    }

    /// Rewrites the PID descriptor of a request.
    ///
    /// Does nothing when the request carries no PID descriptor. Use it before
    /// ``forward()`` so the real service applies the client's policy instead of
    /// the mitm's.
    public func setPid(_ pid: UInt64, for request: MitmRequest) {
        var raw = request.raw
        ounce_mitmRequestSetPid(&raw, pid)
    }

    /// Builds a response in the thread's TLS buffer using the session's
    /// serialization.
    ///
    /// - Returns: The payload area, and the handle array to fill when
    ///   `numHandles` is not zero.
    public func beginResponse(result: ResultCode, payloadSize: Int = 0,
                              numHandles: Int = 0)
        -> (payload: UnsafeMutableRawPointer?, handles: UnsafeMutablePointer<Handle>?) {
        var handles: UnsafeMutablePointer<Handle>?
        let payload = ounce_mitmServiceBeginResponse(&raw, result.rawValue,
                                                     UInt32(payloadSize),
                                                     UInt32(numHandles), &handles)
        return (payload, handles)
    }

    /// Replies to the client with whatever is currently in the TLS buffer.
    public func reply() throws {
        let rc = ounce_mitmServiceReply(&raw)
        guard ounce_result_succeeded(rc) else {
            throw OunceError("replying to the client", rc)
        }
    }

    /// Forwards the current request verbatim to the real service and replies to
    /// the client.
    ///
    /// This replays the message already in TLS, so it preserves buffers,
    /// handles and domain object IDs.
    public func forward() throws {
        let rc = ounce_mitmServiceForward(&raw)
        guard ounce_result_succeeded(rc) else {
            throw OunceError("forwarding to the real service", rc)
        }
    }
}

/// A domain object tracked by a ``MitmDomainTable``.
public struct MitmDomainObject {
    /// The object ID handed to the client.
    public var id: UInt32

    /// The object ID used by the real service.
    public var forwardID: UInt32

    /// A caller-defined object kind.
    public var kind: UInt32

    /// A caller-defined payload.
    public var user: UnsafeMutableRawPointer?

    public init(id: UInt32 = 0, forwardID: UInt32 = 0, kind: UInt32 = 0,
                user: UnsafeMutableRawPointer? = nil) {
        self.id = id
        self.forwardID = forwardID
        self.kind = kind
        self.user = user
    }
}

/// A table mapping mitm object IDs to the real service's object IDs.
public final class MitmDomainTable {
    private let storage: UnsafeMutablePointer<COunceMitm.MitmDomainObject>
    private let capacity: Int
    private var raw = COunceMitm.MitmDomainTable()

    /// Creates a table with room for `capacity` objects.
    public init(capacity: Int = Int(MITM_DOMAIN_MAX_OBJECTS)) {
        self.capacity = capacity
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: COunceMitm.MitmDomainObject(), count: capacity)
        mitmDomainTableInit(&raw, storage, UInt32(capacity))
    }

    deinit {
        storage.deinitialize(count: capacity)
        storage.deallocate()
    }

    /// Allocates an object.
    ///
    /// - Returns: The new object ID, or nil when the table is full.
    public func allocate(forwardID: UInt32 = 0, kind: UInt32 = 0,
                         user: UnsafeMutableRawPointer? = nil) -> UInt32? {
        let id = mitmDomainTableAlloc(&raw, forwardID, kind, user)
        return id == 0 ? nil : id
    }

    /// Releases an object.
    public func free(_ id: UInt32) {
        mitmDomainTableFree(&raw, id)
    }

    /// Looks up an object.
    public func object(_ id: UInt32) -> MitmDomainObject? {
        guard let raw = mitmDomainTableGet(&raw, id) else { return nil }
        return MitmDomainObject(id: raw.pointee.id, forwardID: raw.pointee.forward_id,
                                kind: raw.pointee.kind, user: raw.pointee.user)
    }

    /// The number of slots in use.
    public var count: Int { Int(raw.count) }
}
