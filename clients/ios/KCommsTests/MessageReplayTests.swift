import XCTest
@testable import KComms

final class MessageReplayTests: XCTestCase {
    private let tenant = "00000000-0000-0000-0000-000000000001"
    private let conversation = "00000000-0000-0000-0000-000000000002"
    private let sender = "00000000-0000-0000-0000-000000000003"
    private func message(_ sequence: Int64, body: String = "Original", status: String = "active", revision: String? = nil, foreign: Bool = false) throws -> Message {
        let object: [String: Any] = ["id": String(format: "00000000-0000-0000-0000-%012lld", sequence + 10), "tenant_id": foreign ? "foreign" : tenant,
            "conversation_id": conversation, "sender_user_id": sender, "client_message_id": "synthetic-\(sequence)", "conversation_sequence": sequence,
            "body": body, "status": status, "edited_at": revision as Any? ?? NSNull(), "deleted_at": status == "deleted" ? (revision as Any? ?? NSNull()) : NSNull(),
            "inserted_at": "2026-10-05T10:00:00Z", "attachments": []]
        return try Wire.decoder().decode(Message.self, from: JSONSerialization.data(withJSONObject: object))
    }
    private func page(_ messages: [Message], more: Bool = false, next: Int64? = nil) -> MessagePage {
        MessagePage(data: messages, page: .init(hasMore: more, nextAfterSequence: next, resetRequired: false), included: nil)
    }
    func testVisibleRangeRefreshReplacesEditAndDeletionAtOldSequence() throws {
        var replay = MessageReplay()
        try replay.accept(page([message(1), message(2)]), conversation: conversation, tenant: tenant)
        let refreshed = try [message(1, body: "Edited", revision: "2026-10-05T11:00:00Z"), message(2, status: "deleted", revision: "2026-10-05T11:01:00Z")]
        try replay.reconcile([page(refreshed)], after: 0, through: 2, conversation: conversation, tenant: tenant)
        XCTAssertEqual(replay.sorted[0].visibleBody, "Edited"); XCTAssertEqual(replay.sorted[1].visibleBody, "Message removed")
    }
    func testCompleteRangeRemovesMissingRetainedRecordsButKeepsOutsideRange() throws {
        var replay = MessageReplay()
        try replay.accept(page([message(1), message(2), message(3)]), conversation: conversation, tenant: tenant)
        try replay.reconcile([page([message(3)])], after: 1, through: 3, conversation: conversation, tenant: tenant)
        XCTAssertEqual(replay.sorted.map(\.conversationSequence), [1, 3])
    }
    func testDeletedMessageCannotBeResurrectedByLateOriginalRevision() throws {
        var replay = MessageReplay()
        replay.merge(try message(1, status: "deleted", revision: "2026-10-05T11:00:00Z")); replay.merge(try message(1))
        XCTAssertEqual(replay.sorted.first?.status, "deleted")
    }
    func testObservedDeletionSurvivesVisibleWindowEviction() throws {
        var replay = MessageReplay(); let deleted = try message(1, status: "deleted", revision: "2026-10-05T11:00:00Z")
        replay.merge(deleted)
        try replay.reconcile([page(try (1000...1600).map { try message(Int64($0)) })], after: 999, through: 1600, conversation: conversation, tenant: tenant)
        XCTAssertNil(replay.messages[deleted.id]); replay.merge(try message(1)); XCTAssertNil(replay.messages[deleted.id])
    }
    func testOmittedCurrentRangeRowCannotBeRestoredByOldOriginal() throws {
        var replay = MessageReplay(); let original = try message(1); replay.merge(original)
        try replay.reconcile([page([])], after: 0, through: 1, conversation: conversation, tenant: tenant)
        replay.merge(original); XCTAssertTrue(replay.messages.isEmpty)
    }
    func testOlderWindowUsesItsOwnForwardCursorWithoutLosingSocketHighWater() throws {
        var replay = MessageReplay(); try replay.accept(page([message(10000)]), conversation: conversation, tenant: tenant)
        try replay.reconcile([page([message(1), message(2)])], after: 0, through: 500, conversation: conversation, tenant: tenant, historical: true)
        XCTAssertEqual(replay.cursor, 10000); XCTAssertEqual(replay.forwardCursor, 2)
        XCTAssertEqual(replay.sorted.map(\.conversationSequence), [1, 2])
    }
    func testRemovalMemoryBudgetFailsClosedInsteadOfDroppingObservedDeletions() throws {
        var replay = MessageReplay()
        let rows = try (1...2001).map { try message(Int64($0), status: "deleted", revision: "2026-10-05T11:00:00Z") }
        XCTAssertThrowsError(try replay.reconcile([page(rows)], after: 0, through: 2001, conversation: conversation, tenant: tenant))
        let original = try message(2001); replay.merge(original); XCTAssertNil(replay.messages[original.id])
    }
    func testReplacementLabelSidecarRemovesOldDisplayName() throws {
        var replay = MessageReplay(); replay.merge(try message(1))
        try replay.replaceLabels([SenderLabel(id: sender, displayName: "Previous name", redacted: false)])
        try replay.replaceLabels([SenderLabel(id: sender, displayName: "Former member", redacted: true)])
        XCTAssertEqual(replay.labels[sender]?.displayName, "Former member")
        try replay.replaceLabels([]); XCTAssertNil(replay.labels[sender])
        try replay.replaceLabels([SenderLabel(id: sender, displayName: "Previous name", redacted: false)])
        XCTAssertEqual(replay.labels[sender]?.displayName, "Former member")
    }
    func testForeignTenantPageIsRejectedWithoutImportingItsRows() throws {
        var replay = MessageReplay()
        XCTAssertThrowsError(try replay.accept(page([message(1, foreign: true)]), conversation: conversation, tenant: tenant))
        XCTAssertTrue(replay.messages.isEmpty)
    }
    func testHasMoreMustAdvanceTheRequestedReplayCursor() throws {
        var replay = MessageReplay()
        XCTAssertThrowsError(try replay.accept(page([], more: true, next: 10), conversation: conversation, tenant: tenant, after: 10))
    }
    func testReplayRetainsBoundedVisibleWindow() throws {
        var replay = MessageReplay()
        try replay.reconcile([page(try (1...600).map { try message(Int64($0)) })], after: 0, through: 600, conversation: conversation, tenant: tenant)
        XCTAssertEqual(replay.sorted.count, 500); XCTAssertEqual(replay.sorted.first?.conversationSequence, 101)
    }
    func testLeaseRejectsExpiredCredentialsIdentitySwitchAndAuthorityTimeout() {
        let now = Date(timeIntervalSince1970: 100)
        let stamp = IdentityStamp(identity: .init(tenant: tenant, user: sender, device: "device"), generation: 1)
        let lease = AuthorityLease(stamp: stamp, credentialExpires: now.addingTimeInterval(30), lastObserved: now, uptime: 100)
        XCTAssertTrue(lease.valid(stamp: stamp, now: now.addingTimeInterval(5), uptime: 105))
        XCTAssertFalse(lease.valid(stamp: stamp, now: now.addingTimeInterval(11), uptime: 111))
        XCTAssertFalse(lease.valid(stamp: stamp, now: now.addingTimeInterval(30), uptime: 130))
        XCTAssertFalse(lease.valid(stamp: .init(identity: stamp.identity, generation: 2), now: now, uptime: 100))
    }
    func testClockRollbackCannotExtendCredentialOrAuthorityLease() {
        let now = Date(timeIntervalSince1970: 100)
        let stamp = IdentityStamp(identity: .init(tenant: tenant, user: sender, device: "device"), generation: 1)
        var lease = AuthorityLease(stamp: stamp, credentialExpires: now.addingTimeInterval(30), lastObserved: now, uptime: 100)
        XCTAssertFalse(lease.valid(stamp: stamp, now: now.addingTimeInterval(-60), uptime: 111))
        lease.observe(now: now.addingTimeInterval(-60), uptime: 125)
        XCTAssertTrue(lease.valid(stamp: stamp, now: now.addingTimeInterval(-60), uptime: 126))
        XCTAssertFalse(lease.valid(stamp: stamp, now: now.addingTimeInterval(-60), uptime: 130))
        XCTAssertFalse(lease.valid(stamp: stamp, now: now, uptime: 124))
    }
    @MainActor func testCallReservationRejectsConcurrentTabsAndReentrantAdmission() {
        let slot = NativeCallSlot(); let chat = UUID(); let phone = UUID()
        XCTAssertTrue(slot.acquire(chat)); XCTAssertFalse(slot.acquire(chat)); XCTAssertFalse(slot.acquire(phone))
        slot.release(phone); XCTAssertFalse(slot.acquire(phone))
        slot.release(chat); XCTAssertTrue(slot.acquire(phone)); XCTAssertFalse(slot.acquire(chat))
    }
    func testToneRequiresExactOwnerDispatchReceiptAndUnexpiredCommand() {
        let receipt = PhoneControlReceipt(id: "receipt", callId: "call", action: "dtmf", status: "dispatching", dispatch: true,
            createdAt: "2026-10-05T10:00:00Z", expiresAt: "2026-10-05T10:01:00Z", completedAt: nil, failureReason: nil)
        XCTAssertTrue(receipt.authorizesTone(call: "call", now: Wire.date("2026-10-05T10:00:10Z")!))
        XCTAssertFalse(receipt.authorizesTone(call: "foreign", now: Wire.date("2026-10-05T10:00:10Z")!))
        XCTAssertFalse(receipt.authorizesTone(call: "call", now: Wire.date("2026-10-05T10:01:00Z")!))
    }
    func testUnqualifiedNativeWakeCannotJoinMedia() { XCTAssertFalse(NativePushAvailability.backgroundRingingEnabled); XCTAssertThrowsError(try NativePushAvailability.acceptUnqualifiedWake()) }
}
