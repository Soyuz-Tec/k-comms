import Foundation

struct NativePushConfiguration: Decodable {
    let protocolVersion: Int; let enabled: Bool; let platformConfigs: [Platform]
    let registrationTtlSeconds: Int; let wakeTtlSeconds: Int; let backgroundDeviceQualificationRequired: Bool
    struct Platform: Decodable {
        let platform: String; let channel: String; let applicationId: String; let environment: String; let enabled: Bool
    }
    func approves(channel: String, application: String, environment: String, qualified: Bool) -> Bool {
        qualified && enabled && protocolVersion == 1 && wakeTtlSeconds == 30 && backgroundDeviceQualificationRequired &&
        platformConfigs.contains { $0.enabled && $0.platform == "ios" && $0.channel == channel &&
            $0.applicationId == application && $0.environment == environment }
    }
}
struct NativePushRegistration: Decodable {
    let id: String; let deviceId: String; let version: Int; let platform: String; let channel: String
    let applicationId: String; let environment: String; let status: String; let expiresAt: String
}
struct NativePushRegistrationResult: Decodable { let data: NativePushRegistration; let replayed: Bool; var registration: NativePushRegistration { data } }
/// Push contains an opaque hint only. Its ID is never call authority or a media credential.
struct NativeWakeHint: Equatable {
    let id: String; let expiresAt: Date; let monotonicDeadline: TimeInterval; let receivedUptime: TimeInterval
    init(payload: [AnyHashable: Any], now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) throws {
        let protocolKeys: Set<String> = ["protocol_version", "wake_id", "expires_at", "kind"]
        let keys = Set(payload.keys.compactMap { $0 as? String })
        guard keys.subtracting(["aps"]) == protocolKeys, keys.count == payload.count,
              payload["protocol_version"] as? String == "1", payload["kind"] as? String == "call",
              let id = payload["wake_id"] as? String, UUID(uuidString: id) != nil,
              let text = payload["expires_at"] as? String, let expiry = Wire.date(text),
              expiry > now, expiry.timeIntervalSince(now) <= 30 else { throw NativeClientError.invalidResponse }
        self.id = id; expiresAt = expiry; monotonicDeadline = uptime + expiry.timeIntervalSince(now); receivedUptime = uptime
    }
    func current(now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        expiresAt > now && uptime >= receivedUptime && uptime < monotonicDeadline
    }
}
enum NativeWakeAdmission: Decodable {
    case conversation(CallAdmission), phone(PhoneAdmission)
    private enum Keys: String, CodingKey { case owner, data, credential }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        let owner = try container.decode(String.self, forKey: .owner)
        switch owner {
        case "conversation": self = .conversation(try CallAdmission(from: decoder))
        case "telephony": self = .phone(try PhoneAdmission(from: decoder))
        default: throw NativeClientError.invalidResponse
        }
    }
    var credential: CallCredential { switch self { case .conversation(let value): return value.credential; case .phone(let value): return value.credential } }
}
