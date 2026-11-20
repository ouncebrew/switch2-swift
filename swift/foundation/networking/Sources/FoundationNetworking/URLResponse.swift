// SPDX-License-Identifier: MIT
//
// URLResponse and HTTPURLResponse. The header dictionary is exposed as
// [AnyHashable: Any] to match Foundation while the typed copy is kept for
// case-insensitive lookup.

import FoundationEssentials

open class URLResponse {
    public let url: URL?
    public let mimeType: String?
    public let expectedContentLength: Int
    public let textEncodingName: String?

    public init(
        url: URL?,
        mimeType: String?,
        expectedContentLength length: Int,
        textEncodingName name: String?
    ) {
        self.url = url
        self.mimeType = mimeType
        self.expectedContentLength = length
        self.textEncodingName = name
    }
}

open class HTTPURLResponse: URLResponse {
    public let statusCode: Int
    public let httpVersion: String?
    public let allHeaderFields: [AnyHashable: Any]

    private let headerFields: [String: String]

    public init?(
        url: URL?,
        statusCode: Int,
        httpVersion: String?,
        headerFields: [String: String]?
    ) {
        self.statusCode = statusCode
        self.httpVersion = httpVersion

        let fields = headerFields ?? [:]
        self.headerFields = fields

        var exposed: [AnyHashable: Any] = [:]
        for (key, value) in fields {
            exposed[key] = value
        }
        self.allHeaderFields = exposed

        let length = httpHeaderValue(in: fields, named: "Content-Length")
            .flatMap { Int(trimmingHTTPWhitespace($0)) } ?? -1
        let contentType = httpHeaderValue(in: fields, named: "Content-Type")

        super.init(
            url: url,
            mimeType: contentType,
            expectedContentLength: length,
            textEncodingName: nil
        )
    }

    public func value(forHTTPHeaderField field: String) -> String? {
        if let value = headerFields[field] {
            return value
        }
        let lowered = field.lowercased()
        for (key, value) in headerFields where key.lowercased() == lowered {
            return value
        }
        return nil
    }
}
