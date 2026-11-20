// SPDX-License-Identifier: MIT
//
// A synchronous HTTP/1.1 client over TransportConnection. It supports the
// parts URLSession needs for a data request: methods, headers, a body,
// Content-Length and chunked responses, redirects and a timeout. It does not
// do caching, cookies, proxies, authentication challenges, compression or
// HTTP/2; those are listed as limits in HANDOFF.md.

import FoundationEssentials

struct HTTPClient {
    let configuration: URLSessionConfiguration

    func data(for request: URLRequest) throws -> (Data, HTTPURLResponse) {
        var current = request

        var redirects = 0
        while true {
            let result = try perform(current)

            guard [301, 302, 303, 307, 308].contains(result.1.statusCode),
                  let location = result.1.value(forHTTPHeaderField: "Location"),
                  let baseURL = current.url,
                  let nextURL = URL(string: location, relativeTo: baseURL)?.absoluteURL
            else {
                return result
            }

            redirects += 1
            if redirects > 10 {
                throw URLError(.httpTooManyRedirects, failingURL: baseURL)
            }

            var next = current
            next.url = nextURL

            let method = (current.httpMethod ?? "GET").uppercased()
            if result.1.statusCode == 303 ||
                ((result.1.statusCode == 301 || result.1.statusCode == 302) &&
                    method == "POST") {
                next.httpMethod = "GET"
                next.httpBody = nil
                next.setValue(nil, forHTTPHeaderField: "Content-Length")
                next.setValue(nil, forHTTPHeaderField: "Content-Type")
            }

            current = next
        }
    }

    private func perform(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        guard let url = request.url else {
            throw URLError(.badURL)
        }
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else {
            throw URLError(.unsupportedURL, failingURL: url)
        }
        guard let host = url.host, !host.isEmpty else {
            throw URLError(.badURL, failingURL: url)
        }

        let method = (request.httpMethod ?? "GET").uppercased()
        guard !method.isEmpty,
              method.utf8.allSatisfy({ $0 > 32 && $0 < 127 })
        else {
            throw URLError(.badURL, failingURL: url)
        }

        let portNumber = url.port ?? (scheme == "https" ? 443 : 80)
        guard let port = UInt16(exactly: portNumber), port > 0 else {
            throw URLError(.badURL, failingURL: url)
        }

        let seconds = request.timeoutInterval.isFinite
            ? min(max(request.timeoutInterval, 1.0), 300.0)
            : 60.0
        let timeoutMilliseconds = Int32(seconds * 1000.0)

        var dnsHost = host
        if dnsHost.hasPrefix("["), dnsHost.hasSuffix("]") {
            dnsHost.removeFirst()
            dnsHost.removeLast()
        }

        let connection = try TransportConnection(
            host: dnsHost,
            port: port,
            tls: scheme == "https",
            timeoutMilliseconds: timeoutMilliseconds
        )

        let body = request.httpBody.map { Array($0) }
        let head = requestHead(
            request,
            url: url,
            scheme: scheme,
            bodyLength: body?.count
        )
        try connection.write(Array(head.utf8))
        if let body {
            try connection.write(body)
        }

        let reader = ResponseReader(connection: connection, url: url)
        return try reader.readResponse(method: method)
    }

    private func requestHead(
        _ request: URLRequest,
        url: URL,
        scheme: String,
        bodyLength: Int?
    ) -> String {
        var headers: [(name: String, value: String)] = []

        func set(_ name: String, _ value: String) {
            if let index = headers.firstIndex(where: {
                $0.name.lowercased() == name.lowercased()
            }) {
                headers[index].value = value
            } else {
                headers.append((name, value))
            }
        }

        set("Host", hostHeader(for: url, scheme: scheme))
        set("Accept", "*/*")
        set("Accept-Encoding", "identity")
        set("User-Agent", "Switch2FoundationNetworking/1.0")
        set("Connection", "close")

        if let additional = configuration.httpAdditionalHeaders {
            for (name, value) in additional.sorted(by: { $0.key < $1.key }) {
                set(name, value)
            }
        }
        if let fields = request.allHTTPHeaderFields {
            for (name, value) in fields.sorted(by: { $0.key < $1.key }) {
                set(name, value)
            }
        }
        if let bodyLength,
           httpHeaderValue(in: request.allHTTPHeaderFields,
                           named: "Content-Length") == nil {
            set("Content-Length", String(bodyLength))
        }

        let method = (request.httpMethod ?? "GET").uppercased()
        var head = "\(method) \(requestTarget(for: url)) HTTP/1.1\r\n"
        for header in headers {
            guard !header.name.isEmpty,
                  !header.name.contains("\r"),
                  !header.name.contains("\n"),
                  !header.value.contains("\r"),
                  !header.value.contains("\n")
            else {
                continue
            }
            head += "\(header.name): \(header.value)\r\n"
        }
        head += "\r\n"
        return head
    }

    /// The origin-form request target: everything after the authority, with
    /// the fragment removed. The URL's string is already percent-encoded, so
    /// slicing it preserves the encoding Foundation chose.
    private func requestTarget(for url: URL) -> String {
        let absolute = url.absoluteString
        guard let colon = absolute.firstIndex(of: ":") else {
            return "/"
        }
        let afterColon = absolute.index(after: colon)
        guard absolute[afterColon...].hasPrefix("//") else {
            return "/"
        }

        var remainder = absolute[absolute.index(afterColon, offsetBy: 2)...]
        if let endOfAuthority = remainder.firstIndex(where: {
            $0 == "/" || $0 == "?"
        }) {
            remainder = remainder[endOfAuthority...]
        } else {
            return "/"
        }

        if let fragment = remainder.firstIndex(of: "#") {
            remainder = remainder[..<fragment]
        }
        if remainder.hasPrefix("?") {
            return "/" + String(remainder)
        }
        return String(remainder)
    }

    private func hostHeader(for url: URL, scheme: String) -> String {
        let host = url.host ?? ""
        let shown: String
        if host.contains(":"), !host.hasPrefix("[") {
            shown = "[\(host)]"
        } else {
            shown = host
        }

        let defaultPort = scheme == "https" ? 443 : 80
        if let port = url.port, port != defaultPort {
            return "\(shown):\(port)"
        }
        return shown
    }
}

private final class ResponseReader {
    private let connection: TransportConnection
    private let url: URL
    private var buffer: [UInt8] = []

    init(connection: TransportConnection, url: URL) {
        self.connection = connection
        self.url = url
    }

    func readResponse(method: String) throws -> (Data, HTTPURLResponse) {
        var statusCode = 0
        var version = ""
        var headers: [String: String] = [:]

        while true {
            var statusLine = try readLine()
            while statusLine.isEmpty {
                statusLine = try readLine()
            }

            let parts = statusLine.split(
                separator: " ",
                maxSplits: 2,
                omittingEmptySubsequences: true
            )
            guard parts.count >= 2,
                  parts[0].hasPrefix("HTTP/"),
                  let code = Int(parts[1])
            else {
                throw URLError(.badServerResponse, failingURL: url)
            }

            statusCode = code
            version = String(parts[0])
            headers = [:]

            while true {
                let line = try readLine()
                if line.isEmpty {
                    break
                }
                guard let colon = line.firstIndex(of: ":") else {
                    continue
                }
                let name = trimmingHTTPWhitespace(String(line[..<colon]))
                let value = trimmingHTTPWhitespace(
                    String(line[line.index(after: colon)...])
                )
                guard !name.isEmpty else { continue }

                if let existing = httpHeaderValue(in: headers, named: name),
                   let key = headers.keys.first(where: {
                       $0.lowercased() == name.lowercased()
                   }) {
                    headers[key] = existing + ", " + value
                } else {
                    headers[name] = value
                }
            }

            if statusCode >= 100 && statusCode < 200 {
                if statusCode == 101 {
                    throw URLError(.badServerResponse, failingURL: url)
                }
                continue
            }
            break
        }

        guard let response = HTTPURLResponse(
            url: url,
            statusCode: statusCode,
            httpVersion: version,
            headerFields: headers
        ) else {
            throw URLError(.badServerResponse, failingURL: url)
        }

        let hasNoBody = method == "HEAD" || statusCode == 204 || statusCode == 304
        if hasNoBody {
            return (Data(), response)
        }

        let transferEncoding = httpHeaderValue(
            in: headers,
            named: "Transfer-Encoding"
        )
        if let transferEncoding,
           transferEncoding.lowercased().contains("chunked") {
            return (Data(try readChunkedBody()), response)
        }

        if let lengthText = httpHeaderValue(in: headers, named: "Content-Length"),
           let length = Int(trimmingHTTPWhitespace(lengthText)),
           length >= 0 {
            return (Data(try readExactly(length)), response)
        }

        return (Data(try readToEnd()), response)
    }

    private func readLine() throws -> String {
        let bytes = try readUntil([13, 10], limit: 64 * 1024)
        return String(decoding: bytes, as: UTF8.self)
    }

    private func readUntil(_ marker: [UInt8], limit: Int) throws -> [UInt8] {
        while true {
            if let index = firstIndex(of: marker) {
                let result = Array(buffer[0..<index])
                buffer.removeFirst(index + marker.count)
                return result
            }
            if buffer.count > limit {
                throw URLError(.badServerResponse, failingURL: url)
            }
            let more = try fill()
            if !more {
                throw URLError(.networkConnectionLost, failingURL: url)
            }
        }
    }

    private func readExactly(_ count: Int) throws -> [UInt8] {
        guard count > 0 else { return [] }

        while buffer.count < count {
            let more = try fill()
            if !more {
                throw URLError(.networkConnectionLost, failingURL: url)
            }
        }

        let result = Array(buffer[0..<count])
        buffer.removeFirst(count)
        return result
    }

    private func readToEnd() throws -> [UInt8] {
        var result = buffer
        buffer.removeAll(keepingCapacity: true)

        while true {
            let more = try fill()
            if !more {
                break
            }
            result.append(contentsOf: buffer)
            buffer.removeAll(keepingCapacity: true)
        }

        return result
    }

    private func readChunkedBody() throws -> [UInt8] {
        var result: [UInt8] = []

        while true {
            let line = try readLine()
            let sizeText = line
                .split(separator: ";", maxSplits: 1,
                       omittingEmptySubsequences: false)
                .first
                .map { String($0) } ?? ""
            guard let size = Int(trimmingHTTPWhitespace(sizeText), radix: 16),
                  size >= 0
            else {
                throw URLError(.badServerResponse, failingURL: url)
            }

            if size == 0 {
                while true {
                    let trailer = try readLine()
                    if trailer.isEmpty {
                        break
                    }
                }
                return result
            }

            result.append(contentsOf: try readExactly(size))
            if !(try readLine()).isEmpty {
                throw URLError(.badServerResponse, failingURL: url)
            }
        }
    }

    private func fill() throws -> Bool {
        let chunk = try connection.read()
        if chunk.isEmpty {
            return false
        }
        buffer.append(contentsOf: chunk)
        return true
    }

    private func firstIndex(of marker: [UInt8]) -> Int? {
        guard !marker.isEmpty, buffer.count >= marker.count else {
            return nil
        }

        var index = 0
        while index <= buffer.count - marker.count {
            var matched = 0
            while matched < marker.count &&
                    buffer[index + matched] == marker[matched] {
                matched += 1
            }
            if matched == marker.count {
                return index
            }
            index += 1
        }
        return nil
    }
}
