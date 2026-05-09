import XCTest
@testable import Copool

final class EndpointRequestCoordinatorTests: XCTestCase {
    override func tearDown() {
        super.tearDown()
        MockURLProtocol.store.reset()
    }

    func testFetchFirstSuccessfulRecordsPreferredEndpointForNextRequest() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let preferenceStore = EndpointPreferenceStore()
        let coordinator = EndpointRequestCoordinator(
            session: session,
            preferenceStore: preferenceStore
        )

        let primary = "https://primary.example.com/value"
        let fallback = "https://fallback.example.com/value"
        let tertiary = "https://tertiary.example.com/value"

        MockURLProtocol.store.setHandler { request in
            let url = try XCTUnwrap(request.url?.absoluteString)

            switch url {
            case primary:
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 500,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data("primary failed".utf8)
                )
            case fallback:
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data(#"{"ok":true}"#.utf8)
                )
            default:
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 503,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data()
                )
            }
        }

        _ = try await coordinator.fetchFirstSuccessful(
            scope: "usage",
            candidateURLs: [primary, fallback, tertiary]
        ) { URLRequest(url: $0) }

        MockURLProtocol.store.resetRequestedURLs()

        let result = try await coordinator.fetchFirstSuccessful(
            scope: "usage",
            candidateURLs: [primary, fallback, tertiary]
        ) { URLRequest(url: $0) }

        let requestedURLs = MockURLProtocol.store.requestedURLs()
        XCTAssertEqual(result.endpoint, fallback)
        XCTAssertEqual(requestedURLs, [fallback])
    }

    func testFetchFirstSuccessfulFallsBackWhenPreferredEndpointValidationFails() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let preferenceStore = EndpointPreferenceStore()
        let coordinator = EndpointRequestCoordinator(
            session: session,
            preferenceStore: preferenceStore
        )

        let primary = "https://primary.example.com/value"
        let fallback = "https://fallback.example.com/value"

        MockURLProtocol.store.setHandler { request in
            let url = try XCTUnwrap(request.url?.absoluteString)

            switch url {
            case primary:
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data(#"{"unexpected":true}"#.utf8)
                )
            case fallback:
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data(#"{"ok":true}"#.utf8)
                )
            default:
                return (
                    HTTPURLResponse(
                        url: try XCTUnwrap(request.url),
                        statusCode: 503,
                        httpVersion: nil,
                        headerFields: nil
                    )!,
                    Data()
                )
            }
        }

        let firstResult = try await coordinator.fetchFirstSuccessful(
            scope: "usage",
            candidateURLs: [primary, fallback]
        ) { URLRequest(url: $0) } validate: { result in
            try JSONDecoder().decode(DecodeCheck.self, from: result.data)
        }

        XCTAssertTrue(firstResult.ok)

        MockURLProtocol.store.resetRequestedURLs()

        let secondResult = try await coordinator.fetchFirstSuccessful(
            scope: "usage",
            candidateURLs: [primary, fallback]
        ) { URLRequest(url: $0) } validate: { result in
            try JSONDecoder().decode(DecodeCheck.self, from: result.data)
        }

        let requestedURLs = MockURLProtocol.store.requestedURLs()
        XCTAssertTrue(secondResult.ok)
        XCTAssertEqual(requestedURLs, [fallback])
    }
}

private struct DecodeCheck: Decodable {
    let ok: Bool
}

private final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    static let store = MockURLProtocolStore()

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let currentRequest = request
        let context = URLProtocolTaskContext(protocolInstance: self, client: client)
        do {
            MockURLProtocol.store.record(request: currentRequest)
            guard let handler = MockURLProtocol.store.handler() else {
                context.client?.urlProtocol(context.protocolInstance, didFailWithError: URLError(.badServerResponse))
                return
            }

            let (response, data) = try handler(currentRequest)
            context.client?.urlProtocol(context.protocolInstance, didReceive: response, cacheStoragePolicy: .notAllowed)
            context.client?.urlProtocol(context.protocolInstance, didLoad: data)
            context.client?.urlProtocolDidFinishLoading(context.protocolInstance)
        } catch {
            context.client?.urlProtocol(context.protocolInstance, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

private struct URLProtocolTaskContext: @unchecked Sendable {
    let protocolInstance: URLProtocol
    let client: URLProtocolClient?
}

private final class MockURLProtocolStore: @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) throws -> (HTTPURLResponse, Data)

    private let lock = NSLock()
    private var currentHandler: Handler?
    private var requestedURLValues: [String] = []

    func setHandler(_ handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        currentHandler = handler
    }

    func handler() -> Handler? {
        lock.lock()
        defer { lock.unlock() }
        return currentHandler
    }

    func record(request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        if let url = request.url?.absoluteString {
            requestedURLValues.append(url)
        }
    }

    func requestedURLs() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return requestedURLValues
    }

    func resetRequestedURLs() {
        lock.lock()
        defer { lock.unlock() }
        requestedURLValues = []
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        currentHandler = nil
        requestedURLValues = []
    }
}
