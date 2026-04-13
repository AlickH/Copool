import Foundation
import Network

struct HTTPRequest {
    var method: String
    var target: String
    var path: String
    var queryItems: [URLQueryItem]
    var headers: [String: String]
    var body: Data
}

struct HTTPResponse {
    enum Body {
        case data(Data)
        case stream(AsyncThrowingStream<Data, Error>)
    }

    var statusCode: Int
    var headers: [String: String]
    var body: Body

    init(statusCode: Int, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = .data(body)
    }

    init(statusCode: Int, headers: [String: String], body: AsyncThrowingStream<Data, Error>) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = .stream(body)
    }

    static func json(statusCode: Int, object: Any) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
        return HTTPResponse(
            statusCode: statusCode,
            headers: ["Content-Type": "application/json; charset=utf-8"],
            body: data
        )
    }

    static func text(statusCode: Int, text: String) -> HTTPResponse {
        HTTPResponse(
            statusCode: statusCode,
            headers: ["Content-Type": "text/plain; charset=utf-8"],
            body: Data(text.utf8)
        )
    }

    static func stream(
        statusCode: Int,
        headers: [String: String],
        chunks: [Data]
    ) -> HTTPResponse {
        HTTPResponse(
            statusCode: statusCode,
            headers: headers,
            body: AsyncThrowingStream { continuation in
                for chunk in chunks {
                    continuation.yield(chunk)
                }
                continuation.finish()
            }
        )
    }
}

final class SimpleHTTPServer: @unchecked Sendable {
    typealias RequestHandler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let listener: NWListener
    private let queue: DispatchQueue
    private let handler: RequestHandler
    private let stateLock = NSLock()
    private var isStarted = false
    var port: UInt16? { listener.port?.rawValue }

    init(port: UInt16, handler: @escaping RequestHandler) throws {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw AppError.invalidData(L10n.tr("error.http_server.invalid_port_format", String(port)))
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: parameters, on: nwPort)
        self.queue = DispatchQueue(label: "codex.tools.swift.proxy.listener", qos: .userInitiated)
        self.handler = handler
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection: connection)
        }

        let shouldStart: Bool = stateLock.withLock {
            if isStarted {
                return false
            }
            isStarted = true
            return true
        }

        guard shouldStart else { return }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumeState = ResumeState()

            listener.stateUpdateHandler = { state in
                let action = resumeState.consume(state: state)
                switch action {
                case .resume:
                    continuation.resume()
                case .throwError(let error):
                    continuation.resume(throwing: error)
                case .none:
                    break
                }
            }

            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
        stateLock.withLock {
            isStarted = false
        }
    }

    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(on: connection, buffer: Data())
    }

    private func readRequest(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if error != nil {
                connection.cancel()
                // NSLog("SimpleHTTPServer receive error: \(error.localizedDescription)")
                return
            }

            var working = buffer
            if let data, !data.isEmpty {
                working.append(data)
            }

            if Self.isPayloadOversized(buffer: working) {
                let response = HTTPResponse.text(
                    statusCode: 413,
                    text: L10n.tr(
                        "error.http_server.request_too_large_format",
                        ProxyRuntimeLimits.limitDescription(for: ProxyRuntimeLimits.maxInboundRequestBytes)
                    )
                )
                Task {
                    await self.send(response: response, on: connection)
                }
                return
            }

            if let request = Self.parseRequest(from: working) {
                Task {
                    let response = await self.handler(request)
                    await self.send(response: response, on: connection)
                }
                return
            }

            if isComplete {
                let response = HTTPResponse.text(statusCode: 400, text: "Bad Request")
                Task {
                    await self.send(response: response, on: connection)
                }
                return
            }

            self.readRequest(on: connection, buffer: working)
        }
    }

    private func send(response: HTTPResponse, on connection: NWConnection) async {
        do {
            switch response.body {
            case .data:
                let payload = Self.encode(response: response)
                try await send(payload, on: connection)
            case .stream(let stream):
                let header = Self.encodeStreamingHeader(response: response)
                try await send(header, on: connection)

                for try await chunk in stream {
                    guard !chunk.isEmpty else { continue }
                    try await send(Self.encodeChunk(chunk), on: connection)
                }

                try await send(Data("0\r\n\r\n".utf8), on: connection)
            }
        } catch {
        }

        connection.cancel()
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            })
        }
    }

    private static func parseRequest(from data: Data) -> HTTPRequest? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }

        let headerData = data.subdata(in: 0..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let requestLine = lines.first else {
            return nil
        }

        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else {
            return nil
        }

        let method = String(requestParts[0]).uppercased()
        let target = String(requestParts[1])
        let components = URLComponents(string: target)
        let path = components?.path.isEmpty == false ? (components?.path ?? "/") : (target.split(separator: "?").first.map(String.init) ?? "/")
        let queryItems = components?.queryItems ?? []

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let index = line.firstIndex(of: ":") else { continue }
            let name = line[..<index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: index)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[name] = value
        }

        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headerRange.upperBound
        let expectedEnd = bodyStart + contentLength
        guard data.count >= expectedEnd else {
            return nil
        }

        let body = contentLength == 0 ? Data() : data.subdata(in: bodyStart..<expectedEnd)
        return HTTPRequest(
            method: method,
            target: target,
            path: path,
            queryItems: queryItems,
            headers: headers,
            body: body
        )
    }

    static func isPayloadOversized(buffer: Data) -> Bool {
        if buffer.count > ProxyRuntimeLimits.maxInboundRequestBytes {
            return true
        }
        if let contentLength = extractContentLength(from: buffer),
           contentLength > ProxyRuntimeLimits.maxInboundRequestBytes {
            return true
        }
        return false
    }

    private static func extractContentLength(from data: Data) -> Int? {
        guard let headerRange = data.range(of: Data("\r\n\r\n".utf8)) else {
            return nil
        }

        let headerData = data.subdata(in: 0..<headerRange.lowerBound)
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return nil
        }

        for line in headerText.split(separator: "\r\n", omittingEmptySubsequences: false).dropFirst() {
            guard let index = line.firstIndex(of: ":") else { continue }
            let name = line[..<index].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard name == "content-length" else { continue }
            let value = line[line.index(after: index)...].trimmingCharacters(in: .whitespacesAndNewlines)
            return Int(value)
        }

        return nil
    }

    private static func encode(response: HTTPResponse) -> Data {
        let reason = reasonPhrase(for: response.statusCode)
        let bodyData: Data
        switch response.body {
        case .data(let data):
            bodyData = data
        case .stream:
            bodyData = Data()
        }
        var headerLines: [String] = [
            "HTTP/1.1 \(response.statusCode) \(reason)",
            "Connection: close",
            "Content-Length: \(bodyData.count)"
        ]

        for (key, value) in response.headers {
            headerLines.append("\(key): \(value)")
        }
        headerLines.append("\r\n")

        var output = Data(headerLines.joined(separator: "\r\n").utf8)
        output.append(bodyData)
        return output
    }

    private static func encodeStreamingHeader(response: HTTPResponse) -> Data {
        let reason = reasonPhrase(for: response.statusCode)
        var headerLines: [String] = [
            "HTTP/1.1 \(response.statusCode) \(reason)",
            "Connection: close",
            "Transfer-Encoding: chunked"
        ]

        for (key, value) in response.headers {
            headerLines.append("\(key): \(value)")
        }
        headerLines.append("\r\n")

        return Data(headerLines.joined(separator: "\r\n").utf8)
    }

    private static func encodeChunk(_ chunk: Data) -> Data {
        var output = Data(String(chunk.count, radix: 16).utf8)
        output.append(Data("\r\n".utf8))
        output.append(chunk)
        output.append(Data("\r\n".utf8))
        return output
    }

    private static func reasonPhrase(for statusCode: Int) -> String {
        switch statusCode {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 413: return "Payload Too Large"
        case 404: return "Not Found"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        default: return "HTTP"
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

private final class ResumeState: @unchecked Sendable {
    enum Action {
        case none
        case resume
        case throwError(Error)
    }

    private let lock = NSLock()
    private var hasResumed = false

    func consume(state: NWListener.State) -> Action {
        lock.withLock {
            guard !hasResumed else { return .none }

            switch state {
            case .ready:
                hasResumed = true
                return .resume
            case .failed(let error):
                hasResumed = true
                return .throwError(error)
            case .cancelled:
                hasResumed = true
                return .throwError(AppError.io("HTTP server listener was cancelled"))
            default:
                return .none
            }
        }
    }
}
