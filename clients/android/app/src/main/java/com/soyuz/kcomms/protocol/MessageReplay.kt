package com.soyuz.kcomms.protocol

import kotlinx.serialization.json.decodeFromJsonElement
import kotlinx.serialization.json.jsonPrimitive

/** A loaded conversation's authorized REST projection, never a global content cache. */
class MessageReplay(private val tenantId: String, private val conversationId: String) {
    companion object {
        const val MAX_MESSAGES = 500
        const val MAX_TOMBSTONES = 1000
    }
    private val messages = mutableMapOf<String, Message>()
    private val tombstones = mutableSetOf<String>()
    private val labels = mutableMapOf<String, SenderLabel>()
    private val redactedSenders = mutableSetOf<String>()
    var highWater: Long = 0
        private set
    val oldest: Long? get() = messages.values.minOfOrNull { it.sequence }
    val values: List<Message> get() = messages.values.sortedBy { it.sequence }

    fun clear() {
        messages.clear(); tombstones.clear(); labels.clear(); redactedSenders.clear(); highWater = 0
    }
    fun apply(page: MessagePage, historical: Boolean = false) {
        validatePage(page)
        if (page.page.resetRequired) {
            // A reset invalidates the loaded projection, but cannot resurrect a known deletion.
            messages.clear(); labels.clear(); highWater = 0
        }
        page.data.forEach { applyMessage(it) }
        // Only the current REST owner projection supplies retained sender labels.
        mergeLabels(page.included.senderLabels)
        page.page.nextAfterSequence?.let { next -> highWater = maxOf(highWater, next) }
        trim(historical)
    }
    private fun validatePage(page: MessagePage) {
        require(page.data.size <= MAX_MESSAGES)
        require(page.data.map { it.id }.distinct().size == page.data.size)
        require(page.data.zipWithNext().all { (left, right) -> left.sequence < right.sequence })
        page.data.forEach(::validate)
        page.page.nextAfterSequence?.let { require(it >= 0 && it == page.data.lastOrNull()?.sequence) }
    }
    fun apply(message: Message) {
        applyMessage(message)
        trim()
    }
    /** True means refresh the loaded REST projection and retained labels under the current lease. */
    fun apply(event: PhoenixEvent): Boolean {
        if (event.topic == "conversation:$conversationId") {
            when (event.event) {
                "message.created.v1", "message.updated.v1", "message.deleted.v1" -> {
                    val message = WireJson.decodeFromJsonElement<Message>(event.payload)
                    validate(message)
                    val known = message.id in messages
                    val adjacent = event.event == "message.created.v1" && highWater < Long.MAX_VALUE &&
                        message.sequence == highWater + 1 && (messages.isEmpty() || values.last().sequence == highWater)
                    if (known || adjacent) apply(message)
                    else if (message.deleted) rememberDeletion(message.id)
                    invalidateLabels()
                    return true
                }
                "membership.changed.v1", "conversation.updated.v1", "conversation.archived.v1" -> {
                    invalidateLabels()
                    return true
                }
            }
        } else if (event.topic.startsWith("user:") &&
            event.event in listOf("conversation.activity.v1", "conversation.membership.v1") &&
            event.payload["conversation_id"]?.jsonPrimitive?.content == conversationId) {
            invalidateLabels()
            return true
        }
        return false
    }
    private fun validate(message: Message) {
        require(message.tenantId == tenantId && message.conversationId == conversationId && message.sequence > 0)
        val previous = messages[message.id]
        require(previous == null || previous.sequence == message.sequence)
        // Parse before changing the projection, so malformed revisions cannot partially apply.
        java.time.Instant.parse(message.deletedAt ?: message.editedAt ?: message.insertedAt)
    }
    private fun applyMessage(message: Message) {
        validate(message)
        val previous = messages[message.id]
        if (message.deleted) rememberDeletion(message.id)
        if (message.id in tombstones) messages[message.id] = message.copy(body = null, status = "deleted")
        else {
            val revision = java.time.Instant.parse(message.editedAt ?: message.insertedAt)
            val priorRevision = previous?.let { java.time.Instant.parse(it.editedAt ?: it.insertedAt) }
            if (priorRevision == null || revision >= priorRevision) messages[message.id] = message
        }
        highWater = maxOf(highWater, message.sequence)
    }
    fun tombstone(id: String) {
        rememberDeletion(id)
        messages[id]?.let { messages[id] = it.copy(body = null, status = "deleted") }
    }
    private fun rememberDeletion(id: String) {
        if (id !in tombstones && tombstones.size >= MAX_TOMBSTONES) {
            clear()
            throw ProtocolFailure()
        }
        tombstones += id
    }
    /** Hide stale names immediately until the rendered window is reauthorized through REST. */
    fun invalidateLabels() { labels.entries.removeAll { !it.value.redacted } }
    /** Replace the complete loaded window's fresh owner projection; missing labels lose old names. */
    fun replaceLabels(current: List<SenderLabel>) {
        invalidateLabels()
        mergeLabels(current)
    }
    private fun mergeLabels(current: List<SenderLabel>) {
        val senderIds = messages.values.mapNotNull { it.senderId }.toSet()
        current.filter { it.id in senderIds }.forEach { label ->
            if (label.redacted) {
                if (label.id !in redactedSenders && redactedSenders.size >= MAX_TOMBSTONES) {
                    clear(); throw ProtocolFailure()
                }
                redactedSenders += label.id
            }
            labels[label.id] = if (label.id in redactedSenders) label.copy(name = "Deleted member", redacted = true) else label
        }
    }
    /** Call only after every page of the captured authorized visible range completed. */
    fun replaceVisibleRange(first: Long, last: Long, pages: List<MessagePage>) {
        require(first > 0 && last >= first)
        require(pages.isNotEmpty() && pages.size <= 5 && pages.sumOf { it.data.size } <= MAX_MESSAGES)
        require(pages.none { it.page.resetRequired } && pages.lastOrNull()?.page?.hasMore != true)
        pages.forEach(::validatePage)
        require(pages.flatMap { it.data }.zipWithNext().all { (left, right) -> left.sequence < right.sequence })
        val seen = pages.flatMap { it.data }.map { it.id }.toSet()
        pages.flatMap { it.data }.forEach { require(it.sequence in first..last) }
        messages.values.filter { it.sequence in first..last && it.id !in seen }.forEach { tombstone(it.id) }
        pages.forEach { apply(it) }
    }
    fun trim(historical: Boolean = false) {
        val retain = (if (historical) values.take(MAX_MESSAGES) else values.takeLast(MAX_MESSAGES)).map { it.id }.toSet()
        messages.keys.retainAll(retain)
        val senderIds = messages.values.mapNotNull { it.senderId }.toSet()
        labels.keys.retainAll(senderIds)
    }
    fun label(message: Message): String {
        if (message.deleted || message.senderId == null) return "Deleted member"
        return labels[message.senderId]?.let { if (it.redacted) "Deleted member" else it.name } ?: "Member"
    }
}
