// SPDX-License-Identifier: MIT
//
// URLSession. Task identifiers are allocated from a plain counter; the port is
// single-threaded and the class is not Sendable. See URLSessionTask.swift for
// the synchronous execution model.

import FoundationEssentials

public final class URLSession {
    public static let shared = URLSession(configuration: .default)

    public let configuration: URLSessionConfiguration

    private var nextTaskIdentifier = 1

    public init(configuration: URLSessionConfiguration) {
        self.configuration = configuration
    }

    @discardableResult
    public func dataTask(
        with request: URLRequest,
        completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void
    ) -> URLSessionDataTask {
        makeTask(request, completionHandler: completionHandler)
    }

    @discardableResult
    public func dataTask(with request: URLRequest) -> URLSessionDataTask {
        makeTask(request, completionHandler: nil)
    }

    @discardableResult
    public func dataTask(
        with url: URL,
        completionHandler: @escaping (Data?, URLResponse?, Error?) -> Void
    ) -> URLSessionDataTask {
        makeTask(URLRequest(url: url), completionHandler: completionHandler)
    }

    @discardableResult
    public func dataTask(with url: URL) -> URLSessionDataTask {
        makeTask(URLRequest(url: url), completionHandler: nil)
    }

    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let result = try HTTPClient(configuration: configuration).data(for: request)
        return (result.0, result.1)
    }

    public func data(from url: URL) async throws -> (Data, URLResponse) {
        try await data(for: URLRequest(url: url))
    }

    private func makeTask(
        _ request: URLRequest,
        completionHandler: ((Data?, URLResponse?, Error?) -> Void)?
    ) -> URLSessionDataTask {
        let identifier = nextTaskIdentifier
        nextTaskIdentifier += 1

        let configuration = self.configuration
        return URLSessionDataTask(
            taskIdentifier: identifier,
            request: request,
            completionHandler: completionHandler
        ) {
            try HTTPClient(configuration: configuration).data(for: request)
        }
    }
}
