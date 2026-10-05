import Foundation

struct PhoneNumberAssignment: Decodable { let id: String; let phoneNumber: String; let `extension`: String; let userId: String }
struct PhoneConfiguration: Decodable {
    let enabled: Bool; let configured: Bool; let providerReady: Bool?; let lineAssigned: Bool?
    let provider: String; let number: PhoneNumberAssignment?; let canManage: Bool
    var canCall: Bool { enabled && configured && (providerReady ?? configured) && (lineAssigned ?? (number != nil)) && number != nil }
    var advice: String {
        if !enabled { return "Phone service is off. Your administrator can coordinate provider setup." }
        if !(providerReady ?? configured) { return "The phone provider needs setup. Ask your administrator." }
        if !(lineAssigned ?? (number != nil)) || number == nil { return "No phone line is assigned to your account." }
        return canCall ? "Phone service is ready." : "Phone availability could not be confirmed."
    }
}
struct PhoneCall: Decodable, Identifiable, Equatable, Sendable {
    let id: String; let direction: String; let status: String; let fromNumber: String; let toNumber: String
    let `extension`: String; let startedAt: String; let answeredAt: String?; let endedAt: String?
    let connectedSeconds: Int; let canAnswer: Bool; let canJoin: Bool; let canEnd: Bool
    let activeOnThisDevice: Bool; let endReason: String?; let controlState: String?
    var isActive: Bool { status == "ringing" || status == "answered" }
    var otherNumber: String { direction == "inbound" ? fromNumber : toNumber }
    var statusLabel: String { endReason == "answer_unconfirmed" ? "Answer unconfirmed" : status.replacingOccurrences(of: "_", with: " ").capitalized }
}
struct PhoneAdmission: Decodable { let data: PhoneCall; let credential: CallCredential }
struct PhoneCallsPage: Decodable {
    let data: [PhoneCall]; let page: Paging
    struct Paging: Decodable { let hasMore: Bool; let nextCursor: String? }
}
struct PhoneCapability: Decodable { let supported: Bool; let configured: Bool?; let qualified: Bool?; let reason: String?; let transport: String?; let assurance: String? }
struct PhoneControlReceipt: Decodable, Identifiable, Equatable {
    let id: String; let callId: String; let action: String; let status: String; let dispatch: Bool
    let createdAt: String; let expiresAt: String; let completedAt: String?; let failureReason: String?
    func authorizesTone(call: String, now: Date = Date()) -> Bool {
        callId == call && action == "dtmf" && dispatch && status == "dispatching" && (Wire.date(expiresAt) ?? .distantPast) > now
    }
}
/// Reservations precede permission dialogs/network awaits, so concurrent tabs cannot open two media rooms.
@MainActor final class NativeCallSlot {
    private var owner: UUID?
    func acquire(_ candidate: UUID) -> Bool { if owner == nil { owner = candidate; return true }; return false }
    func release(_ candidate: UUID) { if owner == candidate { owner = nil } }
}
struct AuthorityLease {
    let stamp: IdentityStamp; let credentialExpires: Date
    private(set) var lastObserved: Date
    private let credentialDeadline: TimeInterval
    private var observedUptime: TimeInterval
    init(stamp: IdentityStamp, credentialExpires: Date, lastObserved: Date, uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        self.stamp = stamp; self.credentialExpires = credentialExpires; self.lastObserved = lastObserved
        credentialDeadline = uptime + max(0, credentialExpires.timeIntervalSince(lastObserved)); observedUptime = uptime
    }
    func credentialIsCurrent(now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        now < credentialExpires && uptime >= observedUptime && uptime < credentialDeadline
    }
    func valid(stamp current: IdentityStamp, now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        stamp == current && credentialIsCurrent(now: now, uptime: uptime) && uptime - observedUptime <= 10
    }
    func needsRevalidation(uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool { uptime - observedUptime >= 5 }
    mutating func observe(now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lastObserved = now; observedUptime = uptime
    }
}
