import Foundation

enum BackendEventStreamStatus: Equatable, Sendable {
    case idle
    case connecting
    case connected
    case reconnecting
    case authenticationFailed
    case stopped

    var title: String {
        switch self {
        case .idle: "尚未启动"
        case .connecting: "正在连接"
        case .connected: "已连接"
        case .reconnecting: "等待重连"
        case .authenticationFailed: "认证失败"
        case .stopped: "已停止"
        }
    }
}

struct BackendServerEvent: Equatable, Sendable {
    let id: String?
    let name: String
    let data: String
    let retryMilliseconds: Int?
}

struct ServerSentEventParser: Sendable {
    private var eventID: String?
    private var eventName: String?
    private var dataLines: [String] = []
    private var retryMilliseconds: Int?
    private var hasField = false

    mutating func consume(line: String) -> BackendServerEvent? {
        if line.isEmpty {
            defer { resetEventFields() }
            guard hasField else { return nil }
            return BackendServerEvent(
                id: eventID,
                name: eventName ?? "message",
                data: dataLines.joined(separator: "\n"),
                retryMilliseconds: retryMilliseconds
            )
        }

        guard !line.hasPrefix(":") else { return nil }
        let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let field = String(parts[0])
        var value = parts.count == 2 ? String(parts[1]) : ""
        if value.hasPrefix(" ") { value.removeFirst() }

        switch field {
        case "event":
            eventName = value
            hasField = true
        case "data":
            dataLines.append(value)
            hasField = true
        case "id" where !value.contains("\0"):
            eventID = value
            hasField = true
        case "retry":
            if let retry = Int(value), retry >= 0 {
                retryMilliseconds = retry
                hasField = true
            }
        default:
            break
        }
        return nil
    }

    private mutating func resetEventFields() {
        eventID = nil
        eventName = nil
        dataLines.removeAll(keepingCapacity: true)
        retryMilliseconds = nil
        hasField = false
    }
}

enum BackendEventStreamError: LocalizedError, Equatable {
    case unauthorized(Int)
    case httpStatus(Int)
    case invalidResponse
    case invalidContentType
    case ended

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "实时连接认证失败，请检查后端 API Key。"
        case .httpStatus(let status):
            return "实时连接失败（HTTP \(status)）。"
        case .invalidResponse:
            return "实时连接返回了无效响应。"
        case .invalidContentType:
            return "实时连接未返回 text/event-stream。"
        case .ended:
            return "实时连接已断开。"
        }
    }
}

struct BackendEventReconnectPolicy {
    static let maximumDelay: TimeInterval = 30

    static func delay(
        attempt: Int,
        serverRetryMilliseconds: Int?,
        jitter: Double
    ) -> TimeInterval {
        let suggested = serverRetryMilliseconds.map { TimeInterval($0) / 1_000 }
        let exponential = min(maximumDelay, pow(2, Double(max(0, attempt))))
        let base = min(maximumDelay, max(1, max(suggested ?? 0, exponential)))
        return min(maximumDelay, base * min(max(jitter, 0.8), 1.2))
    }
}

struct BackendEventStreamClient: Sendable {
    let configuration: BackendConfiguration

    init(configuration: BackendConfiguration, session: URLSession? = nil) {
        self.configuration = configuration
        // Kept as an optional argument for source compatibility with tests and
        // injected clients. SSE uses its own delegate-backed streaming session
        // so small frames are delivered incrementally on iOS.
        _ = session
    }

    func makeRequest(lastEventID: String?) -> URLRequest {
        let url = configuration.baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("v1")
            .appendingPathComponent("events")
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let lastEventID, !lastEventID.isEmpty {
            request.setValue(lastEventID, forHTTPHeaderField: "Last-Event-ID")
        }
        return request
    }

    func events(lastEventID: String?) -> AsyncThrowingStream<BackendServerEvent, Error> {
        let request = makeRequest(lastEventID: lastEventID)
        return AsyncThrowingStream { continuation in
            let transport = BackendEventStreamTransport(
                allowedHost: configuration.baseURL.host,
                continuation: continuation
            )
            transport.start(request: request)
            continuation.onTermination = { @Sendable _ in transport.cancel() }
        }
    }
}

private final class BackendEventStreamTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    typealias Continuation = AsyncThrowingStream<BackendServerEvent, Error>.Continuation

    private let allowedHost: String?
    private let continuation: Continuation
    private let lock = NSLock()
    private var isFinished = false
    private var buffer = Data()
    private var parser = ServerSentEventParser()
    private var session: URLSession?
    private var task: URLSessionDataTask?

    init(allowedHost: String?, continuation: Continuation) {
        self.allowedHost = allowedHost?.lowercased()
        self.continuation = continuation
    }

    func start(request: URLRequest) {
        let queue = OperationQueue()
        queue.name = "com.shuto.happyvalley.sse-stream"
        queue.maxConcurrentOperationCount = 1
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 7 * 24 * 60 * 60
        configuration.waitsForConnectivity = true
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        let task = session.dataTask(with: request)
        self.session = session
        self.task = task
        task.resume()
    }

    func cancel() {
        lock.lock()
        let shouldCancel = !isFinished
        isFinished = true
        lock.unlock()
        guard shouldCancel else { return }
        task?.cancel()
        session?.invalidateAndCancel()
        task = nil
        session = nil
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let (disposition, credential) = BackendAuthentication.response(
            for: challenge,
            allowedHost: allowedHost
        )
        completionHandler(disposition, credential)
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let response = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(throwing: BackendEventStreamError.invalidResponse)
            return
        }
        if response.statusCode == 401 || response.statusCode == 403 {
            completionHandler(.cancel)
            finish(throwing: BackendEventStreamError.unauthorized(response.statusCode))
            return
        }
        guard 200..<300 ~= response.statusCode else {
            completionHandler(.cancel)
            finish(throwing: BackendEventStreamError.httpStatus(response.statusCode))
            return
        }
        guard response.value(forHTTPHeaderField: "Content-Type")?
            .lowercased().contains("text/event-stream") == true else {
            completionHandler(.cancel)
            finish(throwing: BackendEventStreamError.invalidContentType)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[..<newline]
            buffer.removeSubrange(...newline)
            var line = String(decoding: lineData, as: UTF8.self)
            if line.last == "\r" { line.removeLast() }
            if let event = parser.consume(line: line) {
                continuation.yield(event)
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if let error = error as? URLError, error.code == .cancelled {
            finish()
        } else if let error {
            finish(throwing: error)
        } else {
            finish(throwing: BackendEventStreamError.ended)
        }
    }

    private func finish(throwing error: Error? = nil) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        lock.unlock()

        if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
        session?.finishTasksAndInvalidate()
        task = nil
        session = nil
    }
}
