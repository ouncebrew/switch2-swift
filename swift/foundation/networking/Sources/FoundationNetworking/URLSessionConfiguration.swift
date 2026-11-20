// SPDX-License-Identifier: MIT
//
// URLSessionConfiguration. The console has no cache, cookie store or proxy
// support, so the properties that would select those are present for source
// compatibility and are ignored by the client.

import FoundationEssentials

public class URLSessionConfiguration {
    public class var `default`: URLSessionConfiguration {
        URLSessionConfiguration()
    }

    public class var ephemeral: URLSessionConfiguration {
        URLSessionConfiguration()
    }

    public var timeoutIntervalForRequest: TimeInterval
    public var timeoutIntervalForResource: TimeInterval
    public var httpAdditionalHeaders: [String: String]?
    public var allowsCellularAccess: Bool
    public var httpShouldSetCookies: Bool
    public var requestCachePolicy: URLRequest.CachePolicy

    public init() {
        self.timeoutIntervalForRequest = 60.0
        self.timeoutIntervalForResource = 604_800.0
        self.httpAdditionalHeaders = nil
        self.allowsCellularAccess = true
        self.httpShouldSetCookies = false
        self.requestCachePolicy = .useProtocolCachePolicy
    }
}
