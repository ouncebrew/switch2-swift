// SPDX-License-Identifier: MIT
//
// URLError, matching the codes FoundationNetworking uses on Linux closely
// enough that ordinary error handling keeps working. Only the code and the
// failing URL are carried; there is no userInfo dictionary.

import FoundationEssentials

public struct URLError: Error, Equatable, Sendable {
    public enum Code: Int, Sendable {
        case unknown = -1
        case cancelled = -999
        case badURL = -1000
        case timedOut = -1001
        case unsupportedURL = -1002
        case cannotFindHost = -1003
        case cannotConnectToHost = -1004
        case networkConnectionLost = -1005
        case dnsLookupFailed = -1006
        case httpTooManyRedirects = -1007
        case resourceUnavailable = -1008
        case notConnectedToInternet = -1009
        case badServerResponse = -1011
        case secureConnectionFailed = -1200
    }

    public let code: Code
    public let failingURL: URL?

    public init(_ code: Code, failingURL: URL? = nil) {
        self.code = code
        self.failingURL = failingURL
    }

    public var localizedDescription: String {
        switch code {
        case .unknown: return "unknown error"
        case .cancelled: return "cancelled"
        case .badURL: return "bad URL"
        case .timedOut: return "the request timed out"
        case .unsupportedURL: return "unsupported URL"
        case .cannotFindHost: return "cannot find host"
        case .cannotConnectToHost: return "cannot connect to host"
        case .networkConnectionLost: return "network connection lost"
        case .dnsLookupFailed: return "DNS lookup failed"
        case .httpTooManyRedirects: return "too many redirects"
        case .resourceUnavailable: return "resource unavailable"
        case .notConnectedToInternet: return "not connected to the internet"
        case .badServerResponse: return "bad server response"
        case .secureConnectionFailed: return "secure connection failed"
        }
    }
}

extension URLError: CustomStringConvertible {
    public var description: String {
        if let failingURL {
            return "\(localizedDescription) (\(failingURL.absoluteString))"
        }
        return localizedDescription
    }
}
