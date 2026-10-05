import Foundation

struct Envelope<T: Decodable>: Decodable { let data: T }
struct Tenant: Codable, Equatable, Sendable { let id: String; let name: String; let slug: String; let status: String }
struct Person: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let displayName: String
    let tenantId: String?
    let accountType: String?
    let accessScope: String?
    let role: String?
    let status: String?
    let version: Int?
    var isNativeMember: Bool { accountType == "human" && status == "active" && (version ?? 0) > 0 && ["workspace", "conversation_only"].contains(accessScope ?? "") }
    var hasWorkspaceAccess: Bool { isNativeMember && accessScope == "workspace" }
}
struct Device: Codable, Equatable, Sendable { let id: String; let userId: String; let name: String; let platform: String }
struct MemberSession: Codable, Equatable, Sendable {
    let accessToken: String
    let refreshToken: String
    let tokenType: String
    let expiresIn: Int
    let tenant: Tenant
    let user: Person
    let device: Device
    var identity: SessionIdentity { SessionIdentity(tenant: tenant.id, user: user.id, device: device.id) }
}
/// Observable UI receives account identity only; the API actor and vault own tokens.
struct SignedInMember: Equatable, Sendable {
    let tenant: Tenant; let user: Person; let device: Device
    init(_ session: MemberSession) { tenant = session.tenant; user = session.user; device = session.device }
    var identity: SessionIdentity { SessionIdentity(tenant: tenant.id, user: user.id, device: device.id) }
}
struct SessionIdentity: Codable, Equatable, Sendable { let tenant: String; let user: String; let device: String }
struct IdentityStamp: Equatable, Sendable { let identity: SessionIdentity; let generation: UInt64 }
struct CredentialEnvelope: Codable {
    let serverOrigin: String; let session: MemberSession; let accessExpiresAt: Date?
    init(serverOrigin: String, session: MemberSession, accessExpiresAt: Date? = nil) {
        self.serverOrigin = serverOrigin; self.session = session; self.accessExpiresAt = accessExpiresAt
    }
}
struct MfaChallenge: Decodable, Sendable { let mfaRequired: Bool; let challengeToken: String; let expiresIn: Int }
enum LoginResult: Decodable {
    case session(MemberSession)
    case mfa(MfaChallenge)
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if try container.decodeIfPresent(Bool.self, forKey: .mfaRequired) == true {
            self = .mfa(try MfaChallenge(from: decoder))
        } else { self = .session(try MemberSession(from: decoder)) }
    }
    private enum CodingKeys: String, CodingKey { case mfaRequired }
}
struct Capabilities: Decodable {
    let allowAudioCalls: Bool
    let allowVideoCalls: Bool
    let allowPublicChannels: Bool
}
struct Me: Decodable { let tenant: Tenant; let user: Person; let device: Device; let capabilities: Capabilities }
struct Conversation: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let tenantId: String
    let kind: String
    let title: String?
    let counterpartDisplayName: String?
    let latestSequence: Int64
    let unreadCount: Int?
    var label: String { title ?? counterpartDisplayName ?? (kind == "direct" ? "Direct conversation" : "Conversation") }
}
struct DirectoryPage: Decodable {
    let data: [Person]
    let page: CursorPage
    struct CursorPage: Decodable { let nextCursor: String? }
}
struct NativeAttachment: Decodable, Identifiable, Equatable, Sendable {
    let id: String; let fileName: String; let status: String
}
struct Message: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let tenantId: String
    let conversationId: String
    let senderUserId: String
    let clientMessageId: String
    let conversationSequence: Int64
    let body: String?
    let status: String
    let editedAt: String?
    let deletedAt: String?
    let insertedAt: String
    let attachments: [NativeAttachment]
    var visibleBody: String { status == "active" ? (body ?? "") : "Message removed" }
}
struct SenderLabel: Decodable, Identifiable, Equatable { let id: String; let displayName: String; let redacted: Bool }
struct MessagePage: Decodable {
    let data: [Message]
    let page: Paging
    let included: Included?
    struct Paging: Decodable { let hasMore: Bool; let nextAfterSequence: Int64?; let resetRequired: Bool }
    struct Included: Decodable { let senderLabels: [SenderLabel] }
}
struct SocketTicket: Decodable { let ticket: String; let expiresIn: Int }
struct Call: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let conversationId: String
    let mediaKind: String?
    let status: String
    let expiresAt: String
    let canEnd: Bool
    var isVideo: Bool { mediaKind == "video" }
}
struct CallCredential: Decodable, Sendable {
    let serverUrl: String
    let participantToken: String
    let expiresIn: Int
    let iceServers: [NativeIceServer]?
}
struct NativeIceServer: Decodable, Sendable { let urls: [String]; let username: String?; let credential: String? }
struct CallAdmission: Decodable, Sendable { let data: Call; let credential: CallCredential }
struct CallParticipant: Decodable { let id: String; let userId: String; let status: String }
struct Meeting: Decodable, Identifiable {
    let id: String
    let conversationId: String
    let title: String
    let timezone: String
    let status: String
    let canManage: Bool
    let version: Int
    let occurrences: [Occurrence]
    struct Occurrence: Decodable, Identifiable {
        let id: String; let startsAt: String; let endsAt: String; let status: String; let callId: String?
    }
}
struct NativeApiError: Error, LocalizedError {
    let status: Int
    let code: String
    var errorDescription: String? {
        switch status {
        case 401: return "Your session has ended. Sign in again."
        case 403: return "You no longer have access to this action."
        case 404: return "This item is no longer available."
        case 409: return "This item changed. Refresh and try again."
        case 429: return "Please wait before trying again."
        case 503: return "This service is unavailable."
        default: return "The request could not be completed (\(code))."
        }
    }
    var removesCachedContent: Bool { [401, 403, 404].contains(status) }
}
enum NativeClientError: Error, LocalizedError {
    case invalidOrigin, sessionChanged, invalidResponse, ownerProjectionSuperseded, workspaceUnavailable, replayDidNotAdvance, replayPrivacyBudgetExceeded, microphoneDenied, cameraDenied, featureUnavailable
    var errorDescription: String? {
        switch self {
        case .invalidOrigin: return "Enter an HTTPS server address without a path, credentials, query, or fragment."
        case .sessionChanged: return "Your account changed. Try again."
        case .invalidResponse: return "The server returned an unsupported response."
        case .ownerProjectionSuperseded: return "Current account access could not be confirmed. Refresh before continuing."
        case .workspaceUnavailable: return "Your account can communicate in its available conversations. Workspace directory, meetings and phone require workspace access."
        case .replayDidNotAdvance: return "Message history could not advance. Refresh the conversation."
        case .replayPrivacyBudgetExceeded: return "Message revision history reached its safe limit. Content was cleared; reopen the conversation to capture current history."
        case .microphoneDenied: return "Microphone access is required. Change it in iOS Settings."
        case .cameraDenied: return "Camera access was denied. Join with audio or change it in iOS Settings."
        case .featureUnavailable: return "Background call notifications are not configured on this deployment."
        }
    }
}
enum Wire {
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase; return decoder
    }
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder(); encoder.keyEncodingStrategy = .convertToSnakeCase; return encoder
    }
    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]; return formatter.date(from: value)
    }
}
enum NativeIdentityAvailability {
    static let corporateSignIn = "Corporate browser sign-in is not available in this native app. Use the web client if your workspace requires corporate sign-in."
    static let administrativeProof = "Administrative and privileged verification actions are available in the web client."
}
