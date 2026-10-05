import Foundation
import XCTest
@testable import KComms

private final class MemoryVault: CredentialVault, @unchecked Sendable {
    private let lock = NSLock(); private var value: CredentialEnvelope?
    init(_ value: CredentialEnvelope? = nil) { self.value = value }
    func load() throws -> CredentialEnvelope? { lock.lock(); defer { lock.unlock() }; return value }
    func save(_ value: CredentialEnvelope) throws { lock.lock(); defer { lock.unlock() }; self.value = value }
    func clear() throws { lock.lock(); defer { lock.unlock() }; value = nil }
}
private final class ProtocolStub: URLProtocol, @unchecked Sendable {
    struct Reply { let status: Int; let data: Data; var delay: Double = 0 }
    static var handler: ((URLRequest) throws -> Reply)?
    private var pending: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }; let result = try handler(request)
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: result.status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: result.data); self.client?.urlProtocolDidFinishLoading(self)
            }
            pending = work; DispatchQueue.global().asyncAfter(deadline: .now() + result.delay, execute: work)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { pending?.cancel(); pending = nil }
}
final class ApiClientTests: XCTestCase {
    private let tenant = "00000000-0000-0000-0000-000000000001", user = "00000000-0000-0000-0000-000000000002", device = "00000000-0000-0000-0000-000000000003"
    private func fixture(token: String = "synthetic-access", scope: String = "workspace", role: String = "member", version: Int = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["access_token": token, "refresh_token": "synthetic-refresh", "token_type": "Bearer", "expires_in": 60,
            "tenant": ["id": tenant, "name": "Synthetic workspace", "slug": "synthetic", "status": "active"],
            "user": ["id": user, "tenant_id": tenant, "display_name": "Synthetic member", "account_type": "human", "access_scope": scope, "role": role, "status": "active", "version": version],
            "device": ["id": device, "user_id": user, "name": "Synthetic iOS", "platform": "ios"]])
    }
    private func meFixture(scope: String = "workspace", role: String = "member", version: Int = 1) throws -> Data {
        var object = try JSONSerialization.jsonObject(with: fixture(scope: scope, role: role, version: version)) as! [String: Any]
        object["capabilities"] = ["allow_audio_calls": true, "allow_video_calls": true, "allow_public_channels": false]
        return try JSONSerialization.data(withJSONObject: object)
    }
    private func transport() -> URLSession { let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [ProtocolStub.self]; return URLSession(configuration: configuration) }
    override func tearDown() { ProtocolStub.handler = nil; super.tearDown() }
    func testCallParticipantsRequireExactCurrentAdmissionAndPropagateWithdrawal() async throws {
        let original = try Wire.decoder().decode(MemberSession.self, from: fixture())
        let vault = MemoryVault(.init(serverOrigin: "https://synthetic.example", session: original, accessExpiresAt: .distantFuture))
        ProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/conversations/00000000-0000-0000-0000-000000000001/calls/00000000-0000-0000-0000-000000000002/participants")
            XCTAssertEqual(request.url?.query, "current_admission=true")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-access")
            return .init(status: 403, data: Data("{\"error\":{\"code\":\"forbidden\"}}".utf8))
        }
        let client = try ApiClient(origin: "https://synthetic.example", vault: vault, transport: transport())
        let call = Call(id: user, conversationId: tenant, mediaKind: "audio", status: "active", expiresAt: "2026-10-06T00:00:00Z", canEnd: false)
        do { _ = try await client.participants(call); XCTFail("Revoked current admission returned another device's participants") }
        catch let error as NativeApiError { XCTAssertEqual(error.status, 403) }
        let current = await client.currentSession(); XCTAssertNotNil(current)
    }
    func testNativeRegistrationUsesActualOwnerRoutesWithoutTokenInURL() async throws {
        let original = try Wire.decoder().decode(MemberSession.self, from: fixture())
        let vault = MemoryVault(.init(serverOrigin: "https://synthetic.example", session: original, accessExpiresAt: .distantFuture))
        let receipt: [String: Any] = ["id": user, "device_id": device, "version": 1, "platform": "ios", "channel": "apns_voip", "application_id": "com.synthetic.native", "environment": "sandbox", "status": "active", "expires_at": "2026-10-06T00:00:00Z"]
        ProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/me/native-push/registration"); XCTAssertNil(request.url?.query)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-access")
            XCTAssertEqual(request.httpMethod, "PUT")
            return .init(status: 200, data: try JSONSerialization.data(withJSONObject: ["data": receipt, "replayed": false]))
        }
        let client = try ApiClient(origin: "https://synthetic.example", vault: vault, transport: transport())
        let result = try await client.registerNativePush(channel: "apns_voip", application: "com.synthetic.native", environment: "sandbox",
            token: String(repeating: "a", count: 64), installation: user, version: 0)
        XCTAssertEqual(result.registration.deviceId, device); XCTAssertFalse(result.replayed)
    }
    func testUncertainNativeAdmissionNeverAutomaticallyReplays() async throws {
        let original = try Wire.decoder().decode(MemberSession.self, from: fixture())
        let vault = MemoryVault(.init(serverOrigin: "https://synthetic.example", session: original, accessExpiresAt: .distantFuture))
        let once = expectation(description: "Exactly one native admission"); once.assertForOverFulfill = true
        ProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/native-call-wakes/00000000-0000-0000-0000-000000000002/admit")
            XCTAssertNil(request.url?.query); XCTAssertEqual(request.httpMethod, "POST"); once.fulfill()
            return .init(status: 503, data: Data("{}".utf8))
        }
        let client = try ApiClient(origin: "https://synthetic.example", vault: vault, transport: transport())
        do { _ = try await client.admitNativeWake(user); XCTFail("Uncertain admission succeeded") }
        catch let error as NativeApiError { XCTAssertEqual(error.status, 503) }
        await fulfillment(of: [once], timeout: 2)
        let current = await client.currentSession(); XCTAssertNotNil(current)
    }
    func testPhoneWakeWorkspaceFenceCannotSurviveWithdrawalAndRegrant() async throws {
        let original = try Wire.decoder().decode(MemberSession.self, from: fixture())
        let vault = MemoryVault(.init(serverOrigin: "https://synthetic.example", session: original, accessExpiresAt: .distantFuture))
        let limited = try meFixture(scope: "conversation_only", version: 2), regranted = try meFixture(version: 3)
        ProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/me")
            return .init(status: 200, data: limited)
        }
        let client = try ApiClient(origin: "https://synthetic.example", vault: vault, transport: transport())
        let stamp = try await client.stamp(); let workspace = try await client.captureWorkspaceAuthority(stamp)
        _ = try await client.me(); ProtocolStub.handler = { _ in .init(status: 200, data: regranted) }; _ = try await client.me()
        do { try await client.assertWorkspaceAuthority(workspace, stamp: stamp); XCTFail("Old phone admission fence survived withdrawal") }
        catch NativeClientError.workspaceUnavailable { }
        try await client.assertCurrent(stamp); let current = await client.currentSession(); XCTAssertTrue(current?.user.hasWorkspaceAccess == true)
    }
    func testOriginRejectsCredentialPathQueryAndPlainHTTP() {
        for value in ["http://synthetic.example", "https://user:password@synthetic.example", "https://synthetic.example/api", "https://synthetic.example?token=x", "https://synthetic.example#fragment"] { XCTAssertThrowsError(try ApiClient.validatedOrigin(value)) }
        XCTAssertEqual(try ApiClient.validatedOrigin("https://SYNTHETIC.EXAMPLE/").absoluteString, "https://synthetic.example")
    }
    func testActualMfaEndpointUsesChallengeWithoutPasswordOrBearer() async throws {
        let data = try fixture(); let vault = MemoryVault()
        ProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/auth/mfa"); XCTAssertEqual(request.httpMethod, "POST"); XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            let bytes = request.httpBody ?? request.httpBodyStream.map { stream -> Data in stream.open(); defer { stream.close() }; var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024); while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }; return data } ?? Data()
            let body = try JSONSerialization.jsonObject(with: bytes) as! [String: String]
            XCTAssertEqual(body, ["challenge_token": "synthetic-challenge", "code": "123456"]); return .init(status: 200, data: data)
        }
        let client = try ApiClient(origin: "https://synthetic.example", vault: vault, transport: transport())
        let session = try await client.completeMfa(challenge: "synthetic-challenge", code: "123456")
        XCTAssertEqual(session.identity.user, user); XCTAssertNotNil(try vault.load()?.accessExpiresAt)
    }
    func testPasswordSignInDecodesMfaChallengeWithoutInstallingCredentials() async throws {
        let vault = MemoryVault()
        ProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/sessions"); XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return .init(status: 200, data: Data("{\"mfa_required\":true,\"challenge_token\":\"synthetic-challenge\",\"expires_in\":60}".utf8))
        }
        let client = try ApiClient(origin: "https://synthetic.example", vault: vault, transport: transport())
        let result = try await client.passwordSignIn(tenant: "synthetic", email: "member@example.test", password: "synthetic-only")
        guard case .mfa(let challenge) = result else { XCTFail("Expected an actual typed MFA challenge"); return }
        XCTAssertEqual(challenge.expiresIn, 60); XCTAssertEqual(challenge.challengeToken, "synthetic-challenge")
        XCTAssertNil(try vault.load()); let current = await client.currentSession(); XCTAssertNil(current)
    }
    func testPasswordSignInRefusesExpiredOrEmptyMfaChallenge() async throws {
        for challenge in [("synthetic-challenge", 0), ("", 60)] {
            let vault = MemoryVault()
            ProtocolStub.handler = { _ in
                .init(status: 200, data: try JSONSerialization.data(withJSONObject: ["mfa_required": true, "challenge_token": challenge.0, "expires_in": challenge.1]))
            }
            let client = try ApiClient(origin: "https://synthetic.example", vault: vault, transport: transport())
            do { _ = try await client.passwordSignIn(tenant: "synthetic", email: "member@example.test", password: "synthetic-only"); XCTFail("An unusable challenge must be refused") }
            catch NativeClientError.invalidResponse { } catch { XCTFail("Unexpected error: \(type(of: error))") }
            XCTAssertNil(try vault.load()); let current = await client.currentSession(); XCTAssertNil(current)
        }
    }
    func testConversationOnlyHumanSignInPreservesScopedCommunication() async throws {
        let data = try fixture(scope: "conversation_only"); let vault = MemoryVault()
        ProtocolStub.handler = { request in
            if request.url?.path == "/api/v1/sessions" { return .init(status: 200, data: data) }
            XCTAssertEqual(request.url?.path, "/api/v1/conversations"); return .init(status: 200, data: Data("{\"data\":[]}".utf8))
        }
        let client = try ApiClient(origin: "https://synthetic.example", vault: vault, transport: transport())
        _ = try await client.passwordSignIn(tenant: "synthetic", email: "member@example.test", password: "synthetic-only")
        let current = await client.currentSession(); XCTAssertTrue(current?.user.isNativeMember == true); XCTAssertFalse(current?.user.hasWorkspaceAccess == true)
        let rooms = try await client.conversations(); XCTAssertTrue(rooms.isEmpty); XCTAssertNotNil(try vault.load())
    }
    func testCurrentScopeWithdrawalRefusesWorkspaceAndRetainsConversationSession() async throws {
        let original = try Wire.decoder().decode(MemberSession.self, from: fixture()), narrowed = try meFixture(scope: "conversation_only", version: 2)
        let vault = MemoryVault(.init(serverOrigin: "https://synthetic.example", session: original, accessExpiresAt: .distantFuture))
        ProtocolStub.handler = { request in
            if request.url?.path == "/api/v1/me" { return .init(status: 200, data: narrowed) }
            XCTAssertEqual(request.url?.path, "/api/v1/conversations", "A withdrawn workspace scope must not reach directory")
            return .init(status: 200, data: Data("{\"data\":[]}".utf8))
        }
        let client = try ApiClient(origin: "https://synthetic.example", vault: vault, transport: transport())
        do { _ = try await client.directory(query: ""); XCTFail("Current owner workspace access was withdrawn") }
        catch NativeClientError.workspaceUnavailable { } catch { XCTFail("Unexpected error: \(type(of: error))") }
        let current = await client.currentSession(); XCTAssertEqual(current?.user.accessScope, "conversation_only")
        XCTAssertEqual(try vault.load()?.session.user.accessScope, "conversation_only")
        let rooms = try await client.conversations(); XCTAssertTrue(rooms.isEmpty)
    }
    func testLegitimateRoleChangeUpdatesOwnerMetadataWithoutRevokingSession() async throws {
        let original = try Wire.decoder().decode(MemberSession.self, from: fixture(role: "admin")), current = try meFixture(role: "member", version: 2)
        let vault = MemoryVault(.init(serverOrigin: "https://synthetic.example", session: original, accessExpiresAt: .distantFuture))
        ProtocolStub.handler = { request in XCTAssertEqual(request.url?.path, "/api/v1/me"); return .init(status: 200, data: current) }
        let client = try ApiClient(origin: "https://synthetic.example", vault: vault, transport: transport()); let stamp = try await client.stamp()
        let me = try await client.me(); XCTAssertEqual(me.user.role, "member"); try await client.assertCurrent(stamp)
        let session = await client.currentSession(); XCTAssertEqual(session?.user.role, "member"); XCTAssertEqual(try vault.load()?.session.user.role, "member")
    }
    func testSupersededOwnerProjectionCannotRestoreWorkspaceOrClearValidSession() async throws {
        let original = try Wire.decoder().decode(MemberSession.self, from: fixture(scope: "conversation_only", version: 2))
        let stale = try meFixture(version: 1), vault = MemoryVault(.init(serverOrigin: "https://synthetic.example", session: original, accessExpiresAt: .distantFuture))
        let reads = expectation(description: "bounded owner reread"); reads.expectedFulfillmentCount = 2
        ProtocolStub.handler = { request in XCTAssertEqual(request.url?.path, "/api/v1/me"); reads.fulfill(); return .init(status: 200, data: stale) }
        let client = try ApiClient(origin: "https://synthetic.example", vault: vault, transport: transport()), stamp = try await client.stamp()
        do { _ = try await client.me(); XCTFail("A superseded projection must not expand owner access") }
        catch NativeClientError.ownerProjectionSuperseded { } catch { XCTFail("Unexpected error: \(type(of: error))") }
        await fulfillment(of: [reads], timeout: 2); try await client.assertCurrent(stamp)
        XCTAssertEqual(try vault.load()?.session.user.accessScope, "conversation_only")
        let current = await client.currentSession(); XCTAssertEqual(current?.user.version, 2)
    }
    func testWorkspaceReplyIsRejectedAcrossWithdrawalAndRegrant() async throws {
        let original = try Wire.decoder().decode(MemberSession.self, from: fixture())
        let owners = try [meFixture(), meFixture(scope: "conversation_only", version: 2), meFixture(version: 3)]
        let vault = MemoryVault(.init(serverOrigin: "https://synthetic.example", session: original, accessExpiresAt: .distantFuture))
        let started = expectation(description: "directory started"), lock = NSLock(); var read = 0
        ProtocolStub.handler = { request in
            if request.url?.path == "/api/v1/me" { lock.lock(); let index = read; read += 1; lock.unlock(); return .init(status: 200, data: owners[index]) }
            XCTAssertEqual(request.url?.path, "/api/v1/directory/users"); started.fulfill()
            return .init(status: 200, data: Data("{\"data\":[],\"page\":{\"next_cursor\":null}}".utf8), delay: 0.3)
        }
        let client = try ApiClient(origin: "https://synthetic.example", vault: vault, transport: transport())
        let pending = Task { try await client.directory(query: "") }
        await fulfillment(of: [started], timeout: 2)
        let withdrawn = try await client.me(); XCTAssertFalse(withdrawn.user.hasWorkspaceAccess)
        let regranted = try await client.me(); XCTAssertTrue(regranted.user.hasWorkspaceAccess)
        do { _ = try await pending.value; XCTFail("Earlier workspace replies must not survive an eligibility transition") }
        catch NativeClientError.workspaceUnavailable { } catch { XCTFail("Unexpected error: \(type(of: error))") }
        XCTAssertEqual(try vault.load()?.session.user.version, 3)
    }
    func testDelayedRefreshRotatesCredentialsWithoutRestoringSupersededOwnerMetadata() async throws {
        let original = try Wire.decoder().decode(MemberSession.self, from: fixture())
        let rotated = try fixture(token: "synthetic-rotated-access"), narrowed = try meFixture(scope: "conversation_only", version: 2)
        let vault = MemoryVault(.init(serverOrigin: "https://synthetic.example", session: original, accessExpiresAt: .distantFuture))
        let started = expectation(description: "rotation started")
        ProtocolStub.handler = { request in
            if request.url?.path == "/api/v1/sessions/refresh" { started.fulfill(); return .init(status: 200, data: rotated, delay: 0.3) }
            if request.url?.path == "/api/v1/me" { return .init(status: 200, data: narrowed) }
            XCTAssertEqual(request.url?.path, "/api/v1/conversations")
            if request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access" { return .init(status: 401, data: Data("{\"error\":{\"code\":\"expired_access\"}}".utf8)) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-rotated-access")
            return .init(status: 200, data: Data("{\"data\":[]}".utf8))
        }
        let client = try ApiClient(origin: "https://synthetic.example", vault: vault, transport: transport()), stamp = try await client.stamp()
        let pending = Task { try await client.conversations() }
        await fulfillment(of: [started], timeout: 2); _ = try await client.me()
        let rooms = try await pending.value; XCTAssertTrue(rooms.isEmpty); try await client.assertCurrent(stamp)
        let current = await client.currentSession(); XCTAssertEqual(current?.accessToken, "synthetic-rotated-access")
        XCTAssertEqual(current?.user.accessScope, "conversation_only"); XCTAssertEqual(current?.user.version, 2)
        XCTAssertEqual(try vault.load()?.session.user.version, 2)
    }
    func testPasswordSignInRefusesUnknownScopeAndNonPositiveOwnerVersion() async throws {
        for invalid in [try fixture(scope: "unknown"), try fixture(version: 0)] {
            let vault = MemoryVault(); ProtocolStub.handler = { _ in .init(status: 200, data: invalid) }
            let client = try ApiClient(origin: "https://synthetic.example", vault: vault, transport: transport())
            do { _ = try await client.passwordSignIn(tenant: "synthetic", email: "member@example.test", password: "synthetic-only"); XCTFail("Unsupported owner metadata must fail closed") }
            catch NativeClientError.invalidResponse { } catch { XCTFail("Unexpected error: \(type(of: error))") }
            XCTAssertNil(try vault.load())
        }
    }
    func testExpiredPersistedAccessRefreshesBeforeAuthenticatedRead() async throws {
        let original = try Wire.decoder().decode(MemberSession.self, from: fixture()); let refreshed = try fixture(token: "synthetic-new-access")
        let vault = MemoryVault(.init(serverOrigin: "https://synthetic.example", session: original, accessExpiresAt: .distantPast))
        let calls = expectation(description: "refresh then read"); calls.expectedFulfillmentCount = 2
        ProtocolStub.handler = { request in
            calls.fulfill()
            if request.url?.path == "/api/v1/sessions/refresh" { XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")); return .init(status: 200, data: refreshed) }
            XCTAssertEqual(request.url?.path, "/api/v1/conversations"); XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-new-access")
            return .init(status: 200, data: Data("{\"data\":[]}".utf8))
        }
        let client = try ApiClient(origin: "https://synthetic.example", vault: vault, transport: transport())
        let conversations = try await client.conversations(); XCTAssertTrue(conversations.isEmpty)
        await fulfillment(of: [calls], timeout: 2)
    }
    func testLogoutRejectsDelayedPreviousIdentitySignInResponse() async throws {
        let started = expectation(description: "old sign-in started"), data = try fixture(); let vault = MemoryVault()
        ProtocolStub.handler = { request in XCTAssertEqual(request.url?.path, "/api/v1/sessions"); started.fulfill(); return .init(status: 200, data: data, delay: 0.1) }
        let client = try ApiClient(origin: "https://synthetic.example", vault: vault, transport: transport())
        let old = Task { try await client.passwordSignIn(tenant: "synthetic", email: "member@example.test", password: "synthetic-only") }
        await fulfillment(of: [started], timeout: 2); _ = await client.logout()
        do { _ = try await old.value; XCTFail("A delayed former identity must not be installed") }
        catch NativeClientError.sessionChanged { } catch { XCTFail("Unexpected error: \(type(of: error))") }
        XCTAssertNil(try vault.load()); let session = await client.currentSession(); XCTAssertNil(session)
    }
    func testRejectedExpiredRefreshClearsAccessAndRefreshCredentials() async throws {
        let original = try Wire.decoder().decode(MemberSession.self, from: fixture())
        let vault = MemoryVault(.init(serverOrigin: "https://synthetic.example", session: original, accessExpiresAt: .distantPast))
        ProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/v1/sessions/refresh")
            return .init(status: 401, data: Data("{\"error\":{\"code\":\"invalid_refresh_token\"}}".utf8))
        }
        let client = try ApiClient(origin: "https://synthetic.example", vault: vault, transport: transport())
        do { _ = try await client.conversations(); XCTFail("An expired rejected refresh must not reach the authenticated read") }
        catch let error as NativeApiError { XCTAssertEqual(error.status, 401) }
        XCTAssertNil(try vault.load()); let current = await client.currentSession(); XCTAssertNil(current)
    }
    func testLogoutRejectsDelayedRefreshReplacement() async throws {
        let original = try Wire.decoder().decode(MemberSession.self, from: fixture()), rotated = try fixture(token: "synthetic-late-access")
        let vault = MemoryVault(.init(serverOrigin: "https://synthetic.example", session: original, accessExpiresAt: .distantPast))
        let started = expectation(description: "refresh started")
        ProtocolStub.handler = { request in
            if request.url?.path == "/api/v1/sessions/refresh" { started.fulfill(); return .init(status: 200, data: rotated, delay: 0.2) }
            XCTAssertEqual(request.url?.path, "/api/v1/sessions/current"); return .init(status: 204, data: Data())
        }
        let client = try ApiClient(origin: "https://synthetic.example", vault: vault, transport: transport())
        let old = Task { try await client.conversations() }
        await fulfillment(of: [started], timeout: 2); _ = await client.logout()
        do { _ = try await old.value; XCTFail("A delayed old refresh cannot restore credentials or complete its old read") } catch { }
        XCTAssertNil(try vault.load()); let current = await client.currentSession(); XCTAssertNil(current)
    }
    func testLogoutClearsAuthorityBeforeRemoteRevocationFinishes() async throws {
        let session = try Wire.decoder().decode(MemberSession.self, from: fixture())
        let vault = MemoryVault(.init(serverOrigin: "https://synthetic.example", session: session, accessExpiresAt: .distantFuture))
        let started = expectation(description: "revocation started")
        ProtocolStub.handler = { request in XCTAssertEqual(request.url?.path, "/api/v1/sessions/current"); XCTAssertEqual(request.httpMethod, "DELETE"); started.fulfill(); return .init(status: 204, data: Data(), delay: 0.1) }
        let client = try ApiClient(origin: "https://synthetic.example", vault: vault, transport: transport()); let logout = Task { await client.logout() }
        await fulfillment(of: [started], timeout: 2); XCTAssertNil(try vault.load()); let current = await client.currentSession(); XCTAssertNil(current)
        let revoked = await logout.value; XCTAssertTrue(revoked)
    }
    @MainActor func testNativeSocketUsesActualHeaderTransportWithoutCredentialInUrl() throws {
        let request = try PhoenixRealtime.handshakeRequest(origin: URL(string: "https://synthetic.example")!, ticket: SocketTicket(ticket: "synthetic-one-use-ticket", expiresIn: 30))
        XCTAssertEqual(request.url?.absoluteString, "wss://synthetic.example/socket/websocket?vsn=2.0.0")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-k-comms-socket-ticket"), "synthetic-one-use-ticket")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization")); XCTAssertFalse(request.url!.absoluteString.contains("synthetic-one-use-ticket"))
    }
    @MainActor func testNativeSocketRejectsExpiredAndHeaderInjectionTickets() {
        let origin = URL(string: "https://synthetic.example")!
        XCTAssertThrowsError(try PhoenixRealtime.handshakeRequest(origin: origin, ticket: SocketTicket(ticket: "synthetic-only", expiresIn: 0)))
        for value in ["synthetic\r\nother: value", "synthetic\rother", "synthetic\nother", "synthetic\tother", "synthetic\0other", "synthetic other", "syntheticé", ""] {
            XCTAssertThrowsError(try PhoenixRealtime.handshakeRequest(origin: origin, ticket: SocketTicket(ticket: value, expiresIn: 30)), value.debugDescription)
        }
    }
}
