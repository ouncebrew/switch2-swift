// SPDX-License-Identifier: MIT
//
// The transport, the C side of the port. The functions are declared with
// @_silgen_name rather than imported through a Clang module so that a program
// that imports FoundationNetworking needs no extra -Xcc flags. Keep the error
// numbers in sync with transport.h.

import FoundationEssentials

private enum TransportErrorCode {
    static let initialization: Int32 = -1
    static let dns: Int32 = -2
    static let connect: Int32 = -3
    static let timeout: Int32 = -4
    static let tls: Int32 = -5
    static let io: Int32 = -6
    static let badURL: Int32 = -7
}

@_silgen_name("sfn_net_initialize")
private func sfn_net_initialize() -> Int32

@_silgen_name("sfn_connect")
private func sfn_connect(
    _ host: UnsafePointer<CChar>,
    _ port: UInt16,
    _ useTLS: Int32,
    _ timeoutMilliseconds: Int32,
    _ error: UnsafeMutablePointer<Int32>
) -> UnsafeMutableRawPointer?

@_silgen_name("sfn_read")
private func sfn_read(
    _ connection: UnsafeMutableRawPointer,
    _ buffer: UnsafeMutableRawPointer,
    _ length: Int
) -> Int

@_silgen_name("sfn_write")
private func sfn_write(
    _ connection: UnsafeMutableRawPointer,
    _ buffer: UnsafeRawPointer,
    _ length: Int
) -> Int

@_silgen_name("sfn_close")
private func sfn_close(_ connection: UnsafeMutableRawPointer)

final class TransportConnection {
    private var handle: UnsafeMutableRawPointer?

    init(
        host: String,
        port: UInt16,
        tls: Bool,
        timeoutMilliseconds: Int32
    ) throws {
        var error: Int32 = 0
        let created = host.withCString { name in
            sfn_connect(
                name,
                port,
                tls ? 1 : 0,
                timeoutMilliseconds,
                &error
            )
        }
        guard let created else {
            throw TransportConnection.urlError(for: error)
        }
        self.handle = created
    }

    deinit {
        if let handle {
            sfn_close(handle)
        }
    }

    func read(maxLength: Int = 16 * 1024) throws -> [UInt8] {
        guard let handle, maxLength > 0 else { return [] }

        var buffer = [UInt8](repeating: 0, count: maxLength)
        let count = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return sfn_read(handle, base, maxLength)
        }

        if count < 0 {
            throw TransportConnection.urlError(for: Int32(count))
        }
        if count == 0 {
            return []
        }
        return Array(buffer[0..<count])
    }

    func write(_ bytes: [UInt8]) throws {
        guard let handle, !bytes.isEmpty else { return }

        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return sfn_write(
                    handle,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
            }

            if count <= 0 {
                throw TransportConnection.urlError(for: Int32(count))
            }
            offset += count
        }
    }

    private static func urlError(for code: Int32) -> URLError {
        switch code {
        case TransportErrorCode.initialization:
            return URLError(.notConnectedToInternet)
        case TransportErrorCode.dns:
            return URLError(.cannotFindHost)
        case TransportErrorCode.connect:
            return URLError(.cannotConnectToHost)
        case TransportErrorCode.timeout:
            return URLError(.timedOut)
        case TransportErrorCode.tls:
            return URLError(.secureConnectionFailed)
        case TransportErrorCode.badURL:
            return URLError(.badURL)
        default:
            return URLError(.networkConnectionLost)
        }
    }
}
