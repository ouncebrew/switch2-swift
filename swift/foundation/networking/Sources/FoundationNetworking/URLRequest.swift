// SPDX-License-Identifier: MIT
//
// URLRequest. FoundationEssentials starts at URL and stops before the
// networking layer; URLRequest and the URLSession types live in
// FoundationNetworking on Linux, so this port supplies the subset it can
// actually honour.

import FoundationEssentials

public struct URLRequest: Hashable, Sendable {
    public enum CachePolicy: Hashable, Sendable {
        case useProtocolCachePolicy
        case reloadIgnoringLocalCacheData
        case returnCacheDataElseLoad
        case returnCacheDataDontLoad
    }

    public var url: URL?
    public var cachePolicy: CachePolicy
    public var timeoutInterval: TimeInterval
    public var httpMethod: String?
    public var allHTTPHeaderFields: [String: String]?
    public var httpBody: Data?
    public var allowsCellularAccess: Bool
    public var httpShouldHandleCookies: Bool

    public init(
        url: URL,
        cachePolicy: CachePolicy = .useProtocolCachePolicy,
        timeoutInterval: TimeInterval = 60.0
    ) {
        self.url = url
        self.cachePolicy = cachePolicy
        self.timeoutInterval = timeoutInterval
        self.httpMethod = nil
        self.allHTTPHeaderFields = nil
        self.httpBody = nil
        self.allowsCellularAccess = true
        self.httpShouldHandleCookies = false
    }

    public func value(forHTTPHeaderField field: String) -> String? {
        httpHeaderValue(in: allHTTPHeaderFields, named: field)
    }

    public mutating func setValue(_ value: String?, forHTTPHeaderField field: String) {
        var fields = allHTTPHeaderFields ?? [:]
        if let existing = fields.keys.first(where: {
            $0.lowercased() == field.lowercased()
        }) {
            fields.removeValue(forKey: existing)
        }
        if let value {
            fields[field] = value
        }
        allHTTPHeaderFields = fields.isEmpty ? nil : fields
    }

    public mutating func addValue(_ value: String, forHTTPHeaderField field: String) {
        var fields = allHTTPHeaderFields ?? [:]
        if let existing = fields.keys.first(where: {
            $0.lowercased() == field.lowercased()
        }) {
            fields[existing] = (fields[existing] ?? "") + ", " + value
        } else {
            fields[field] = value
        }
        allHTTPHeaderFields = fields
    }
}
