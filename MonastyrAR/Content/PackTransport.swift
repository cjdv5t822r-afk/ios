import Foundation
import StageCore

/// Why a request ended without the file.
enum TransportError: Error {
    /// The server answered, but not with the file: a status other than 200, or a redirect that is not followed.
    case server(String)
    /// The server could not be reached.
    case offline
}

/// "Fetch this URL as a stream of chunks": the one seam between the library and the network. The iOS
/// counterpart of `content/PackTransport.kt`.
///
/// One `URLSession` without cookies, cache or stored credentials. Redirects are held to the rules: never to
/// another host, and never from HTTPS down to HTTP. Plain HTTP is accepted only when the configured base
/// address is itself HTTP, which is a developer's local test server.
final class PackTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    /// The silence after which a connection counts as dead.
    private static let idleTimeout: TimeInterval = 20

    private let allowHTTP: Bool
    private let lock = NSLock()
    /// The requests under way, by task identifier. Guarded by `lock`.
    private var receivers: [Int: Receiver] = [:]
    private var session: URLSession!

    /// - Parameter base: the configured base address, or nil when there is none
    init(base: String?) {
        allowHTTP = base.map { PackServerRules.allowsPlainHTTP(base: $0) } ?? false
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        // A stale copy from a cache on the way would not match the catalog's checksums.
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = PackTransport.idleTimeout
        configuration.waitsForConnectivity = false
        // The session makes a serial queue of its own for the delegate calls: chunks arrive in order.
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    /// Requests `url` and hands over what comes back, on the session's delegate queue.
    ///
    /// - Parameters:
    ///   - head: called once when the server answers with status 200, with the size it announced (negative when
    ///     it did not say, or when the body is encoded on the way and the size is that of the encoded form).
    ///     Throwing refuses the body.
    ///   - body: called with every chunk, in order. Throwing ends the request.
    /// - Throws: whatever `head` or `body` threw; `TransportError` when the server answers with anything but the
    ///   file or cannot be reached; `CancellationError` when the calling task was cancelled, at once.
    func fetch(
        _ url: URL,
        head: @escaping (Int64) throws -> Void,
        body: @escaping (Data) throws -> Void
    ) async throws {
        guard PackServerRules.isAllowedScheme(url, allowHTTP: allowHTTP) else {
            throw TransportError.server("refused scheme")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.httpShouldHandleCookies = false
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        // The catalog lists the size of every file as it is stored; a compressed transfer would announce another.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")

        let receiver = Receiver(head: head, body: body)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.start(receiver, request: request, continuation: continuation)
            }
        } onCancel: {
            receiver.cancel()
        }
    }

    private func start(_ receiver: Receiver, request: URLRequest, continuation: CheckedContinuation<Void, Error>) {
        let task = session.dataTask(with: request)
        lock.lock()
        receivers[task.taskIdentifier] = receiver
        lock.unlock()
        if receiver.attach(task, continuation: continuation) {
            task.resume()
        } else {
            // Called off before it began.
            _ = remove(task)
            task.cancel()
            continuation.resume(throwing: CancellationError())
        }
    }

    private func receiver(for task: URLSessionTask) -> Receiver? {
        lock.lock()
        defer { lock.unlock() }
        return receivers[task.taskIdentifier]
    }

    private func remove(_ task: URLSessionTask) -> Receiver? {
        lock.lock()
        defer { lock.unlock() }
        return receivers.removeValue(forKey: task.taskIdentifier)
    }

    private static func transportError(_ error: Error) -> TransportError {
        guard let urlError = error as? URLError else { return .offline }
        switch PackServerRules.fault(for: urlError.code) {
        case .server: return .server("URL error \(urlError.code.rawValue)")
        case .offline: return .offline
        }
    }

    // MARK: URLSessionTaskDelegate

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        guard let receiver = receiver(for: task) else {
            completionHandler(nil)
            return
        }
        receiver.redirects += 1
        guard receiver.redirects <= PackServerRules.maxRedirects else {
            receiver.fail(TransportError.server("too many redirects"))
            completionHandler(nil)
            return
        }
        guard let from = response.url ?? task.currentRequest?.url,
              let to = request.url,
              PackServerRules.isAllowedRedirect(from: from, to: to, allowHTTP: allowHTTP)
        else {
            receiver.fail(TransportError.server("refused redirect"))
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let receiver = remove(task) else { return }
        if receiver.isCancelled {
            // A cancelled request can surface as a failed read; it is still a cancellation.
            receiver.finish(throwing: CancellationError())
        } else if let failure = receiver.failure {
            receiver.finish(throwing: failure)
        } else if let error {
            receiver.finish(throwing: PackTransport.transportError(error))
        } else if !receiver.accepted {
            receiver.finish(throwing: TransportError.server("no response"))
        } else {
            receiver.finish(throwing: nil)
        }
    }

    // MARK: URLSessionDataDelegate

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        guard let receiver = receiver(for: dataTask) else {
            completionHandler(.cancel)
            return
        }
        // A second response on one request (a multipart reply) is not a file either.
        guard receiver.failure == nil, !receiver.accepted else {
            receiver.fail(TransportError.server("unexpected response"))
            completionHandler(.cancel)
            return
        }
        guard let http = response as? HTTPURLResponse else {
            receiver.fail(TransportError.server("not an HTTP address"))
            completionHandler(.cancel)
            return
        }
        // A refused redirect arrives here too, as the 3xx it is.
        guard http.statusCode == 200 else {
            receiver.fail(TransportError.server("HTTP \(http.statusCode)"))
            completionHandler(.cancel)
            return
        }
        let encoding = http.value(forHTTPHeaderField: "Content-Encoding")?.lowercased()
        let announced: Int64 = (encoding == nil || encoding == "identity") ? http.expectedContentLength : -1
        do {
            try receiver.head(announced)
            receiver.accepted = true
            completionHandler(.allow)
        } catch {
            receiver.fail(error)
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let receiver = receiver(for: dataTask), receiver.failure == nil else { return }
        do {
            try receiver.body(data)
        } catch {
            receiver.fail(error)
            dataTask.cancel()
        }
    }
}

/// One request: what to do with its answer, and the task that waits for its end.
private final class Receiver: @unchecked Sendable {
    let head: (Int64) throws -> Void
    let body: (Data) throws -> Void

    // Touched on the session's delegate queue only.
    private(set) var failure: Error?
    var redirects = 0
    var accepted = false

    private let lock = NSLock()
    // Guarded by `lock`: the cancellation handler runs on whatever thread cancels the task.
    private var task: URLSessionDataTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var cancelled = false

    init(head: @escaping (Int64) throws -> Void, body: @escaping (Data) throws -> Void) {
        self.head = head
        self.body = body
    }

    /// Ties the request to its task. False when it was cancelled before it began.
    func attach(_ task: URLSessionDataTask, continuation: CheckedContinuation<Void, Error>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if cancelled { return false }
        self.task = task
        self.continuation = continuation
        return true
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    /// Ends a transfer that is blocked on the network: the task completes with an error right away.
    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        // Outside the lock: a cancellation handler must not hold a lock that a continuation is resumed under.
        task?.cancel()
    }

    /// The first failure is the one that is reported.
    func fail(_ error: Error) {
        if failure == nil { failure = error }
    }

    func finish(throwing error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }
}
