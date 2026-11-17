import XCTest
@testable import Pecule

final class GatewayAuthClientTests: XCTestCase {
    private let baseURL = URL(string: "https://gateway.test/")!

    private func makeClient(baseURL: URL?) -> LiveGatewayAuthClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return LiveGatewayAuthClient(
            session: URLSession(configuration: configuration),
            userAgent: "Pecule-tests/1.0",
            baseURLProvider: { baseURL }
        )
    }

    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testChallengeIsPublicAndParsesUnixMilliseconds() async throws {
        let recorder = AuthRequestRecorder()
        StubURLProtocol.handler = { request in
            recorder.record(request)
            return (201, Data(#"{"challengeId":"c-1","nonce":"deadbeef","expiresAt":1789371562000}"#.utf8))
        }

        let challenge = try await makeClient(baseURL: baseURL).startChallenge()

        XCTAssertEqual(challenge.challengeId, "c-1")
        XCTAssertEqual(challenge.nonce, "deadbeef")
        XCTAssertEqual(challenge.expiresAt, Date(timeIntervalSince1970: 1_789_371_562))
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://gateway.test/v1/auth/apple/challenge")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "the challenge must never carry a bearer")
    }

    func testSignInSendsOnlyTheChallengeAndTheIdentityToken() async throws {
        let recorder = AuthRequestRecorder()
        StubURLProtocol.handler = { request in
            recorder.record(request)
            return (201, Data(#"{"token":"abc","userId":"apple_42","expiresAt":1789374862000}"#.utf8))
        }

        let session = try await makeClient(baseURL: baseURL).completeSignIn(challengeId: "c-1", identityToken: "apple.jwt")

        XCTAssertEqual(session.token, "abc")
        XCTAssertEqual(session.userId, "apple_42")
        XCTAssertEqual(session.expiresAt, Date(timeIntervalSince1970: 1_789_374_862))
        let request = try XCTUnwrap(recorder.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://gateway.test/v1/auth/apple/session")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), "sign-in is authenticated by Apple, not by a bearer")
        let body = try XCTUnwrap(recorder.bodies.first)
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(payload, ["challengeId": "c-1", "identityToken": "apple.jwt"], "no userId is ever sent by the client")
    }

    func testSessionRoutesCarryTheUserTokenAsBearer() async throws {
        let recorder = AuthRequestRecorder()
        StubURLProtocol.handler = { request in
            recorder.record(request)
            return (200, Data(#"{"userId":"apple_42"}"#.utf8))
        }
        let client = makeClient(baseURL: baseURL)

        let userId = try await client.currentUserID(token: "session-token")
        try await client.signOut(token: "session-token")

        XCTAssertEqual(userId, "apple_42")
        XCTAssertEqual(recorder.requests.map(\.httpMethod), ["GET", "DELETE"])
        XCTAssertEqual(recorder.requests.map { $0.url?.path }, ["/v1/session", "/v1/session"])
        for request in recorder.requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
        }
    }

    func testErrorsAreMappedFromTheGatewayEnvelope() async {
        let cases: [(Int, String, GatewayAuthError)] = [
            (401, #"{"error":"invalid_identity"}"#, .invalidIdentity),
            (401, #"{"error":"unauthorized"}"#, .unauthorized),
            (429, #"{"error":"too_many_requests","retryAfterSeconds":42}"#, .rateLimited(retryAfterSeconds: 42)),
            (503, #"{"error":"authentication_unavailable"}"#, .unavailable),
            (400, #"{"error":"invalid_request"}"#, .http(status: 400, code: "invalid_request")),
        ]
        for (status, body, expected) in cases {
            StubURLProtocol.handler = { _ in (status, Data(body.utf8)) }
            do {
                _ = try await makeClient(baseURL: baseURL).startChallenge()
                XCTFail("expected \(expected)")
            } catch let error as GatewayAuthError {
                XCTAssertEqual(error, expected)
            } catch {
                XCTFail("unexpected \(error)")
            }
        }
    }

    func testMissingBaseURLIsNotConfigured() async {
        do {
            _ = try await makeClient(baseURL: nil).startChallenge()
            XCTFail("expected notConfigured")
        } catch let error as GatewayAuthError {
            XCTAssertEqual(error, .notConfigured)
        } catch {
            XCTFail("unexpected \(error)")
        }
    }
}

final class AuthRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [URLRequest] = []
    private var bodyStorage: [Data] = []

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    var bodies: [Data] {
        lock.lock(); defer { lock.unlock() }
        return bodyStorage
    }

    func record(_ request: URLRequest) {
        lock.lock()
        storage.append(request)
        // URLProtocol strips httpBody into a stream; read it back so the payload can be asserted.
        if let body = request.httpBody ?? request.httpBodyStream.map(Self.drain) {
            bodyStorage.append(body)
        }
        lock.unlock()
    }

    private static func drain(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        let size = 4096
        var buffer = [UInt8](repeating: 0, count: size)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: size)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
