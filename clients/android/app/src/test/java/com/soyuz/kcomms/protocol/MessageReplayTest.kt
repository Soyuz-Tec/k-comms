package com.soyuz.kcomms.protocol

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.encodeToJsonElement
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.*
import org.junit.Test

class MessageReplayTest {
    private val tenant = "00000000-0000-4000-8000-000000000001"
    private val conversation = "00000000-0000-4000-8000-000000000002"
    private val sender = "00000000-0000-4000-8000-000000000003"
    private fun message(sequence: Long, body: String = "original") = Message(
        id = "message-$sequence", tenantId = tenant, conversationId = conversation,
        senderId = sender, clientId = "command-$sequence", sequence = sequence,
        body = body, status = "accepted", insertedAt = "2026-01-01T00:00:00Z",
    )
    private fun page(vararg messages: Message, more: Boolean = false, labels: List<SenderLabel> = emptyList()) =
        MessagePage(messages.toList(), MessagePaging(more, messages.lastOrNull()?.sequence), MessageIncluded(labels))
    private fun event(kind: String, value: Message) = PhoenixEvent("conversation:$conversation", kind,
        WireJson.encodeToJsonElement(value).jsonObject)

    @Test fun realtimeEditsWinOverDelayedHistoryAndDeletionNeverResurrects() {
        val replay = MessageReplay(tenant, conversation)
        val original = message(4)
        replay.apply(page(original, labels = listOf(SenderLabel(sender, "Ada", false))))
        assertEquals("Ada", replay.label(original))
        assertTrue(replay.apply(event("message.updated.v1", original.copy(body = "edited", editedAt = "2026-01-01T00:01:00Z"))))
        assertEquals("Member", replay.label(original))
        replay.apply(page(original))
        assertEquals("edited", replay.values.single().body)
        assertTrue(replay.apply(event("message.deleted.v1", original.copy(body = null, status = "deleted", deletedAt = "2026-01-01T00:02:00Z"))))
        replay.apply(page(original.copy(body = "late edit", editedAt = "2026-01-01T00:03:00Z")))
        assertTrue(replay.values.single().deleted)
        assertNull(replay.values.single().body)
        assertEquals(4L, replay.highWater)
    }

    @Test fun freshLabelsDropMissingNamesAndRedactionSurvivesTrimAndReset() {
        val replay = MessageReplay(tenant, conversation)
        val original = message(1)
        replay.apply(page(original, labels = listOf(SenderLabel(sender, "Ada", false))))
        replay.replaceLabels(emptyList())
        assertEquals("Member", replay.label(original))
        replay.replaceLabels(listOf(SenderLabel(sender, "Deleted member", true)))
        replay.replaceLabels(listOf(SenderLabel(sender, "Stale Ada", false)))
        assertEquals("Deleted member", replay.label(original))
        (2L..501L).forEach { replay.apply(message(it).copy(senderId = "other-sender")) }
        assertEquals(2L, replay.oldest)
        replay.apply(page(original, labels = listOf(SenderLabel(sender, "Trimmed stale Ada", false))), historical = true)
        assertEquals("Deleted member", replay.label(original))
        replay.apply(MessagePage(listOf(original), MessagePaging(false, 1, resetRequired = true),
            MessageIncluded(listOf(SenderLabel(sender, "Old Ada", false)))))
        assertEquals("Deleted member", replay.label(original))
        replay.clear()
        assertTrue(replay.values.isEmpty())
        assertEquals(0L, replay.highWater)
    }

    @Test fun realtimeEventsReauthorizeWithoutExpandingTheLoadedWindowAcrossGaps() {
        val replay = MessageReplay(tenant, conversation)
        replay.apply(page(message(100), message(101)))
        assertTrue(replay.apply(event("message.updated.v1", message(1).copy(body = "old edit", editedAt = "2026-01-01T00:01:00Z"))))
        assertTrue(replay.apply(event("message.deleted.v1", message(2).copy(body = null, status = "deleted"))))
        assertTrue(replay.apply(event("message.created.v1", message(103))))
        assertEquals(listOf(100L, 101L), replay.values.map { it.sequence })
        assertEquals(101L, replay.highWater)
        assertTrue(replay.apply(event("message.created.v1", message(102))))
        assertEquals(listOf(100L, 101L, 102L), replay.values.map { it.sequence })
        replay.apply(page(message(2)), historical = true)
        assertNull(replay.values.first().body)
        // The latest observed cursor must not append a new live message to an older loaded window.
        (103L..650L).forEach { replay.apply(message(it)) }
        replay.apply(page(message(3), message(4)), historical = true)
        val before = replay.values.map { it.sequence }
        assertTrue(replay.apply(event("message.created.v1", message(651))))
        assertEquals(before, replay.values.map { it.sequence })
        assertEquals(650L, replay.highWater)
    }

    @Test fun missingMessagesBecomeTombstonesOnlyAfterCompleteVisibleReplay() {
        val replay = MessageReplay(tenant, conversation)
        val first = message(1); val second = message(2)
        replay.apply(page(first, second))
        assertThrows(IllegalArgumentException::class.java) {
            replay.replaceVisibleRange(1, 2, listOf(page(first, more = true)))
        }
        assertEquals("original", replay.values.last().body)
        assertThrows(IllegalArgumentException::class.java) { replay.replaceVisibleRange(1, 2, emptyList()) }
        replay.replaceVisibleRange(1, 2, listOf(page(first)))
        assertTrue(replay.values.last().deleted)
        replay.apply(second)
        assertNull(replay.values.last().body)
    }

    @Test fun everyRetainedProjectionIsBoundedIncludingHistoricalPagingAndTombstones() {
        val replay = MessageReplay(tenant, conversation)
        (1L..600L).forEach { replay.apply(message(it)) }
        assertEquals(500, replay.values.size)
        assertEquals(101L, replay.oldest)
        replay.apply(page(message(1), message(2)), historical = true)
        assertEquals(500, replay.values.size)
        assertEquals(1L, replay.oldest)
        assertEquals(600L, replay.highWater)
        repeat(MessageReplay.MAX_TOMBSTONES) { replay.tombstone("deleted-$it") }
        assertThrows(ProtocolFailure::class.java) { replay.tombstone("overflow") }
        assertTrue(replay.values.isEmpty())
        assertEquals(0L, replay.highWater)
    }

    @Test fun invalidScopeOrRevisionCannotChangeTheLoadedProjection() {
        val replay = MessageReplay(tenant, conversation)
        replay.apply(message(1))
        assertThrows(IllegalArgumentException::class.java) {
            replay.apply(page(message(2), message(3).copy(tenantId = "another tenant")))
        }
        assertEquals(listOf(message(1)), replay.values)
        assertThrows(IllegalArgumentException::class.java) { replay.apply(message(1).copy(sequence = 2)) }
        assertFalse(replay.apply(PhoenixEvent("conversation:other", "message.deleted.v1", buildJsonObject {})))
        assertTrue(replay.apply(PhoenixEvent("user:$sender", "conversation.membership.v1", buildJsonObject {
            put("conversation_id", conversation)
        })))
        assertEquals(1L, replay.highWater)
    }
}
