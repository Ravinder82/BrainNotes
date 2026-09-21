import Foundation

/// Deterministic in-memory HTTP stubbing for unit tests.
///
/// Tests install responses by URL prefix and inject a session built here into
/// `OpenAIClient(session:)`; production keeps its shared session.
final class MockURLProtocol: URLProtocol {
    enum Body {
        /// Full body, delivered in one chunk.
        case data(Data)
        /// Incremental chunks with a delay, so mid-stream cancellation is observable.
        case streamed([Data], intervalMs: UInt64)
    }

    struct Stub {
        let response: HTTPURLResponse
        let body: Body
    }

    private static let lock = NSLock()
    private static let bodyLock = NSLock()
    private nonisolated(unsafe) static var handlers: [(prefix: String, make: @Sendable (URLRequest) -> Stub)] = []
    private nonisolated(unsafe) static var capturedBodies: [Data] = []

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        handlers = []
        capturedBodies = []
    }

    static func stub(_ urlPrefix: String, _ make: @escaping @Sendable (URLRequest) -> Stub) {
        lock.lock(); defer { lock.unlock() }
        handlers.append((urlPrefix, make))
    }

    /// The body of the nth captured request, for wire-format assertions.
    static func capturedRequestBody(at index: Int = 0) -> Data? {
        bodyLock.lock(); defer { bodyLock.unlock() }
        guard capturedBodies.indices.contains(index) else { return nil }
        return capturedBodies[index]
    }

    /// SSE response yielding each line as its own chunk.
    static func sse(_ urlPrefix: String, lines: [String], intervalMs: UInt64 = 0) {
        stub(urlPrefix) { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "text/event-stream"])!
            let chunks = lines.map { Data(($0 + "\n").utf8) }
            return Stub(response: response, body: .streamed(chunks, intervalMs: intervalMs))
        }
    }

    /// A non-streaming response with the given status and body.
    static func raw(_ urlPrefix: String, status: Int, body: String,
                    contentType: String = "application/json") {
        stub(urlPrefix) { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                           httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": contentType])!
            return Stub(response: response, body: .data(Data(body.utf8)))
        }
    }

    /// A fake session bound to this protocol; tests inject it into the client.
    static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [MockURLProtocol.self]
        cfg.timeoutIntervalForRequest = 10
        return URLSession(configuration: cfg)
    }

    // MARK: - URLProtocol

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let body = Self.readBody(request)
        Self.bodyLock.lock()
        Self.capturedBodies.append(body)
        Self.bodyLock.unlock()

        Self.lock.lock()
        let match = Self.handlers.last { url.absoluteString.hasPrefix($0.prefix) }
        Self.lock.unlock()

        guard let stub = match?.make(request) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        client?.urlProtocol(self, didReceive: stub.response, cacheStoragePolicy: .notAllowed)
        switch stub.body {
        case .data(let data):
            if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
            client?.urlProtocolDidFinishLoading(self)
        case .streamed(let chunks, let intervalMs):
            // URLProtocol isn't Sendable; the loading contract allows serving
            // didLoad from any thread, so the test stub escapes the check
            // deliberately and only touches these values from this one task.
            let selfBox = UnsafeSendableBox(self)
            let clientBox = UnsafeSendableBox(client)
            Task.detached {
                for chunk in chunks {
                    try? Task.checkCancellation()
                    if intervalMs > 0 {
                        try? await Task.sleep(nanoseconds: intervalMs * 1_000_000)
                    }
                    clientBox.value?.urlProtocol(selfBox.value, didLoad: chunk)
                }
                clientBox.value?.urlProtocolDidFinishLoading(selfBox.value)
            }
        }
    }

    override func stopLoading() {}

    private static func readBody(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 64 * 1024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: size)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: size)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

/// Test-only escape hatch for values whose safe use is guaranteed by the
/// surrounding protocol's threading contract.
final class UnsafeSendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
