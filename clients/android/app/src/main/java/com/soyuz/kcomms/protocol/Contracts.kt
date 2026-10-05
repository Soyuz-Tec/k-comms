package com.soyuz.kcomms.protocol

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject

val WireJson = Json { ignoreUnknownKeys = true; explicitNulls = false }

@Serializable data class Tenant(val id: String, val slug: String = "", val name: String = "")
@Serializable data class User(
    val id: String,
    @SerialName("tenant_id") val tenantId: String,
    @SerialName("display_name") val displayName: String,
    @SerialName("account_type") val accountType: String,
    @SerialName("access_scope") val accessScope: String = "",
    val status: String = "",
    val role: String = "member",
    val version: Long = 0,
) {
    // Role alone never grants workspace access. Missing/unknown scope fails closed.
    val workspaceEligible get() = accountType == "human" && status == "active" && accessScope == "workspace"
}
@Serializable data class Device(val id: String, @SerialName("user_id") val userId: String)
@Serializable data class Authentication(
    @SerialName("access_token") val accessToken: String,
    @SerialName("refresh_token") val refreshToken: String,
    @SerialName("expires_in") val expiresIn: Long,
    val tenant: Tenant, val user: User, val device: Device,
) {
    override fun toString() = "Authentication(credentials redacted)"
    fun validate() {
        require(accessToken.length in 20..16384 && refreshToken.length in 20..16384)
        require(expiresIn in 1..86400 && user.accountType == "human" && user.status == "active")
        require(user.tenantId == tenant.id && device.userId == user.id)
        listOf(tenant.id, user.id, device.id).forEach { java.util.UUID.fromString(it) }
    }
}
@Serializable data class MfaChallenge(
    @SerialName("mfa_required") val required: Boolean,
    @SerialName("challenge_token") val token: String,
    @SerialName("expires_in") val expiresIn: Long,
) { override fun toString() = "MfaChallenge(token redacted)" }
sealed interface SignInResult {
    data class Authenticated(val authentication: Authentication) : SignInResult
    data class Challenge(val challenge: MfaChallenge) : SignInResult
}
@Serializable data class DirectoryPerson(
    val id: String,
    @SerialName("display_name") val displayName: String,
    @SerialName("presence_state") val presence: String? = null,
)
@Serializable data class DirectoryPage(val data: List<DirectoryPerson>, val page: CursorPage)
@Serializable data class CursorPage(@SerialName("next_cursor") val nextCursor: String? = null)
@Serializable data class Conversation(
    val id: String,
    @SerialName("tenant_id") val tenantId: String,
    val kind: String,
    val title: String? = null,
    @SerialName("counterpart_display_name") val counterpart: String? = null,
    @SerialName("latest_sequence") val latestSequence: Long = 0,
    @SerialName("unread_count") val unreadCount: Long = 0,
    @SerialName("archived_at") val archivedAt: String? = null,
) { val label get() = title ?: counterpart ?: "Direct conversation" }
@Serializable data class ConversationList(val data: List<Conversation>)
@Serializable data class ConversationResult(val data: Conversation)
@Serializable data class Message(
    val id: String,
    @SerialName("tenant_id") val tenantId: String,
    @SerialName("conversation_id") val conversationId: String,
    @SerialName("sender_user_id") val senderId: String?,
    @SerialName("client_message_id") val clientId: String,
    @SerialName("conversation_sequence") val sequence: Long,
    val body: String? = null,
    val status: String,
    @SerialName("edited_at") val editedAt: String? = null,
    @SerialName("deleted_at") val deletedAt: String? = null,
    @SerialName("inserted_at") val insertedAt: String,
) { val deleted get() = status == "deleted" || deletedAt != null }
@Serializable data class SenderLabel(val id: String, @SerialName("display_name") val name: String, val redacted: Boolean)
@Serializable data class MessageIncluded(@SerialName("sender_labels") val senderLabels: List<SenderLabel> = emptyList())
@Serializable data class MessagePage(
    val data: List<Message>, val page: MessagePaging,
    val included: MessageIncluded = MessageIncluded(),
)
@Serializable data class MessagePaging(
    @SerialName("has_more") val hasMore: Boolean,
    @SerialName("next_after_sequence") val nextAfterSequence: Long? = null,
    @SerialName("reset_required") val resetRequired: Boolean = false,
)
@Serializable data class MessageResult(val data: Message)
@Serializable data class SenderLabelsResult(val data: List<SenderLabel>)
@Serializable data class Call(
    val id: String,
    @SerialName("conversation_id") val conversationId: String,
    @SerialName("media_kind") val mediaKind: String,
    val status: String,
    @SerialName("can_end") val canEnd: Boolean = false,
    @SerialName("started_at") val startedAt: String,
    @SerialName("expires_at") val expiresAt: String,
    @SerialName("end_reason") val endReason: String? = null,
    @SerialName("tenant_id") val tenantId: String = "",
    @SerialName("started_by_user_id") val startedById: String? = null,
    @SerialName("ended_by_user_id") val endedById: String? = null,
    @SerialName("ended_at") val endedAt: String? = null,
    val version: Long = 0,
)
@Serializable data class IceServer(val urls: List<String>, val username: String? = null, val credential: String? = null)
@Serializable data class MediaCredential(
    @SerialName("server_url") val serverUrl: String,
    @SerialName("participant_token") val participantToken: String,
    @SerialName("expires_in") val expiresIn: Long,
    @SerialName("ice_servers") val iceServers: List<IceServer> = emptyList(),
) { override fun toString() = "MediaCredential(credentials redacted)" }
@Serializable data class CallAdmission(val data: Call, val credential: MediaCredential)
@Serializable data class CallParticipant(val id: String, @SerialName("user_id") val userId: String, val status: String)
@Serializable data class CallParticipants(val data: List<CallParticipant>)
@Serializable data class CallResult(val data: Call?)
@Serializable data class CallList(val data: List<Call>, val page: CallPaging)
@Serializable data class CallPaging(val limit: Int, @SerialName("has_more") val hasMore: Boolean, @SerialName("next_cursor") val nextCursor: String? = null)
@Serializable data class MeetingOccurrence(
    val id: String, val sequence: Int,
    @SerialName("starts_at") val startsAt: String,
    @SerialName("ends_at") val endsAt: String,
    val status: String,
    @SerialName("call_id") val callId: String? = null,
)
@Serializable data class Meeting(
    val id: String,
    @SerialName("conversation_id") val conversationId: String,
    @SerialName("host_user_id") val hostId: String?,
    val title: String, val timezone: String,
    @SerialName("local_start") val localStart: String,
    @SerialName("duration_minutes") val durationMinutes: Int,
    @SerialName("reminder_minutes") val reminderMinutes: Int,
    val status: String, val version: Long,
    val occurrences: List<MeetingOccurrence>,
    @SerialName("can_manage") val canManage: Boolean,
    val recurrence: MeetingRecurrence = MeetingRecurrence(),
    @SerialName("host_policy") val hostPolicy: MeetingHostPolicy = MeetingHostPolicy(),
)
@Serializable data class MeetingRecurrence(val frequency: String = "none", val interval: Int = 1, val count: Int = 1)
@Serializable data class MeetingHostPolicy(
    @SerialName("allow_guests") val allowGuests: Boolean = false,
    @SerialName("join_before_host") val joinBeforeHost: Boolean = false,
)
@Serializable data class MeetingList(val data: List<Meeting>)
@Serializable data class MeetingResult(val data: Meeting)
@Serializable data class TicketResult(val data: Ticket)
@Serializable data class Ticket(val ticket: String, @SerialName("expires_in") val expiresIn: Long)
@Serializable data class MemberCapabilities(
    @SerialName("allow_public_channels") val allowPublicChannels: Boolean = false,
    @SerialName("allow_audio_calls") val allowAudioCalls: Boolean = false,
    @SerialName("allow_video_calls") val allowVideoCalls: Boolean = false,
    @SerialName("allow_immersive_mode") val allowImmersiveMode: Boolean = false,
    @SerialName("message_edit_window_seconds") val messageEditWindowSeconds: Long = 0,
    @SerialName("max_attachment_bytes") val maxAttachmentBytes: Long = 0,
)
@Serializable data class Me(val user: User, val device: Device, val tenant: Tenant,
                            val capabilities: MemberCapabilities = MemberCapabilities())

@Serializable data class PhoneNumberAssignment(
    val id: String,
    @SerialName("phone_number") val phoneNumber: String,
    val extension: String,
    @SerialName("user_id") val userId: String,
    @SerialName("inbound_trunk_id") val inboundTrunkId: String? = null,
    @SerialName("outbound_trunk_id") val outboundTrunkId: String? = null,
)
@Serializable data class PhoneConfiguration(
    val enabled: Boolean,
    val configured: Boolean,
    val provider: String,
    val number: PhoneNumberAssignment? = null,
    @SerialName("can_manage") val canManage: Boolean,
    @SerialName("provider_ready") val providerReady: Boolean? = null,
    @SerialName("line_assigned") val lineAssigned: Boolean? = null,
) {
    val canCall get() = enabled && configured && (providerReady ?: configured) &&
        (lineAssigned ?: (number != null)) && number != null
}
@Serializable data class PhoneConfigurationResult(val data: PhoneConfiguration)
@Serializable data class PhoneCapability(
    val supported: Boolean,
    val reason: String? = null,
    val configured: Boolean? = null,
    val qualified: Boolean? = null,
    val transport: String? = null,
    val assurance: String? = null,
)
@Serializable data class PhoneCapabilities(
    val dtmf: PhoneCapability? = null,
    val hold: PhoneCapability? = null,
    val resume: PhoneCapability? = null,
    @SerialName("blind_transfer") val blindTransfer: PhoneCapability? = null,
    @SerialName("consult_transfer") val consultTransfer: PhoneCapability? = null,
    @SerialName("complete_transfer") val completeTransfer: PhoneCapability? = null,
    @SerialName("cancel_transfer") val cancelTransfer: PhoneCapability? = null,
    val voicemail: PhoneCapability? = null,
    val queues: PhoneCapability? = null,
    @SerialName("shared_lines") val sharedLines: PhoneCapability? = null,
)
@Serializable data class PhoneCapabilitiesResult(val data: PhoneCapabilities)
@Serializable data class PhoneCall(
    val id: String,
    val direction: String,
    val status: String,
    @SerialName("from_number") val fromNumber: String,
    @SerialName("to_number") val toNumber: String,
    val extension: String,
    @SerialName("started_at") val startedAt: String,
    @SerialName("connected_seconds") val connectedSeconds: Long,
    @SerialName("can_answer") val canAnswer: Boolean,
    @SerialName("can_join") val canJoin: Boolean,
    @SerialName("can_end") val canEnd: Boolean,
    @SerialName("active_on_this_device") val activeOnThisDevice: Boolean,
    @SerialName("answered_at") val answeredAt: String? = null,
    @SerialName("ended_at") val endedAt: String? = null,
    @SerialName("end_reason") val endReason: String? = null,
    @SerialName("control_state") val controlState: String? = null,
) { val active get() = status == "ringing" || status == "answered" }
@Serializable data class PhoneSession(val data: PhoneCall, val credential: MediaCredential)
@Serializable data class PhoneCallResult(val data: PhoneCall)
@Serializable data class PhoneCallsPage(val data: List<PhoneCall>, val page: CallPaging)
/** Submitted is SDK submission evidence; it does not assert carrier delivery. */
@Serializable data class PhoneControlReceipt(
    val id: String,
    @SerialName("call_id") val callId: String,
    val action: String,
    val status: String,
    val dispatch: Boolean,
    @SerialName("created_at") val createdAt: String,
    @SerialName("expires_at") val expiresAt: String,
    @SerialName("completed_at") val completedAt: String? = null,
    @SerialName("failure_reason") val failureReason: String? = null,
)
@Serializable data class PhoneControlResult(val data: PhoneControlReceipt)
@Serializable data class PhoneControlsResult(val data: List<PhoneControlReceipt>, val limit: Int)

class ApiFailure(val status: Int, val code: String) : Exception("HTTP $status: $code")
class IdentityChanged : Exception("This account or device changed. Sign in again.")
class WorkspaceAccessUnavailable : Exception("Workspace features are unavailable with your current access.")
class ProtocolFailure : Exception("The server returned an invalid response.")

fun decodeSignIn(body: String): SignInResult {
    val objectValue = WireJson.decodeFromString<JsonObject>(body)
    return if (objectValue["mfa_required"]?.toString() == "true") {
        val challenge = WireJson.decodeFromString<MfaChallenge>(body)
        require(challenge.required && challenge.token.length in 20..16384 && challenge.expiresIn in 1..300)
        SignInResult.Challenge(challenge)
    } else SignInResult.Authenticated(WireJson.decodeFromString<Authentication>(body).also { it.validate() })
}
