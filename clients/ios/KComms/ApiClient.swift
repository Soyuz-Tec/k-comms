import Foundation

final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor ApiClient {
    nonisolated let origin: URL
    private let transport: URLSession
    private let vault: any CredentialVault
    private var session: MemberSession?
    private var accessExpiresAt: Date?
    private var generation: UInt64 = 0
    private var workspaceGeneration: UInt64 = 0
    private var refreshFlight: (stamp: IdentityStamp, token: String, task: Task<MemberSession, Error>)?
    private let maximumResponseBytes = 33_554_432

    init(origin: String, vault: any CredentialVault = KeychainCredentialVault(), transport: URLSession? = nil) throws {
        self.origin = try Self.validatedOrigin(origin)
        self.vault = vault
        if let saved = try vault.load(), saved.serverOrigin == self.origin.absoluteString { session = saved.session; accessExpiresAt = saved.accessExpiresAt }
        if let transport { self.transport = transport }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false
            configuration.urlCache = nil; configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 20
            self.transport = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
        }
    }
    nonisolated static func validatedOrigin(_ value: String) throws -> URL {
        guard let components = URLComponents(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil, components.query == nil,
              components.fragment == nil, components.path == "" || components.path == "/",
              components.port.map({ (1...65535).contains($0) }) ?? true else { throw NativeClientError.invalidOrigin }
        var canonical = components; canonical.path = ""; canonical.host = host.lowercased()
        guard let url = canonical.url else { throw NativeClientError.invalidOrigin }; return url
    }
    func currentSession() -> MemberSession? { session }
    func stamp() throws -> IdentityStamp {
        guard let session else { throw NativeApiError(status: 401, code: "sign_in_required") }
        return IdentityStamp(identity: session.identity, generation: generation)
    }
    func assertCurrent(_ expected: IdentityStamp) throws {
        guard let session, expected == IdentityStamp(identity: session.identity, generation: generation) else {
            throw NativeClientError.sessionChanged
        }
    }
    func passwordSignIn(tenant: String, email: String, password: String) async throws -> LoginResult {
        let expectedGeneration = generation
        let result: LoginResult = try await anonymous("/api/v1/sessions", body: [
            "tenant_slug": tenant, "email": email, "password": password,
            "device": ["name": "K-Comms iOS", "platform": "ios"]
        ])
        guard generation == expectedGeneration else { throw NativeClientError.sessionChanged }
        if case .session(let value) = result { try install(value) }
        if case .mfa(let challenge) = result {
            guard challenge.expiresIn > 0, !challenge.challengeToken.isEmpty,
                  challenge.challengeToken.utf8.count <= 8192 else { throw NativeClientError.invalidResponse }
        }
        return result
    }
    func completeMfa(challenge: String, code: String) async throws -> MemberSession {
        let expectedGeneration = generation
        let value: MemberSession = try await anonymous("/api/v1/auth/mfa", body: ["challenge_token": challenge, "code": code])
        guard generation == expectedGeneration else { throw NativeClientError.sessionChanged }
        try install(value); return value
    }
    private func install(_ value: MemberSession) throws {
        guard value.user.isNativeMember, value.tenant.status == "active",
              value.device.userId == value.user.id, value.user.tenantId == value.tenant.id,
              value.tokenType == "Bearer", !value.accessToken.isEmpty, !value.refreshToken.isEmpty,
              value.expiresIn > 0 else { throw NativeClientError.invalidResponse }
        let expires = Date().addingTimeInterval(TimeInterval(value.expiresIn))
        try vault.save(CredentialEnvelope(serverOrigin: origin.absoluteString, session: value, accessExpiresAt: expires)); accessExpiresAt = expires
        generation &+= 1; refreshFlight?.task.cancel(); refreshFlight = nil; session = value
    }
    /// Clear local authority before the best-effort remote revocation starts.
    func logout() async -> Bool {
        let old = session
        generation &+= 1; refreshFlight?.task.cancel(); refreshFlight = nil; session = nil; accessExpiresAt = nil
        var cleared = true
        do { try vault.clear() } catch { cleared = false }
        guard let old else { return cleared }
        do {
            let (_, response) = try await raw("/api/v1/sessions/current", method: "DELETE", token: old.accessToken)
            return cleared && response.statusCode == 204
        } catch { return false }
    }
    func me() async throws -> Me {
        let expected = try stamp()
        // A delayed older owner projection must not restore withdrawn access. Retry
        // once for a current projection without revoking a valid session lineage.
        for _ in 0..<2 {
            let value: Me = try await request("/api/v1/me")
            try assertCurrent(expected)
            guard value.tenant.id == expected.identity.tenant, value.user.id == expected.identity.user,
                  value.device.id == expected.identity.device, value.device.userId == value.user.id,
                  value.user.tenantId == value.tenant.id, value.user.isNativeMember, value.tenant.status == "active" else {
                try clearRejectedSession(expected); throw NativeApiError(status: 401, code: "identity_mismatch")
            }
            let current = session!
            guard (value.user.version ?? 0) >= (current.user.version ?? 0) else { continue }
            // Scope and role are owner metadata. Current capabilities/admission
            // decide each action; a legitimate role change preserves identity.
            let updated = MemberSession(accessToken: current.accessToken, refreshToken: current.refreshToken, tokenType: current.tokenType,
                                        expiresIn: current.expiresIn, tenant: value.tenant, user: value.user, device: value.device)
            try vault.save(CredentialEnvelope(serverOrigin: origin.absoluteString, session: updated, accessExpiresAt: accessExpiresAt))
            if current.user.accessScope != updated.user.accessScope { workspaceGeneration &+= 1 }; session = updated
            return value
        }
        throw NativeClientError.ownerProjectionSuperseded
    }
    func captureWorkspaceAuthority(_ expected: IdentityStamp) throws -> UInt64 {
        try assertCurrent(expected)
        guard session?.user.hasWorkspaceAccess == true else { throw NativeClientError.workspaceUnavailable }
        return workspaceGeneration
    }
    func assertWorkspaceAuthority(_ value: UInt64, stamp: IdentityStamp) throws {
        try assertCurrent(stamp)
        guard session?.user.hasWorkspaceAccess == true, workspaceGeneration == value else { throw NativeClientError.workspaceUnavailable }
    }
    private func workspaceRequest<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> T {
        guard try await me().user.hasWorkspaceAccess, session?.user.hasWorkspaceAccess == true else { throw NativeClientError.workspaceUnavailable }
        let expected = workspaceGeneration
        let value: T = try await request(path, method: method, body: body)
        guard expected == workspaceGeneration, session?.user.hasWorkspaceAccess == true else { throw NativeClientError.workspaceUnavailable }
        return value
    }
    func conversations() async throws -> [Conversation] { let value: Envelope<[Conversation]> = try await request("/api/v1/conversations"); return value.data }
    func directory(query: String, cursor: String? = nil) async throws -> DirectoryPage {
        var values = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "limit", value: "25")]
        if let cursor { values.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await workspaceRequest(path("/api/v1/directory/users", values))
    }
    func directConversation(person: String) async throws -> Conversation {
        let value: Envelope<Conversation> = try await workspaceRequest("/api/v1/direct-conversations", method: "POST", body: ["user_id": person]); return value.data
    }
    func createGroup(title: String, members: [String]) async throws -> Conversation {
        let value: Envelope<Conversation> = try await workspaceRequest("/api/v1/conversations", method: "POST", body: [
            "title": title, "kind": "group", "visibility": "private", "member_ids": members
        ]); return value.data
    }
    func messages(conversation: String, after: Int64 = 0, before: Int64? = nil) async throws -> MessagePage {
        var values = [URLQueryItem(name: "after_sequence", value: String(after)), URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "include", value: "sender_labels")]
        if let before { values.append(URLQueryItem(name: "before_sequence", value: String(before))) }
        return try await request(path("/api/v1/conversations/\(try id(conversation))/messages", values))
    }
    func senderLabels(conversation: String, messageIds: [String]) async throws -> [SenderLabel] {
        var labels: [String: SenderLabel] = [:]
        let unique = Array(Set(messageIds)).sorted()
        for offset in stride(from: 0, to: unique.count, by: 200) {
            let batch = Array(unique[offset..<min(offset + 200, unique.count)])
            let value: Envelope<[SenderLabel]> = try await request("/api/v1/conversations/\(try id(conversation))/message-sender-labels", method: "POST", body: ["message_ids": batch])
            for label in value.data { labels[label.id] = label }
        }
        return Array(labels.values)
    }
    func editMessage(_ message: Message, body: String) async throws -> Message {
        let value: Envelope<Message> = try await request("/api/v1/messages/\(try id(message.id))", method: "PATCH", body: ["body": body]); return value.data
    }
    func deleteMessage(_ message: Message) async throws {
        try await requestVoid("/api/v1/messages/\(try id(message.id))", method: "DELETE")
    }
    func send(_ pending: PendingMessage) async throws -> Message {
        try assertCurrent(pending.stamp)
        let value: Envelope<Message> = try await request("/api/v1/conversations/\(try id(pending.conversation))/messages", method: "POST",
                                                       body: ["body": pending.body, "attachment_ids": []], headers: ["Idempotency-Key": pending.id])
        return value.data
    }
    func read(conversation: String, sequence: Int64) async throws {
        try await requestVoid("/api/v1/conversations/\(try id(conversation))/read-cursor", method: "PUT", body: ["sequence": sequence])
    }
    func socketTicket() async throws -> SocketTicket { let value: Envelope<SocketTicket> = try await request("/api/v1/socket-tickets", method: "POST"); return value.data }
    func activeCall(conversation: String) async throws -> Call? { let value: Envelope<Call?> = try await request("/api/v1/conversations/\(try id(conversation))/call"); return value.data }
    func startCall(conversation: String, video: Bool) async throws -> CallAdmission {
        try await request("/api/v1/conversations/\(try id(conversation))/calls", method: "POST", body: ["media_kind": video ? "video" : "audio"])
    }
    func joinCall(_ call: Call) async throws -> CallAdmission {
        try await request("/api/v1/conversations/\(try id(call.conversationId))/calls/\(try id(call.id))/join", method: "POST")
    }
    func participants(_ call: Call) async throws -> [CallParticipant] {
        let value: Envelope<[CallParticipant]> = try await request("/api/v1/conversations/\(try id(call.conversationId))/calls/\(try id(call.id))/participants?current_admission=true"); return value.data
    }
    func endCall(_ call: Call) async throws {
        try await requestVoid("/api/v1/conversations/\(try id(call.conversationId))/calls/\(try id(call.id))/end", method: "POST")
    }
    func meetings(from: Date, through: Date) async throws -> [Meeting] {
        let formatter = ISO8601DateFormatter()
        let value: Envelope<[Meeting]> = try await workspaceRequest(path("/api/v1/meetings", [
            URLQueryItem(name: "from", value: formatter.string(from: from)), URLQueryItem(name: "to", value: formatter.string(from: through))
        ])); return value.data
    }
    func startMeeting(_ meeting: Meeting, occurrence: Meeting.Occurrence, video: Bool) async throws -> CallAdmission {
        return try await workspaceRequest("/api/v1/meetings/\(try id(meeting.id))/occurrences/\(try id(occurrence.id))/start", method: "POST", body: ["media_kind": video ? "video" : "audio"])
    }
    func createMeeting(conversation: String, title: String, start: Date, duration: Int) async throws -> Meeting {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .current; formatter.dateFormat = "yyyy-MM-dd'T'HH:mm"
        let value: Envelope<Meeting> = try await workspaceRequest("/api/v1/conversations/\(try id(conversation))/meetings", method: "POST", body: [
            "title": title, "timezone": TimeZone.current.identifier, "local_start": formatter.string(from: start), "duration_minutes": duration,
            "recurrence": ["frequency": "none", "interval": 1, "count": 1], "reminder_minutes": 5,
            "host_policy": ["allow_guests": false, "join_before_host": false]
        ]); return value.data
    }
    func cancelMeeting(_ meeting: Meeting) async throws -> Meeting {
        let value: Envelope<Meeting> = try await workspaceRequest("/api/v1/meetings/\(try id(meeting.id))/cancel", method: "POST", body: ["expected_version": meeting.version]); return value.data
    }
    func phoneConfiguration() async throws -> PhoneConfiguration { let value: Envelope<PhoneConfiguration> = try await workspaceRequest("/api/v1/telephony/config"); return value.data }
    func phoneCapabilities() async throws -> [String: PhoneCapability] { let value: Envelope<[String: PhoneCapability]> = try await workspaceRequest("/api/v1/telephony/capabilities"); return value.data }
    func phoneCalls(cursor: String? = nil) async throws -> PhoneCallsPage {
        var query = [URLQueryItem(name: "limit", value: "30")]; if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await workspaceRequest(path("/api/v1/telephony/calls", query))
    }
    func phoneCall(_ call: String) async throws -> PhoneCall { let value: Envelope<PhoneCall> = try await workspaceRequest("/api/v1/telephony/calls/\(try id(call))"); return value.data }
    func dialPhone(destination: String, key: String) async throws -> PhoneAdmission {
        return try await workspaceRequest("/api/v1/telephony/calls", method: "POST", body: ["destination": destination, "idempotency_key": key])
    }
    func answerPhone(_ call: String) async throws -> PhoneAdmission { try await workspaceRequest("/api/v1/telephony/calls/\(try id(call))/answer", method: "POST") }
    func joinPhone(_ call: String) async throws -> PhoneAdmission { try await workspaceRequest("/api/v1/telephony/calls/\(try id(call))/join", method: "POST") }
    func endPhone(_ call: String) async throws -> PhoneCall { let value: Envelope<PhoneCall> = try await workspaceRequest("/api/v1/telephony/calls/\(try id(call))/end", method: "POST"); return value.data }
    func rejectPhone(_ call: String) async throws -> PhoneCall { let value: Envelope<PhoneCall> = try await workspaceRequest("/api/v1/telephony/calls/\(try id(call))/reject", method: "POST"); return value.data }
    func phoneControls(_ call: String) async throws -> [PhoneControlReceipt] {
        let value: Envelope<[PhoneControlReceipt]> = try await workspaceRequest("/api/v1/telephony/calls/\(try id(call))/controls"); return value.data
    }
    func requestTone(_ call: String, digit: String, key: String) async throws -> PhoneControlReceipt {
        let value: Envelope<PhoneControlReceipt> = try await workspaceRequest("/api/v1/telephony/calls/\(try id(call))/controls", method: "POST", body: ["action": "dtmf", "digit": digit, "idempotency_key": key]); return value.data
    }
    func completeTone(_ call: String, command: String, status: String) async throws -> PhoneControlReceipt {
        let value: Envelope<PhoneControlReceipt> = try await workspaceRequest("/api/v1/telephony/calls/\(try id(call))/controls/\(try id(command))/complete", method: "POST", body: ["status": status]); return value.data
    }
    func reconcileTone(_ call: String, command: String) async throws -> PhoneControlReceipt {
        let value: Envelope<PhoneControlReceipt> = try await workspaceRequest("/api/v1/telephony/calls/\(try id(call))/controls/\(try id(command))/reconcile", method: "POST"); return value.data
    }
    func nativePushConfiguration() async throws -> NativePushConfiguration {
        let value: Envelope<NativePushConfiguration> = try await request("/api/v1/me/native-push/config"); return value.data
    }
    func nativePushRegistrations() async throws -> [NativePushRegistration] {
        let value: Envelope<[NativePushRegistration]> = try await request("/api/v1/me/native-push/registration"); return value.data
    }
    func registerNativePush(channel: String, application: String, environment: String, token: String,
                            installation: String, version: Int) async throws -> NativePushRegistrationResult {
        let value: NativePushRegistrationResult = try await request("/api/v1/me/native-push/registration", method: "PUT", body: [
            "platform": "ios", "channel": channel, "application_id": application, "environment": environment,
            "token": token, "installation_id": installation, "expected_version": version
        ]); return value
    }
    func revokeNativePush(channel: String, version: Int) async throws {
        try await requestVoid("/api/v1/me/native-push/registration", method: "DELETE", body: ["channel": channel, "expected_version": version])
    }
    func admitNativeWake(_ wake: String) async throws -> NativeWakeAdmission {
        let expected = try stamp()
        if (accessExpiresAt ?? .distantPast) <= Date().addingTimeInterval(10) { try await refresh(expected) }
        try assertCurrent(expected)
        return try await request("/api/v1/native-call-wakes/\(try id(wake))/admit", method: "POST", retry: false)
    }
    private func id(_ value: String) throws -> String {
        guard UUID(uuidString: value) != nil else { throw NativeClientError.invalidResponse }; return value
    }
    private func path(_ path: String, _ values: [URLQueryItem]) -> String {
        var components = URLComponents(); components.path = path; components.queryItems = values; return components.string!
    }
    private func request<T: Decodable>(_ path: String, method: String = "GET", body: [String: Any]? = nil,
                                       headers: [String: String] = [:], retry: Bool = true) async throws -> T {
        let bytes = try await authenticated(path, method: method, body: body, headers: headers, retry: retry)
        return try Wire.decoder().decode(T.self, from: bytes)
    }
    private func requestVoid(_ path: String, method: String, body: [String: Any]? = nil) async throws {
        _ = try await authenticated(path, method: method, body: body, headers: [:], retry: true)
    }
    private func authenticated(_ path: String, method: String, body: [String: Any]?, headers: [String: String], retry: Bool) async throws -> Data {
        let expected = try stamp()
        if retry && (accessExpiresAt ?? .distantPast) <= Date() { try await refresh(expected); try assertCurrent(expected) }
        let token = session!.accessToken
        let (data, response) = try await raw(path, method: method, body: body, token: token, headers: headers)
        try assertCurrent(expected)
        if response.statusCode == 401 && retry {
            if session?.accessToken != token {
                return try await authenticated(path, method: method, body: body, headers: headers, retry: false)
            }
            try await refresh(expected)
            try assertCurrent(expected)
            return try await authenticated(path, method: method, body: body, headers: headers, retry: false)
        }
        if response.statusCode == 401 { try clearRejectedSession(expected) }
        try check(response, data); return data
    }
    private func refresh(_ expected: IdentityStamp) async throws {
        try assertCurrent(expected)
        let oldToken = session!.refreshToken
        let flight: Task<MemberSession, Error>
        if let existing = refreshFlight, existing.stamp == expected, existing.token == oldToken { flight = existing.task }
        else {
            let created = Task { () throws -> MemberSession in
                let value: MemberSession = try await self.anonymous("/api/v1/sessions/refresh", body: ["refresh_token": oldToken])
                return value
            }
            refreshFlight = (expected, oldToken, created); flight = created
        }
        do {
            let value = try await flight.value
            try assertCurrent(expected)
            guard value.identity == expected.identity, value.user.isNativeMember, value.tenant.status == "active", value.device.userId == value.user.id, value.user.tenantId == value.tenant.id, value.tokenType == "Bearer", value.expiresIn > 0, !value.accessToken.isEmpty, !value.refreshToken.isEmpty else { try clearRejectedSession(expected); throw NativeApiError(status: 401, code: "identity_mismatch") }
            if session!.refreshToken == oldToken {
                let current = session!
                // Token rotation can finish after a newer /me projection. Install
                // the new credentials while retaining the newer owner metadata.
                let rotated = (value.user.version ?? 0) < (current.user.version ?? 0)
                    ? MemberSession(accessToken: value.accessToken, refreshToken: value.refreshToken, tokenType: value.tokenType,
                                    expiresIn: value.expiresIn, tenant: current.tenant, user: current.user, device: current.device)
                    : value
                let expires = Date().addingTimeInterval(TimeInterval(value.expiresIn))
                try vault.save(CredentialEnvelope(serverOrigin: origin.absoluteString, session: rotated, accessExpiresAt: expires))
                if current.user.accessScope != rotated.user.accessScope { workspaceGeneration &+= 1 }; session = rotated; accessExpiresAt = expires
            }
            if refreshFlight?.token == oldToken { refreshFlight = nil }
        } catch {
            if let error = error as? NativeApiError, [400, 401, 403].contains(error.status), generation == expected.generation, session?.identity == expected.identity { try clearRejectedSession(expected) }
            if refreshFlight?.token == oldToken { refreshFlight = nil }
            throw error
        }
    }
    private func clearRejectedSession(_ expected: IdentityStamp) throws {
        try assertCurrent(expected); generation &+= 1; session = nil; accessExpiresAt = nil; refreshFlight?.task.cancel(); refreshFlight = nil; try vault.clear()
    }
    private func anonymous<T: Decodable>(_ path: String, body: [String: Any]) async throws -> T {
        let (data, response) = try await raw(path, method: "POST", body: body); try check(response, data)
        return try Wire.decoder().decode(T.self, from: data)
    }
    private func raw(_ path: String, method: String, body: [String: Any]? = nil,
                     token: String? = nil, headers: [String: String] = [:]) async throws -> (Data, HTTPURLResponse) {
        guard path.hasPrefix("/api/v1/"), !path.hasPrefix("//"), let url = URL(string: origin.absoluteString + path),
              url.host == origin.host, url.scheme == origin.scheme, url.port == origin.port else { throw NativeClientError.invalidOrigin }
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let (data, response) = try await transport.data(for: request)
        guard data.count <= maximumResponseBytes, let response = response as? HTTPURLResponse else { throw NativeClientError.invalidResponse }
        return (data, response)
    }
    private func check(_ response: HTTPURLResponse, _ data: Data) throws {
        guard (200..<300).contains(response.statusCode) else {
            struct ErrorEnvelope: Decodable { let error: Details?; struct Details: Decodable { let code: String? } }
            let code = (try? Wire.decoder().decode(ErrorEnvelope.self, from: data))?.error?.code ?? "request_failed"
            throw NativeApiError(status: response.statusCode, code: code)
        }
    }
}
