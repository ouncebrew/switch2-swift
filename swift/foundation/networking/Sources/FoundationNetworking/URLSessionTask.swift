// SPDX-License-Identifier: MIT
//
// URLSessionTask and URLSessionDataTask. Requests run synchronously when the
// task is resumed: the port has a single cooperative executor, so suspending a
// task on a blocking socket would starve everything else. The completion
// handler is therefore called before resume() returns, and the async
// URLSession.data(for:) methods return without suspending.

import FoundationEssentials

public enum URLSessionTaskState: Int, Sendable {
    case running = 0
    case suspended = 1
    case cancelling = 2
    case completed = 3
}

open class URLSessionTask {
    public let taskIdentifier: Int
    public private(set) var originalRequest: URLRequest?
    public private(set) var currentRequest: URLRequest?
    public private(set) var response: URLResponse?
    public private(set) var error: Error?
    public private(set) var state: URLSessionTaskState = .suspended

    internal var completedData: Data?

    private let operation: () throws -> (Data, URLResponse)

    internal init(
        taskIdentifier: Int,
        request: URLRequest,
        operation: @escaping () throws -> (Data, URLResponse)
    ) {
        self.taskIdentifier = taskIdentifier
        self.originalRequest = request
        self.currentRequest = request
        self.operation = operation
    }

    open func resume() {
        guard state == .suspended else { return }

        state = .running
        do {
            let result = try operation()
            completedData = result.0
            response = result.1
        } catch {
            self.error = error
        }
        state = .completed
    }

    open func cancel() {
        guard state != .completed else { return }
        state = .cancelling
        error = URLError(.cancelled, failingURL: originalRequest?.url)
        state = .completed
    }
}

public final class URLSessionDataTask: URLSessionTask {
    private let completionHandler: ((Data?, URLResponse?, Error?) -> Void)?

    internal init(
        taskIdentifier: Int,
        request: URLRequest,
        completionHandler: ((Data?, URLResponse?, Error?) -> Void)?,
        operation: @escaping () throws -> (Data, URLResponse)
    ) {
        self.completionHandler = completionHandler
        super.init(
            taskIdentifier: taskIdentifier,
            request: request,
            operation: operation
        )
    }

    public override func resume() {
        let wasSuspended = state == .suspended
        super.resume()
        if wasSuspended {
            completionHandler?(completedData, response, error)
        }
    }

    public override func cancel() {
        let wasCompleted = state == .completed
        super.cancel()
        if !wasCompleted {
            completionHandler?(nil, nil, error)
        }
    }
}
