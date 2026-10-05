package com.soyuz.kcomms.ui

import com.soyuz.kcomms.protocol.*
import com.soyuz.kcomms.security.*
import org.junit.Assert.*
import org.junit.Test

class WorkspaceScopeTest {
    private val tenant = "11111111-1111-4111-8111-111111111111"
    private val userId = "22222222-2222-4222-8222-222222222222"
    private val deviceId = "33333333-3333-4333-8333-333333333333"
    private val conversationId = "44444444-4444-4444-8444-444444444444"
    private val lease = IdentityLease(7, "https://example.test", tenant, userId, deviceId, "same-login-lineage")
    private fun identity(scope: String = "workspace", role: String = "member") = SessionIdentity(lease,
        Authentication("synthetic-access-token-123456", "synthetic-refresh-token-123456", 3600,
            Tenant(tenant), User(userId, tenant, "Member", "human", scope, "active", role), Device(deviceId, userId)))
    private fun populated() = AppState(restoring = false, identity = identity(), section = AppSection.PHONE,
        conversations = listOf(Conversation(conversationId, tenant, "group", title = "Admitted conversation")),
        selected = Conversation(conversationId, tenant, "group", title = "Admitted conversation"),
        messages = listOf(RenderedMessage(Message("message", tenant, conversationId, userId, "client", 1,
            "retained body", "accepted", insertedAt = "2026-01-01T00:00:00Z"), "Current sender")),
        pending = listOf(PendingMessage("command", lease.origin, tenant, userId, deviceId, lease.lineage, conversationId, "queued body")),
        calls = listOf(Call("call", conversationId, "audio", "active", startedAt = "2026-01-01T00:00:00Z", expiresAt = "2026-01-01T00:01:00Z")),
        directory = listOf(DirectoryPerson(userId, "Directory name")), directoryQuery = "private query", directoryCursor = "cursor",
        meetings = listOf(Meeting("meeting", conversationId, userId, "Private meeting", "UTC", "2026-01-01T00:00:00", 30, 10,
            "scheduled", 1, emptyList(), true)), phoneConfiguration = PhoneConfiguration(true, true, "provider", canManage = false),
        phoneCapabilities = PhoneCapabilities(dtmf = PhoneCapability(true)),
        phoneCalls = listOf(PhoneCall("phone", "outbound", "answered", "+12025550000", "+12025550123", "1234",
            "2026-01-01T00:00:00Z", 42, false, true, true, true)), phoneCursor = "phone-cursor",
        phoneControl = PhoneControlReceipt("receipt", "phone", "dtmf", "unknown", false,
            "2026-01-01T00:00:00Z", "2026-01-01T00:01:00Z"), pendingDialDestination = "+12025550123")

    @Test fun limitedActiveHumanRetainsConversationsAndCallsWithoutWorkspaceTabs() {
        val state = AppState(identity = identity("conversation_only", "owner"))
        assertEquals(listOf(AppSection.CONVERSATIONS, AppSection.CALLS), state.visibleSections)
        assertFalse(state.workspaceEligible)
        val owner = state.identity!!.authentication.user
        listOf(owner.copy(accessScope = ""), owner.copy(accessScope = "unknown"),
            owner.copy(accessScope = "workspace", status = ""), owner.copy(accessScope = "workspace", status = "suspended"),
            owner.copy(accessScope = "workspace", accountType = "service")).forEach { assertFalse(it.workspaceEligible) }
    }
    @Test fun withdrawingWorkspaceAccessClearsWorkspaceCachesAndKeepsConversationState() {
        val previous = populated()
        val narrowed = previous.withOwnerIdentity(identity("conversation_only", "owner"))
        assertEquals(lease, narrowed.identity?.lease); assertEquals(AppSection.CONVERSATIONS, narrowed.section)
        assertTrue(narrowed.directory.isEmpty()); assertEquals("", narrowed.directoryQuery); assertNull(narrowed.directoryCursor)
        assertTrue(narrowed.meetings.isEmpty()); assertNull(narrowed.phoneConfiguration); assertNull(narrowed.phoneCapabilities)
        assertTrue(narrowed.phoneCalls.isEmpty()); assertNull(narrowed.phoneCursor); assertNull(narrowed.phoneControl); assertNull(narrowed.pendingDialDestination)
        assertEquals(previous.conversations, narrowed.conversations); assertEquals(previous.selected, narrowed.selected)
        assertEquals(previous.messages, narrowed.messages); assertEquals(previous.pending, narrowed.pending); assertEquals(previous.calls, narrowed.calls)
    }
    @Test fun restoredWorkspaceEligibilityRequiresFreshWorkspaceProjections() {
        val narrowed = populated().withOwnerIdentity(identity("conversation_only"))
        val regranted = narrowed.withOwnerIdentity(identity("workspace", "moderator"))
        assertEquals(AppSection.entries, regranted.visibleSections); assertEquals(lease, regranted.identity?.lease)
        assertTrue(regranted.directory.isEmpty()); assertTrue(regranted.meetings.isEmpty()); assertTrue(regranted.phoneCalls.isEmpty())
        assertNull(regranted.phoneConfiguration); assertNull(regranted.phoneControl)
        assertEquals(narrowed.messages, regranted.messages); assertEquals(narrowed.pending, regranted.pending)
    }
    @Test fun legitimateRoleChangeWithinWorkspacePreservesSelectedFeatureAndCaches() {
        val previous = populated()
        val changed = previous.withOwnerIdentity(identity("workspace", "admin"))
        assertEquals(lease, changed.identity?.lease); assertEquals("admin", changed.identity?.authentication?.user?.role)
        assertEquals(previous.section, changed.section); assertEquals(previous.directory, changed.directory)
        assertEquals(previous.meetings, changed.meetings); assertEquals(previous.phoneCalls, changed.phoneCalls)
        assertEquals(previous.phoneConfiguration, changed.phoneConfiguration); assertEquals(previous.messages, changed.messages)
    }
}
