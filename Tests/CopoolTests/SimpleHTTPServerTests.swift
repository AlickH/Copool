import XCTest
import Network
import Darwin
@testable import Copool

final class SimpleHTTPServerTests: XCTestCase {
    func testStartThrowsWhenPortAlreadyInUse() async throws {
        let occupier = try PortOccupier(port: 0)
        let occupiedPort = occupier.port

        let server = try SimpleHTTPServer(port: occupiedPort) { _ in
            HTTPResponse.text(statusCode: 200, text: "ok")
        }

        do {
            try await server.start()
            XCTFail("Expected start to fail when the port is already in use")
        } catch {
            XCTAssertFalse(error.localizedDescription.isEmpty)
        }
    }

    func testStreamingResponseUsesChunkedEncoding() async throws {
        let server = try SimpleHTTPServer(port: 0) { _ in
            HTTPResponse.stream(
                statusCode: 200,
                headers: ["Content-Type": "text/event-stream; charset=utf-8"],
                chunks: [
                    Data("data: first\n\n".utf8),
                    Data("data: second\n\n".utf8)
                ]
            )
        }

        try await server.start()
        defer { server.stop() }
        let port = try XCTUnwrap(server.port)

        let payload = try await rawHTTPResponse(
            port: port,
            request: "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
        )

        let text = String(decoding: payload, as: UTF8.self)
        XCTAssertTrue(text.contains("Transfer-Encoding: chunked"))
        XCTAssertTrue(text.contains("\r\n\r\nd\r\ndata: first\n\n\r\n"))
        XCTAssertTrue(text.contains("\r\ne\r\ndata: second\n\n\r\n0\r\n\r\n"))
    }
}

private final class PortOccupier {
    private let fileDescriptor: Int32
    let port: UInt16

    init(port: UInt16) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(fd)
            throw POSIXError(code)
        }

        guard listen(fd, 1) == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(fd)
            throw POSIXError(code)
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                getsockname(fd, sockaddrPointer, &length)
            }
        }
        guard nameResult == 0 else {
            let code = POSIXErrorCode(rawValue: errno) ?? .EIO
            close(fd)
            throw POSIXError(code)
        }
        self.fileDescriptor = fd
        self.port = UInt16(bigEndian: boundAddress.sin_port)
    }

    deinit {
        close(fileDescriptor)
    }
}

private func rawHTTPResponse(port: UInt16, request: String) async throws -> Data {
    let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    let queue = DispatchQueue(label: "SimpleHTTPServerTests.Client")
    connection.start(queue: queue)
    defer { connection.cancel() }

    try await waitForReady(connection)
    try await sendRequest(connection, data: Data(request.utf8))

    var response = Data()
    while true {
        let chunk = try await receiveChunk(connection)
        if chunk.isEmpty { break }
        response.append(chunk)
    }

    return response
}

private func waitForReady(_ connection: NWConnection) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let state = ConnectionResumeState()
        connection.stateUpdateHandler = { newState in
            switch state.consume(state: newState) {
            case .resume:
                continuation.resume()
            case .throwError(let error):
                continuation.resume(throwing: error)
            case .none:
                break
            }
        }
    }
}

private func sendRequest(_ connection: NWConnection, data: Data) async throws {
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

private func receiveChunk(_ connection: NWConnection) async throws -> Data {
    try await withCheckedThrowingContinuation { continuation in
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { data, _, isComplete, error in
            if let error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: isComplete ? (data ?? Data()) : (data ?? Data()))
            }
        }
    }
}

private final class TestResumeState: @unchecked Sendable {
    enum Action {
        case none
        case resume
        case throwError(Error)
    }

    private let lock = NSLock()
    private var hasResumed = false

    func consume(state: NWListener.State) -> Action {
        lock.lock()
        defer { lock.unlock() }

        guard !hasResumed else { return .none }

        switch state {
        case .ready:
            hasResumed = true
            return .resume
        case .failed(let error):
            hasResumed = true
            return .throwError(error)
        default:
            return .none
        }
    }
}

private final class ConnectionResumeState: @unchecked Sendable {
    enum Action {
        case none
        case resume
        case throwError(Error)
    }

    private let lock = NSLock()
    private var hasResumed = false

    func consume(state: NWConnection.State) -> Action {
        lock.lock()
        defer { lock.unlock() }

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
            return .throwError(XCTestError(.failureWhileWaiting))
        default:
            return .none
        }
    }
}
