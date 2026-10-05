import Foundation

struct PhoenixFrame {
    let joinRef: String?
    let ref: String?
    let topic: String
    let event: String
    let payload: [String: Any]
    func encoded() throws -> String {
        let values: [Any] = [joinRef as Any? ?? NSNull(), ref as Any? ?? NSNull(), topic, event, payload]
        let data = try JSONSerialization.data(withJSONObject: values)
        guard let string = String(data: data, encoding: .utf8) else { throw NativeClientError.invalidResponse }; return string
    }
    static func decode(_ data: Data) -> PhoenixFrame? {
        guard data.count <= 1_048_576, let values = try? JSONSerialization.jsonObject(with: data) as? [Any],
              values.count == 5, let topic = values[2] as? String, let event = values[3] as? String,
              let payload = values[4] as? [String: Any] else { return nil }
        return PhoenixFrame(joinRef: values[0] as? String, ref: values[1] as? String, topic: topic, event: event, payload: payload)
    }
}
enum RealtimeSignal { case connected, contentChanged, authorityChanged, callChanged, phoneChanged, disconnected }

@MainActor final class PhoenixRealtime {
    private var socket: URLSessionWebSocketTask?
    private var reader: Task<Void, Never>?
    private var heartbeat: Task<Void, Never>?
    private var joinDeadline: Task<Void, Never>?
    private var acknowledged: Set<String> = []
    private var connectionGeneration: UInt64 = 0
    private let transport: URLSession
    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false; configuration.urlCache = nil
        transport = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }
    static func handshakeRequest(origin: URL, ticket: SocketTicket) throws -> URLRequest {
        let canonical = try ApiClient.validatedOrigin(origin.absoluteString)
        guard ticket.expiresIn > 0, !ticket.ticket.isEmpty, ticket.ticket.utf8.count <= 8192,
              !ticket.ticket.contains("\r"), !ticket.ticket.contains("\n") else { throw NativeClientError.invalidResponse }
        var components = URLComponents(url: canonical, resolvingAgainstBaseURL: false)!
        components.scheme = "wss"; components.path = "/socket/websocket"
        components.queryItems = [URLQueryItem(name: "vsn", value: "2.0.0")]
        guard let url = components.url else { throw NativeClientError.invalidOrigin }
        var request = URLRequest(url: url); request.setValue(ticket.ticket, forHTTPHeaderField: "x-k-comms-socket-ticket")
        return request
    }
    func connect(api: ApiClient, stamp: IdentityStamp, conversation: String?, cursor: Int64, call: Call?,
                 onSignal: @escaping @MainActor (RealtimeSignal) -> Void) async throws {
        close(); let expected = connectionGeneration
        let ticket = try await api.socketTicket(); try await api.assertCurrent(stamp)
        guard expected == connectionGeneration, !ticket.ticket.isEmpty, ticket.expiresIn > 0 else { throw NativeClientError.sessionChanged }
        let handshake = try Self.handshakeRequest(origin: api.origin, ticket: ticket)
        let opened = transport.webSocketTask(with: handshake); opened.maximumMessageSize = 1_048_576; socket = opened; opened.resume()
        var topics: [(String, [String: Any])] = [("user:\(stamp.identity.user)", ["protocol_version": 1])]
        if let conversation {
            topics.append(("conversation:\(conversation)", ["protocol_version": 1, "after_sequence": cursor,
                                                         "client_capabilities": ["message_revisions", "attachment_v2"]]))
        }
        if let call { topics.append(("call:\(call.id)", ["protocol_version": 1, "conversation_id": call.conversationId])) }
        for (index, entry) in topics.enumerated() {
            try await api.assertCurrent(stamp)
            guard expected == connectionGeneration else { throw NativeClientError.sessionChanged }
            let ref = String(index + 1)
            try await opened.send(.string(try PhoenixFrame(joinRef: ref, ref: ref, topic: entry.0, event: "phx_join", payload: entry.1).encoded()))
        }
        let joins = Dictionary(uniqueKeysWithValues: topics.enumerated().map { (String($0.offset + 1), $0.element.0) })
        joinDeadline = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) } catch { return }
            guard let self, expected == self.connectionGeneration, self.acknowledged.count < joins.count else { return }
            self.close(); onSignal(.disconnected)
        }
        reader = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let incoming = try await opened.receive()
                    try await api.assertCurrent(stamp)
                    guard let self, expected == self.connectionGeneration else { return }
                    let data: Data
                    switch incoming { case .data(let bytes): data = bytes; case .string(let value): data = Data(value.utf8); @unknown default: continue }
                    guard let frame = PhoenixFrame.decode(data) else { continue }
                    guard topics.contains(where: { $0.0 == frame.topic }) || frame.topic == "phoenix" else { continue }
                    if frame.event == "disconnect" || frame.event == "phx_close" || frame.event == "phx_error" {
                        onSignal(.authorityChanged); self.close(); return
                    }
                    if frame.event == "phx_reply" && frame.payload["status"] as? String == "error" {
                        onSignal(.authorityChanged); self.close(); return
                    }
                    if frame.event == "phx_reply" {
                        if let ref = frame.ref, joins[ref] == frame.topic, frame.payload["status"] as? String == "ok" {
                            self.acknowledged.insert(ref)
                            if self.acknowledged.count == joins.count { self.joinDeadline?.cancel(); self.joinDeadline = nil; onSignal(.connected) }
                            onSignal(.contentChanged)
                        }
                        continue
                    }
                    if frame.event.hasPrefix("telephony.") {
                        onSignal(.phoneChanged)
                    } else if ["call.started.v1", "call.ended.v1", "call.participant_removed.v1", "call.participant_muted.v1"].contains(frame.event) {
                        onSignal(.callChanged)
                    } else if frame.event == "membership.changed.v1" || frame.event == "conversation.membership.v1" {
                        onSignal(.authorityChanged)
                    } else if frame.event.hasPrefix("message.") || frame.event == "conversation.activity.v1" ||
                                frame.event == "conversation.archived.v1" || frame.event == "conversation.updated.v1" {
                        onSignal(.contentChanged)
                    }
                }
            } catch {
                guard let self, expected == self.connectionGeneration else { return }
                self.close(); onSignal(.disconnected)
            }
        }
        heartbeat = Task { [weak self] in
            do {
                var ref = 100
                while !Task.isCancelled {
                    try await Task.sleep(nanoseconds: 25_000_000_000)
                    try await api.assertCurrent(stamp)
                    guard let self, expected == self.connectionGeneration else { return }
                    ref += 1
                    try await opened.send(.string(try PhoenixFrame(joinRef: nil, ref: String(ref), topic: "phoenix", event: "heartbeat", payload: [:]).encoded()))
                }
            } catch {
                guard let self, expected == self.connectionGeneration else { return }
                self.close(); onSignal(.disconnected)
            }
        }
    }
    func close() {
        connectionGeneration &+= 1; reader?.cancel(); heartbeat?.cancel(); joinDeadline?.cancel(); reader = nil; heartbeat = nil; joinDeadline = nil; acknowledged = []
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
    }
}
