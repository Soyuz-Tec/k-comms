import Foundation
import XCTest
@testable import KComms

final class NativeWakeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_791_158_400)
    private let id = "00000000-0000-4000-8000-000000000101"
    private func payload(seconds: TimeInterval = 25) -> [AnyHashable: Any] {
        ["protocol_version": "1", "wake_id": id, "expires_at": ISO8601DateFormatter().string(from: now.addingTimeInterval(seconds)), "kind": "call"]
    }
    func testOpaqueWakeIsBoundedByWallAndMonotonicDeadlines() throws {
        let hint = try NativeWakeHint(payload: payload(), now: now, uptime: 100)
        XCTAssertEqual(hint.id, id); XCTAssertTrue(hint.current(now: now.addingTimeInterval(2), uptime: 102))
        XCTAssertFalse(hint.current(now: now.addingTimeInterval(-100), uptime: 126))
        XCTAssertFalse(hint.current(now: now.addingTimeInterval(26), uptime: 102))
        XCTAssertFalse(hint.current(now: now, uptime: 99))
    }
    func testExpiredFutureHorizonAndMalformedIDsAreRejected() {
        for seconds in [-1.0, 0.0, 31.0] { XCTAssertThrowsError(try NativeWakeHint(payload: payload(seconds: seconds), now: now, uptime: 100)) }
        var invalid = payload(); invalid["wake_id"] = "not-an-intent"; XCTAssertThrowsError(try NativeWakeHint(payload: invalid, now: now))
    }
    func testPayloadCannotCarryCallerCallOrCredentialContents() {
        for key in ["caller", "call_id", "conversation_id", "participant_token", "session_token", "body"] {
            var invalid = payload(); invalid[key] = "private value"
            XCTAssertThrowsError(try NativeWakeHint(payload: invalid, now: now))
        }
    }
    func testAPNsAPSMetadataDoesNotBecomeAuthority() throws {
        var value = payload(); value["aps"] = [String: String]()
        XCTAssertEqual(try NativeWakeHint(payload: value, now: now).id, id)
        value["protocol_version"] = 1; XCTAssertThrowsError(try NativeWakeHint(payload: value, now: now))
    }
    func testApprovedBackendConfigurationCannotOverrideUnsignedQualification() throws {
        let data = Data("{\"protocol_version\":1,\"enabled\":true,\"wake_ttl_seconds\":30,\"registration_ttl_seconds\":86400,\"background_device_qualification_required\":true,\"platform_configs\":[{\"platform\":\"ios\",\"channel\":\"apns_voip\",\"application_id\":\"com.synthetic.native\",\"environment\":\"sandbox\",\"enabled\":true}]}".utf8)
        let config = try Wire.decoder().decode(NativePushConfiguration.self, from: data)
        XCTAssertFalse(config.approves(channel: "apns_voip", application: "com.synthetic.native", environment: "sandbox", qualified: false))
        XCTAssertTrue(config.approves(channel: "apns_voip", application: "com.synthetic.native", environment: "sandbox", qualified: true))
        XCTAssertFalse(config.approves(channel: "apns_voip", application: "com.other.native", environment: "sandbox", qualified: true))
        XCTAssertFalse(config.approves(channel: "apns_voip", application: "com.synthetic.native", environment: "production", qualified: true))
    }
    func testUnknownAdmissionOwnerCannotBeDecodedAsGenericAuthOrMedia() {
        XCTAssertThrowsError(try Wire.decoder().decode(NativeWakeAdmission.self, from: Data("{\"owner\":\"unknown\",\"access_token\":\"not-auth\"}".utf8)))
    }
    @MainActor func testPendingNativeCallReservationCannotStealForegroundCallSlot() {
        let slot = NativeCallSlot(); let foreground = UUID(); let wake = UUID()
        XCTAssertTrue(slot.acquire(foreground)); XCTAssertFalse(slot.acquire(wake)); slot.release(wake)
        XCTAssertFalse(slot.acquire(wake)); slot.release(foreground); XCTAssertTrue(slot.acquire(wake))
    }
}
