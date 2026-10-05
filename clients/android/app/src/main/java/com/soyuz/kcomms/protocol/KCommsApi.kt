package com.soyuz.kcomms.protocol

import com.soyuz.kcomms.push.*
import com.soyuz.kcomms.security.IdentityLease
import com.soyuz.kcomms.security.PendingMessage
import com.soyuz.kcomms.security.SessionStore
import kotlinx.serialization.json.*
import java.time.Instant

/** Exact current /api/v1 routes, including the default-off native wake owner protocol. */
class KCommsApi(val sessions: SessionStore) {
    suspend fun signIn(endpoint: Endpoint, tenant: String, email: String, password: String): Pair<Long, SignInResult> {
        val epoch = sessions.resetForSignIn()
        val text = sessions.transport.request(endpoint, "POST", "/sessions", buildJsonObject {
            put("tenant_slug", tenant.trim()); put("email", email.trim()); put("password", password)
            put("device", buildJsonObject { put("name", "K-Comms Android"); put("platform", "android") })
        })
        sessions.requireSignInEpoch(epoch)
        val result = decodeSignIn(text)
        if (result is SignInResult.Authenticated) sessions.install(endpoint, result.authentication, epoch)
        return epoch to result
    }
    suspend fun completeMfa(endpoint: Endpoint, epoch: Long, challenge: String, code: String) {
        sessions.requireSignInEpoch(epoch)
        val text = sessions.transport.request(endpoint, "POST", "/auth/mfa", buildJsonObject {
            put("challenge_token", challenge); put("code", code.trim())
        })
        sessions.requireSignInEpoch(epoch)
        sessions.install(endpoint, WireJson.decodeFromString<Authentication>(text), epoch)
    }

    suspend fun nativePushConfiguration(lease: IdentityLease = sessions.capture()): NativePushConfiguration =
        WireJson.decodeFromString<NativeConfigurationResult>(sessions.authorized("GET", "/me/native-push/config", lease = lease)).data
    suspend fun nativeRegistrations(lease: IdentityLease = sessions.capture()): List<NativeRegistration> =
        WireJson.decodeFromString<NativeRegistrationList>(sessions.authorized("GET", "/me/native-push/registration", lease = lease)).data
    suspend fun registerNativePush(token: String, installation: String, application: String, version: Long,
                                   lease: IdentityLease = sessions.capture()): NativeRegistrationResult =
        WireJson.decodeFromString(sessions.authorized("PUT", "/me/native-push/registration", buildJsonObject {
            put("platform", "android"); put("channel", "fcm"); put("application_id", application); put("environment", "production")
            put("token", token); put("installation_id", uuid(installation)); put("expected_version", version)
        }, lease = lease))
    suspend fun revokeNativePush(version: Long, lease: IdentityLease = sessions.capture()) {
        sessions.authorized("DELETE", "/me/native-push/registration", buildJsonObject {
            put("channel", "fcm"); put("expected_version", version)
        }, lease = lease)
    }
    suspend fun admitNativeWake(id: String, lease: IdentityLease = sessions.capture()): NativeWakeAdmission =
        NativeWakeAdmission.decode(sessions.authorized("POST", "/native-call-wakes/${uuid(id)}/admit", lease = lease))

    suspend fun me(lease: IdentityLease = sessions.capture()): Me {
        val me = WireJson.decodeFromString<Me>(sessions.authorized("GET", "/me", lease = lease))
        sessions.updateOwnerMetadata(me, lease)
        return me
    }

    private suspend fun workspaceAuthorized(method: String, path: String, body: JsonObject? = null,
                                            query: Map<String, String> = emptyMap(), lease: IdentityLease): String {
        sessions.ensureFresh(lease)
        val generation = sessions.captureWorkspace(lease)
        val response = sessions.authorized(method, path, body, query = query, lease = lease)
        // Late workspace projections/admissions cannot survive withdrawal, even after a later regrant.
        sessions.requireWorkspace(lease, generation)
        return response
    }
    suspend fun directory(query: String = "", cursor: String? = null, lease: IdentityLease = sessions.capture()): DirectoryPage {
        val params = mutableMapOf("limit" to "30")
        if (query.isNotBlank()) params["q"] = query.trim()
        if (cursor != null) params["cursor"] = cursor
        return WireJson.decodeFromString(workspaceAuthorized("GET", "/directory/users", query = params, lease = lease))
    }
    suspend fun conversations(lease: IdentityLease = sessions.capture()): List<Conversation> =
        WireJson.decodeFromString<ConversationList>(sessions.authorized("GET", "/conversations", lease = lease)).data
    suspend fun direct(userId: String, lease: IdentityLease = sessions.capture()): Conversation =
        WireJson.decodeFromString<ConversationResult>(workspaceAuthorized("POST", "/direct-conversations", buildJsonObject {
            put("user_id", uuid(userId))
        }, lease = lease)).data
    suspend fun group(title: String, members: List<String>, lease: IdentityLease = sessions.capture()): Conversation =
        WireJson.decodeFromString<ConversationResult>(workspaceAuthorized("POST", "/conversations", buildJsonObject {
            put("kind", "group"); put("visibility", "private"); put("title", title.trim())
            put("member_ids", JsonArray(members.distinct().map { JsonPrimitive(uuid(it)) }))
        }, lease = lease)).data
    suspend fun history(conversationId: String, after: Long? = null, before: Long? = null,
                        limit: Int = 100, lease: IdentityLease = sessions.capture()): MessagePage {
        require(after == null || after >= 0); require(before == null || before > 0)
        require(after == null || before == null || after < before)
        val query = mutableMapOf("limit" to limit.coerceIn(1, 200).toString(), "include" to "sender_labels")
        if (after != null) query["after_sequence"] = after.toString()
        if (before != null) query["before_sequence"] = before.toString()
        return WireJson.decodeFromString(sessions.authorized("GET", "/conversations/${uuid(conversationId)}/messages", query = query, lease = lease))
    }
    /** The backend orders ascending; both bounds select a recent, bounded sequence window. */
    suspend fun latestHistory(conversation: Conversation, limit: Int = 100,
                              lease: IdentityLease = sessions.capture()): MessagePage {
        require(conversation.tenantId == lease.tenantId && conversation.latestSequence in 0 until Long.MAX_VALUE)
        val bounded = limit.coerceIn(1, 200)
        return history(conversation.id, after = (conversation.latestSequence - bounded).coerceAtLeast(0),
            before = conversation.latestSequence + 1, limit = bounded, lease = lease)
    }
    suspend fun senderLabels(conversationId: String, messageIds: List<String>,
                             lease: IdentityLease = sessions.capture()): List<SenderLabel> {
        require(messageIds.size in 1..200 && messageIds.distinct().size == messageIds.size)
        return WireJson.decodeFromString<SenderLabelsResult>(sessions.authorized("POST",
            "/conversations/${uuid(conversationId)}/message-sender-labels", buildJsonObject {
                put("message_ids", JsonArray(messageIds.map { JsonPrimitive(uuid(it)) }))
            }, lease = lease)).data
    }
    suspend fun edit(messageId: String, body: String, lease: IdentityLease = sessions.capture()): Message {
        require(body.isNotBlank() && body.toByteArray().size <= 16000)
        return WireJson.decodeFromString<MessageResult>(sessions.authorized("PATCH", "/messages/${uuid(messageId)}",
            buildJsonObject { put("body", body) }, lease = lease)).data.also {
            if (it.id != messageId || it.tenantId != lease.tenantId || it.senderId != lease.userId) throw ProtocolFailure()
        }
    }
    suspend fun delete(messageId: String, lease: IdentityLease = sessions.capture()): Message =
        WireJson.decodeFromString<MessageResult>(sessions.authorized("DELETE", "/messages/${uuid(messageId)}", lease = lease)).data.also {
            if (it.id != messageId || it.tenantId != lease.tenantId || !it.deleted) throw ProtocolFailure()
        }
    suspend fun send(command: PendingMessage, lease: IdentityLease): Message {
        sessions.requireCurrent(lease)
        require(command.origin == lease.origin && command.tenantId == lease.tenantId && command.userId == lease.userId &&
            command.deviceId == lease.deviceId && command.lineage == lease.lineage)
        require(sessions.pending(lease).contains(command)) { "Message content or identity changed; create a new command." }
        val result = WireJson.decodeFromString<MessageResult>(sessions.authorized("POST",
            "/conversations/${uuid(command.conversationId)}/messages", buildJsonObject {
                put("body", command.body); put("attachment_ids", JsonArray(emptyList()))
            }, idempotencyKey = uuid(command.commandId), lease = lease)).data
        if (result.tenantId != lease.tenantId || result.conversationId != command.conversationId ||
            result.clientId != command.commandId || result.senderId != lease.userId) throw ProtocolFailure()
        sessions.acknowledge(command, lease)
        return result
    }
    suspend fun markRead(conversationId: String, sequence: Long, lease: IdentityLease = sessions.capture()) {
        require(sequence >= 0)
        sessions.authorized("PUT", "/conversations/${uuid(conversationId)}/read-cursor", buildJsonObject {
            put("sequence", sequence)
        }, lease = lease)
    }
    suspend fun ticket(lease: IdentityLease): Ticket {
        val result = WireJson.decodeFromString<TicketResult>(sessions.authorized("POST", "/socket-tickets", lease = lease)).data
        require(result.ticket.length in 20..1024 && result.expiresIn in 1..300)
        return result
    }
    suspend fun activeCall(conversationId: String, lease: IdentityLease = sessions.capture()): Call? =
        WireJson.decodeFromString<CallResult>(sessions.authorized("GET", "/conversations/${uuid(conversationId)}/call", lease = lease)).data
    suspend fun participants(conversationId: String, callId: String, lease: IdentityLease): List<CallParticipant> =
        WireJson.decodeFromString<CallParticipants>(sessions.authorized("GET",
            "/conversations/${uuid(conversationId)}/calls/${uuid(callId)}/participants",
            query = mapOf("current_admission" to "true"), lease = lease)).data
    suspend fun calls(cursor: String? = null, lease: IdentityLease = sessions.capture()): CallList =
        WireJson.decodeFromString(sessions.authorized("GET", "/calls",
            query = buildMap { put("scope", "recent"); put("limit", "30"); if (cursor != null) put("cursor", cursor) }, lease = lease))
    suspend fun startCall(conversationId: String, video: Boolean, lease: IdentityLease): CallAdmission =
        WireJson.decodeFromString(sessions.authorized("POST", "/conversations/${uuid(conversationId)}/calls", buildJsonObject {
            put("media_kind", if (video) "video" else "audio")
        }, lease = lease))
    suspend fun joinCall(call: Call, lease: IdentityLease): CallAdmission =
        WireJson.decodeFromString(sessions.authorized("POST", "/conversations/${uuid(call.conversationId)}/calls/${uuid(call.id)}/join", lease = lease))
    suspend fun endCall(call: Call, lease: IdentityLease) {
        sessions.authorized("POST", "/conversations/${uuid(call.conversationId)}/calls/${uuid(call.id)}/end",
            buildJsonObject { put("reason", "ended_by_user") }, lease = lease)
    }
    suspend fun meetings(lease: IdentityLease = sessions.capture()): List<Meeting> {
        val now = Instant.now()
        return meetings(now.minusSeconds(86400).toString(), now.plusSeconds(7 * 86400).toString(), lease)
    }
    suspend fun meetings(from: String, to: String, lease: IdentityLease = sessions.capture()): List<Meeting> {
        val start = Instant.parse(from); val end = Instant.parse(to)
        require(start < end)
        return WireJson.decodeFromString<MeetingList>(workspaceAuthorized("GET", "/meetings",
            query = mapOf("from" to start.toString(), "to" to end.toString()), lease = lease)).data
    }
    suspend fun schedule(conversationId: String, title: String, localStart: String, timezone: String,
                         duration: Int, lease: IdentityLease = sessions.capture()): Meeting =
        WireJson.decodeFromString<MeetingResult>(workspaceAuthorized("POST",
            "/conversations/${uuid(conversationId)}/meetings", buildJsonObject {
                put("title", title.trim()); put("local_start", localStart.trim()); put("timezone", timezone.trim())
                put("duration_minutes", duration); put("reminder_minutes", 10)
                put("recurrence", buildJsonObject { put("frequency", "none"); put("interval", 1); put("count", 1) })
                put("host_policy", buildJsonObject { put("allow_guests", false); put("join_before_host", false) })
            }, lease = lease)).data
    suspend fun cancelMeeting(meeting: Meeting, lease: IdentityLease): Meeting =
        WireJson.decodeFromString<MeetingResult>(workspaceAuthorized("POST", "/meetings/${uuid(meeting.id)}/cancel",
            buildJsonObject { put("expected_version", meeting.version) }, lease = lease)).data
    suspend fun startMeeting(meeting: Meeting, occurrence: MeetingOccurrence, video: Boolean, lease: IdentityLease): CallAdmission =
        WireJson.decodeFromString(workspaceAuthorized("POST", "/meetings/${uuid(meeting.id)}/occurrences/${uuid(occurrence.id)}/start",
            buildJsonObject { put("media_kind", if (video) "video" else "audio") }, lease = lease))

    suspend fun phoneConfiguration(lease: IdentityLease = sessions.capture()): PhoneConfiguration =
        WireJson.decodeFromString<PhoneConfigurationResult>(workspaceAuthorized("GET", "/telephony/config", lease = lease)).data
    suspend fun phoneCapabilities(lease: IdentityLease = sessions.capture()): PhoneCapabilities =
        WireJson.decodeFromString<PhoneCapabilitiesResult>(workspaceAuthorized("GET", "/telephony/capabilities", lease = lease)).data
    suspend fun phoneCalls(cursor: String? = null, lease: IdentityLease = sessions.capture()): PhoneCallsPage =
        WireJson.decodeFromString(workspaceAuthorized("GET", "/telephony/calls",
            query = buildMap { put("limit", "30"); if (cursor != null) put("cursor", cursor) }, lease = lease))
    suspend fun phoneCall(id: String, lease: IdentityLease = sessions.capture()): PhoneCall =
        WireJson.decodeFromString<PhoneCallResult>(workspaceAuthorized("GET", phonePath(id), lease = lease)).data.also {
            if (it.id != id) throw ProtocolFailure()
        }
    suspend fun dialPhone(destination: String, commandId: String, lease: IdentityLease): PhoneSession {
        require(Regex("^\\+[1-9][0-9]{7,14}$").matches(destination))
        return WireJson.decodeFromString(workspaceAuthorized("POST", "/telephony/calls", buildJsonObject {
            put("destination", destination); put("idempotency_key", uuid(commandId))
        }, lease = lease))
    }
    suspend fun answerPhone(id: String, lease: IdentityLease): PhoneSession = phoneAdmission(id, "answer", lease)
    suspend fun joinPhone(id: String, lease: IdentityLease): PhoneSession = phoneAdmission(id, "join", lease)
    suspend fun rejectPhone(id: String, lease: IdentityLease): PhoneCall = phoneAction(id, "reject", lease)
    suspend fun endPhone(id: String, lease: IdentityLease): PhoneCall = phoneAction(id, "end", lease)
    suspend fun phoneControls(id: String, lease: IdentityLease = sessions.capture()): PhoneControlsResult =
        WireJson.decodeFromString(workspaceAuthorized("GET", "${phonePath(id)}/controls", lease = lease))
    /** A retry with the same command ID is reconciliation and never authorizes another SDK digit. */
    suspend fun phoneControl(id: String, digit: String, commandId: String, lease: IdentityLease): PhoneControlReceipt {
        require(Regex("^[0-9*#ABCD]$").matches(digit))
        return WireJson.decodeFromString<PhoneControlResult>(workspaceAuthorized("POST", "${phonePath(id)}/controls",
            buildJsonObject { put("action", "dtmf"); put("digit", digit); put("idempotency_key", uuid(commandId)) },
            lease = lease)).data.also { validateControl(it, id) }
    }
    /** Use the returned receipt ID here, which is distinct from the request's idempotency key. */
    suspend fun completePhoneControl(id: String, commandId: String, status: String, lease: IdentityLease): PhoneControlReceipt {
        require(status == "submitted" || status == "unknown")
        return WireJson.decodeFromString<PhoneControlResult>(workspaceAuthorized("POST",
            "${phonePath(id)}/controls/${uuid(commandId)}/complete", buildJsonObject { put("status", status) },
            lease = lease)).data.also { validateControl(it, id, commandId) }
    }
    suspend fun reconcilePhoneControl(id: String, commandId: String, lease: IdentityLease): PhoneControlReceipt =
        WireJson.decodeFromString<PhoneControlResult>(workspaceAuthorized("POST",
            "${phonePath(id)}/controls/${uuid(commandId)}/reconcile", lease = lease)).data.also {
            validateControl(it, id, commandId)
        }

    private suspend fun phoneAdmission(id: String, action: String, lease: IdentityLease): PhoneSession =
        WireJson.decodeFromString<PhoneSession>(workspaceAuthorized("POST", "${phonePath(id)}/$action", lease = lease)).also {
            if (it.data.id != id) throw ProtocolFailure()
        }
    private suspend fun phoneAction(id: String, action: String, lease: IdentityLease): PhoneCall =
        WireJson.decodeFromString<PhoneCallResult>(workspaceAuthorized("POST", "${phonePath(id)}/$action", lease = lease)).data.also {
            if (it.id != id) throw ProtocolFailure()
        }
    private fun phonePath(id: String) = "/telephony/calls/${uuid(id)}"
    private fun validateControl(receipt: PhoneControlReceipt, callId: String, receiptId: String? = null) {
        if (receipt.callId != callId || receiptId != null && receipt.id != receiptId || receipt.action != "dtmf" ||
            receipt.status !in listOf("pending", "dispatching", "submitted", "failed", "unknown") ||
            receipt.dispatch && (receipt.status != "dispatching" || Instant.parse(receipt.expiresAt) <= Instant.now())) throw ProtocolFailure()
        uuid(receipt.id)
    }

    private fun uuid(value: String) = java.util.UUID.fromString(value).toString()
}
