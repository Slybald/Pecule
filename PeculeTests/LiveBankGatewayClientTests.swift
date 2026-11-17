import XCTest
@testable import Pecule

final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) -> (Int, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler, let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (status, data) = handler(request)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class LiveBankGatewayClientTests: XCTestCase {
    private let configuration = BankGatewayConfiguration(
        baseURL: URL(string: "https://gateway.test/")!,
        bearerToken: "secret-token"
    )

    private func makeClient(configuration: BankGatewayConfiguration?) -> LiveBankGatewayClient {
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [StubURLProtocol.self]
        return LiveBankGatewayClient(
            session: URLSession(configuration: sessionConfiguration),
            userAgent: "Pecule-tests/1.0",
            configurationProvider: { configuration }
        )
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testThrowsWhenNotConfigured() async {
        let client = makeClient(configuration: nil)
        do {
            _ = try await client.balances(accountUID: "acc", attended: false)
            XCTFail("expected notConfigured")
        } catch let error as BankGatewayError {
            XCTAssertEqual(error, .notConfigured)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testBalancesRequestCarriesBearerUserAgentAndAttendedFlag() async throws {
        let captured = CapturedRequest()
        StubURLProtocol.handler = { request in
            captured.store(request)
            return (200, Data(#"{"balances":[{"balance_amount":{"currency":"EUR","amount":"10.00"},"balance_type":"CLBD"}]}"#.utf8))
        }
        let client = makeClient(configuration: configuration)

        let balances = try await client.balances(accountUID: "acc-1", attended: true)

        XCTAssertEqual(balances.map(\.amount), [Decimal(10)])
        let request = try XCTUnwrap(captured.request)
        XCTAssertEqual(request.url?.absoluteString, "https://gateway.test/v1/accounts/acc-1/balances?attended=1")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Pecule-tests/1.0")
    }

    func testProbeChecksHealthWithoutBearerThenListsBanksWithIt() async throws {
        let recorder = RequestRecorder()
        StubURLProtocol.handler = { request in
            recorder.record(request)
            if request.url?.path == "/healthz" {
                return (200, Data(#"{"ok":true,"environment":"production"}"#.utf8))
            }
            return (200, Data(#"{"aspsps":[{"name":"Boursorama Banque","country":"FR"},{"name":"Revolut","country":"FR"}]}"#.utf8))
        }
        let client = makeClient(configuration: nil)

        let probe = try await client.probe(configuration)

        XCTAssertEqual(probe, BankGatewayProbe(environment: "production", aspspCount: 2))
        let requests = recorder.requests
        XCTAssertEqual(requests.map { $0.url?.path }, ["/healthz", "/v1/aspsps"])
        XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"), "the health check is public")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer secret-token")
        XCTAssertEqual(requests[1].url?.query, "country=FR")
    }

    func testProbeReportsARefusedBearer() async {
        StubURLProtocol.handler = { request in
            request.url?.path == "/healthz"
                ? (200, Data(#"{"ok":true,"environment":"sandbox"}"#.utf8))
                : (401, Data(#"{"error":"unauthorized"}"#.utf8))
        }
        let client = makeClient(configuration: nil)

        do {
            _ = try await client.probe(configuration)
            XCTFail("expected unauthorized")
        } catch let error as BankGatewayError {
            XCTAssertEqual(error, .unauthorized)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testTransactionsRequestSerialisesQueryWithoutAttendedFlag() async throws {
        let captured = CapturedRequest()
        StubURLProtocol.handler = { request in
            captured.store(request)
            return (200, Data(#"{"transactions":[],"continuation_key":"next"}"#.utf8))
        }
        let client = makeClient(configuration: configuration)
        let query = BankTransactionsQuery(
            dateFrom: BankGatewayDateParser.parseDay("2026-08-01"),
            dateTo: BankGatewayDateParser.parseDay("2026-09-14"),
            continuationKey: "k1",
            strategy: "longest"
        )

        let page = try await client.transactions(accountUID: "acc-1", query: query, attended: false)

        XCTAssertEqual(page.continuationKey, "next")
        XCTAssertTrue(page.transactions.isEmpty)
        let url = try XCTUnwrap(captured.request?.url)
        XCTAssertEqual(url.path, "/v1/accounts/acc-1/transactions")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(
            Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") }),
            ["date_from": "2026-08-01", "date_to": "2026-09-14", "continuation_key": "k1", "strategy": "longest"]
        )
    }

    func testStartLinkPostsToLinksAndDecodesResponse() async throws {
        let captured = CapturedRequest()
        StubURLProtocol.handler = { request in
            captured.store(request)
            return (201, Data(#"{"linkId":"l1","authUrl":"https://bank.test/authorize","validUntil":"2027-03-13T07:39:07.434000Z"}"#.utf8))
        }
        let client = makeClient(configuration: configuration)

        let start = try await client.startLink(institution: .mock)

        XCTAssertEqual(start.linkId, "l1")
        XCTAssertEqual(start.authUrl.absoluteString, "https://bank.test/authorize")
        XCTAssertEqual(captured.request?.httpMethod, "POST")
        XCTAssertEqual(captured.request?.url?.path, "/v1/links")
        XCTAssertEqual(captured.request?.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testMapsSessionExpiredAndDeleteSucceedsOnNoContent() async throws {
        StubURLProtocol.handler = { request in
            request.httpMethod == "DELETE" ? (204, Data()) : (409, Data(#"{"error":"session_expired"}"#.utf8))
        }
        let client = makeClient(configuration: configuration)

        do {
            _ = try await client.link(id: "l1")
            XCTFail("expected sessionExpired")
        } catch let error as BankGatewayError {
            XCTAssertEqual(error, .sessionExpired)
        }
        try await client.deleteLink(id: "l1")
    }
}

private final class CapturedRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URLRequest?

    var request: URLRequest? {
        lock.withLock { stored }
    }

    func store(_ request: URLRequest) {
        lock.withLock { stored = request }
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ request: URLRequest) {
        lock.lock()
        storage.append(request)
        lock.unlock()
    }
}
