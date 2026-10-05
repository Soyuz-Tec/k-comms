package com.soyuz.kcomms.protocol

import com.soyuz.kcomms.security.CredentialVault
import com.soyuz.kcomms.security.SessionStore
import com.soyuz.kcomms.security.StoredState
import java.io.Closeable
import java.time.Instant
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.*
import java.util.concurrent.CountDownLatch
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.*
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okhttp3.mockwebserver.Dispatcher
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.Assert.*
import org.junit.Test

class KCommsApiTest {
    @Test fun limitedHumanOwnerMetadataKeepsAdmittedConversationAndCallRoutesAvailable() = runBlocking {
        ProtocolFixture().use { f ->
            val originalLease = f.lease
            val command = f.sessions.enqueue(f.conversationId, "same queued body", originalLease)
            val limited = f.authentication.user.copy(accessScope = "conversation_only", role = "owner")
            val me = Me(limited, f.authentication.device, f.authentication.tenant,
                MemberCapabilities(allowAudioCalls = true))
            f.respond(me)
            assertEquals(me, f.api.me(originalLease)); assertEquals("/api/v1/me", f.request().path)
            assertEquals(originalLease, f.lease); assertEquals(limited, f.sessions.identity.value?.authentication?.user)
            assertEquals(listOf(command), f.sessions.pending(originalLease))
            val conversation = Conversation(f.conversationId, f.tenantId, "group", title = "Admitted room")
            f.respond(ConversationList(listOf(conversation)))
            assertEquals(listOf(conversation), f.api.conversations(originalLease))
            assertEquals("/api/v1/conversations", f.request().path)
            val admission = CallAdmission(Call(f.callId, f.conversationId, "audio", "active",
                startedAt = "2026-01-01T00:00:00Z", expiresAt = "2026-01-01T00:01:00Z", tenantId = f.tenantId), f.credential())
            f.respond(admission)
            assertEquals(admission, f.api.startCall(f.conversationId, false, originalLease))
            assertEquals("/api/v1/conversations/${f.conversationId}/calls", f.request().path)
            val before = f.server.requestCount
            listOf<suspend () -> Unit>(
                { f.api.directory(lease = originalLease) }, { f.api.direct(f.userId, originalLease) },
                { f.api.group("Group", listOf(f.userId), originalLease) }, { f.api.meetings(originalLease) },
                { f.api.phoneConfiguration(originalLease) }, { f.api.dialPhone("+12025550123", f.commandId, originalLease) },
            ).forEach { unavailable ->
                try { unavailable(); fail("Limited human obtained workspace access") }
                catch (_: WorkspaceAccessUnavailable) { }
            }
            assertEquals(before, f.server.requestCount); assertEquals(originalLease, f.lease)
        }
    }
    @Test fun missingOrUnknownOwnerScopeCannotGrantWorkspaceFeaturesEvenWithOwnerRole() = runBlocking {
        ProtocolFixture().use { f ->
            val originalLease = f.lease
            val userJson = buildJsonObject {
                put("id", f.userId); put("tenant_id", f.tenantId); put("display_name", "Limited owner")
                put("account_type", "human"); put("status", "active"); put("role", "owner")
            }
            val missingScope = WireJson.decodeFromString<User>(userJson.toString())
            for (user in listOf(missingScope, missingScope.copy(accessScope = "future_scope"))) {
                f.respond(Me(user, f.authentication.device, f.authentication.tenant))
                f.api.me(originalLease); assertEquals("/api/v1/me", f.request().path)
                try { f.api.directory(lease = originalLease); fail("Unknown scope granted Directory") }
                catch (_: WorkspaceAccessUnavailable) { }
                assertEquals(originalLease, f.lease); assertFalse(f.sessions.identity.value!!.authentication.user.workspaceEligible)
            }
            assertEquals(2, f.server.requestCount)
        }
    }
    @Test fun lateWorkspaceProjectionCannotSurviveWithdrawalAndRegrantOfTheSameLogin() = runBlocking {
        ProtocolFixture().use { f ->
            val arrived = CountDownLatch(1); val release = CountDownLatch(1)
            f.server.dispatcher = object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    arrived.countDown(); release.await(5, TimeUnit.SECONDS)
                    return MockResponse().setHeader("Content-Type", "application/json").setBody(
                        WireJson.encodeToString(DirectoryPage(listOf(DirectoryPerson(f.userId, "Old workspace projection")), CursorPage())))
                }
            }
            try {
                val lease = f.lease
                val delayed = async(Dispatchers.IO) { runCatching { f.api.directory(lease = lease) } }
                assertTrue(withContext(Dispatchers.IO) { arrived.await(5, TimeUnit.SECONDS) })
                f.sessions.updateOwnerMetadata(Me(f.authentication.user.copy(accessScope = "conversation_only"),
                    f.authentication.device, f.authentication.tenant), lease)
                f.sessions.updateOwnerMetadata(Me(f.authentication.user.copy(role = "admin"),
                    f.authentication.device, f.authentication.tenant), lease)
                release.countDown()
                assertTrue(delayed.await().exceptionOrNull() is WorkspaceAccessUnavailable)
                f.sessions.requireWorkspace(lease); assertEquals(lease, f.lease)
            } finally { release.countDown() }
        }
    }
    @Test fun ongoingCallAuthorityUsesTheCurrentOwnerParticipantProjection() = runBlocking {
        ProtocolFixture().use { f ->
            f.respond(CallParticipants(listOf(CallParticipant(f.receiptId, f.userId, "admitted"))))
            assertEquals(f.userId, f.api.participants(f.conversationId, f.callId, f.lease).single().userId)
            val request = f.request()
            assertEquals("GET", request.method)
            assertEquals("/api/v1/conversations/${f.conversationId}/calls/${f.callId}/participants", request.path)
            assertEquals("Bearer ${f.authentication.accessToken}", request.getHeader("Authorization"))
        }
    }
    @Test fun mfaCompletesThroughTheCurrentAuthRouteWithoutBearerCredentials() = runBlocking {
        ProtocolFixture().use { f ->
            f.respond(MfaChallenge(true, "challenge-token".repeat(3), 120))
            val (epoch, result) = f.api.signIn(f.endpoint, " tenant ", " member@example.test ", "password")
            assertTrue(result is SignInResult.Challenge)
            assertNull(f.sessions.identity.value)
            val signIn = f.request()
            assertEquals("/api/v1/sessions", signIn.path)
            assertEquals("tenant", signIn.json()["tenant_slug"]?.jsonPrimitive?.content)
            f.respond(f.authentication)
            f.api.completeMfa(f.endpoint, epoch, (result as SignInResult.Challenge).challenge.token, " 123456 ")
            val request = f.request()
            assertEquals("POST", request.method)
            assertEquals("/api/v1/auth/mfa", request.path)
            assertNull(request.getHeader("Authorization"))
            assertEquals("123456", request.json()["code"]?.jsonPrimitive?.content)
            assertEquals(f.authentication.user.id, f.sessions.capture().userId)
        }
    }

    @Test fun latestHistoryUsesBothAscendingBoundsAndLabelsAreAuthorizedByMessageIds() = runBlocking {
        ProtocolFixture().use { f ->
            f.respond(MessagePage(emptyList(), MessagePaging(false)))
            f.api.latestHistory(Conversation(f.conversationId, f.tenantId, "group", latestSequence = 1000), lease = f.lease)
            val history = f.request().requestUrl!!
            assertEquals("/api/v1/conversations/${f.conversationId}/messages", history.encodedPath)
            assertEquals("900", history.queryParameter("after_sequence"))
            assertEquals("1001", history.queryParameter("before_sequence"))
            assertEquals("100", history.queryParameter("limit"))
            assertEquals("sender_labels", history.queryParameter("include"))
            f.respond(SenderLabelsResult(listOf(SenderLabel(f.userId, "Member", false))))
            val labels = f.api.senderLabels(f.conversationId, listOf(f.messageId), f.lease)
            assertEquals(f.userId, labels.single().id)
            val request = f.request()
            assertEquals("POST", request.method)
            assertEquals("/api/v1/conversations/${f.conversationId}/message-sender-labels", request.path)
            assertEquals(listOf(f.messageId), request.json()["message_ids"]?.jsonArray?.map { it.jsonPrimitive.content })
            assertThrows(IllegalArgumentException::class.java) {
                runBlocking { f.api.senderLabels(f.conversationId, listOf(f.messageId, f.messageId), f.lease) }
            }
            assertEquals(2, f.server.requestCount)
        }
    }

    @Test fun editAndDeleteDecodeTheCurrentRevisionAndScopeFailuresRemainVisible() = runBlocking {
        ProtocolFixture().use { f ->
            val message = f.message().copy(body = "revised", editedAt = "2026-01-01T00:01:00Z")
            f.respond(MessageResult(message))
            assertEquals("revised", f.api.edit(f.messageId, "revised", f.lease).body)
            val edit = f.request()
            assertEquals("PATCH", edit.method)
            assertEquals("/api/v1/messages/${f.messageId}", edit.path)
            assertEquals("revised", edit.json()["body"]?.jsonPrimitive?.content)
            f.respond(MessageResult(message.copy(body = null, status = "deleted", deletedAt = "2026-01-01T00:02:00Z")))
            assertTrue(f.api.delete(f.messageId, f.lease).deleted)
            assertEquals("DELETE", f.request().method)
            f.server.enqueue(MockResponse().setResponseCode(403).setHeader("Content-Type", "application/json")
                .setBody("""{"error":{"code":"forbidden"}}"""))
            val failure = assertThrows(ApiFailure::class.java) {
                runBlocking { f.api.history(f.conversationId, lease = f.lease) }
            }
            assertEquals(403, failure.status)
            assertEquals("forbidden", failure.code)
            assertEquals(f.lease, f.sessions.capture())
        }
    }

    @Test fun meetingWindowsAndVersionConflictsUseTheBackendContract() = runBlocking {
        ProtocolFixture().use { f ->
            f.respond(MeetingList(emptyList()))
            f.api.meetings("2026-01-01T00:00:00Z", "2026-01-08T00:00:00Z", f.lease)
            val window = f.request().requestUrl!!
            assertEquals("2026-01-01T00:00:00Z", window.queryParameter("from"))
            assertEquals("2026-01-08T00:00:00Z", window.queryParameter("to"))
            val meeting = f.meeting()
            f.respond(MeetingResult(meeting.copy(status = "cancelled", version = 8)))
            assertEquals("cancelled", f.api.cancelMeeting(meeting, f.lease).status)
            val cancellation = f.request()
            assertEquals("/api/v1/meetings/${meeting.id}/cancel", cancellation.path)
            assertEquals(7L, cancellation.json()["expected_version"]?.jsonPrimitive?.long)
            assertFalse(cancellation.json().containsKey("version"))
            f.server.enqueue(MockResponse().setResponseCode(409).setHeader("Content-Type", "application/json")
                .setBody("""{"error":{"code":"stale_version"}}"""))
            assertEquals(409, assertThrows(ApiFailure::class.java) {
                runBlocking { f.api.cancelMeeting(meeting, f.lease) }
            }.status)
            assertEquals(3, f.server.requestCount)
        }
    }

    @Test fun callHistoryAndTelephoneAdmissionsUseSeparateCurrentRoutes() = runBlocking {
        ProtocolFixture().use { f ->
            f.respond(CallList(emptyList(), CallPaging(30, false)))
            f.api.calls("opaque/cursor", f.lease)
            val calls = f.request().requestUrl!!
            assertEquals("/api/v1/calls", calls.encodedPath)
            assertEquals("recent", calls.queryParameter("scope"))
            assertEquals("opaque/cursor", calls.queryParameter("cursor"))
            f.respond(PhoneConfigurationResult(PhoneConfiguration(true, false, "livekit_sip", canManage = false)))
            assertFalse(f.api.phoneConfiguration(f.lease).canCall)
            assertEquals("/api/v1/telephony/config", f.request().path)
            f.respond(PhoneCapabilitiesResult(PhoneCapabilities(dtmf = PhoneCapability(false, "provider_unavailable"))))
            assertFalse(f.api.phoneCapabilities(f.lease).dtmf!!.supported)
            assertEquals("/api/v1/telephony/capabilities", f.request().path)
            f.respond(PhoneCallsPage(listOf(f.phoneCall()), CallPaging(30, true, "next")))
            assertEquals("next", f.api.phoneCalls("phone-cursor", f.lease).page.nextCursor)
            assertEquals("phone-cursor", f.request().requestUrl!!.queryParameter("cursor"))
            val session = PhoneSession(f.phoneCall(), f.credential())
            f.respond(session)
            assertEquals(f.callId, f.api.dialPhone("+12025550123", f.commandId, f.lease).data.id)
            val dial = f.request()
            assertEquals("POST", dial.method)
            assertEquals("/api/v1/telephony/calls", dial.path)
            assertEquals(f.commandId, dial.json()["idempotency_key"]?.jsonPrimitive?.content)
            assertEquals("+12025550123", dial.json()["destination"]?.jsonPrimitive?.content)
            for (action in listOf("answer", "join")) {
                f.respond(session)
                if (action == "answer") f.api.answerPhone(f.callId, f.lease) else f.api.joinPhone(f.callId, f.lease)
                assertEquals("/api/v1/telephony/calls/${f.callId}/$action", f.request().path)
            }
            for (action in listOf("reject", "end")) {
                f.respond(PhoneCallResult(f.phoneCall().copy(status = "ended")))
                if (action == "reject") f.api.rejectPhone(f.callId, f.lease) else f.api.endPhone(f.callId, f.lease)
                assertEquals("/api/v1/telephony/calls/${f.callId}/$action", f.request().path)
            }
        }
    }

    @Test fun dtmfDispatchIsSingleUseAndCompletionUsesReceiptIdRatherThanIdempotencyKey() = runBlocking {
        ProtocolFixture().use { f ->
            val receipt = PhoneControlReceipt(f.receiptId, f.callId, "dtmf", "dispatching", true,
                Instant.now().toString(), Instant.now().plusSeconds(60).toString())
            f.respond(PhoneControlResult(receipt))
            assertTrue(f.api.phoneControl(f.callId, "#", f.commandId, f.lease).dispatch)
            val first = f.request()
            assertEquals("/api/v1/telephony/calls/${f.callId}/controls", first.path)
            assertEquals("dtmf", first.json()["action"]?.jsonPrimitive?.content)
            assertEquals("#", first.json()["digit"]?.jsonPrimitive?.content)
            assertEquals(f.commandId, first.json()["idempotency_key"]?.jsonPrimitive?.content)
            f.respond(PhoneControlResult(receipt.copy(dispatch = false)))
            assertFalse(f.api.phoneControl(f.callId, "#", f.commandId, f.lease).dispatch)
            assertEquals(first.json(), f.request().json())
            f.respond(PhoneControlResult(receipt.copy(dispatch = false, status = "unknown", failureReason = "sdk_outcome_unknown")))
            assertEquals("unknown", f.api.completePhoneControl(f.callId, f.receiptId, "unknown", f.lease).status)
            val complete = f.request()
            assertEquals("/api/v1/telephony/calls/${f.callId}/controls/${f.receiptId}/complete", complete.path)
            assertEquals("unknown", complete.json()["status"]?.jsonPrimitive?.content)
            f.respond(PhoneControlResult(receipt.copy(dispatch = false, status = "unknown")))
            assertFalse(f.api.reconcilePhoneControl(f.callId, f.receiptId, f.lease).dispatch)
            assertEquals("/api/v1/telephony/calls/${f.callId}/controls/${f.receiptId}/reconcile", f.request().path)
            assertThrows(IllegalArgumentException::class.java) {
                runBlocking { f.api.phoneControl(f.callId, "12", f.commandId, f.lease) }
            }
            assertEquals(4, f.server.requestCount)
        }
    }
}

private class MemoryVault : CredentialVault {
    private var state = StoredState()
    override suspend fun load() = state
    override suspend fun save(state: StoredState) { this.state = state }
    override suspend fun clear() { state = StoredState() }
}

private class ProtocolFixture : Closeable {
    val tenantId = "00000000-0000-4000-8000-000000000001"
    val userId = "00000000-0000-4000-8000-000000000002"
    val deviceId = "00000000-0000-4000-8000-000000000003"
    val conversationId = "00000000-0000-4000-8000-000000000004"
    val messageId = "00000000-0000-4000-8000-000000000005"
    val callId = "00000000-0000-4000-8000-000000000006"
    val commandId = "00000000-0000-4000-8000-000000000007"
    val receiptId = "00000000-0000-4000-8000-000000000008"
    val authentication = Authentication("access-token".repeat(3), "refresh-token".repeat(3), 3600,
        Tenant(tenantId, "tenant", "Tenant"), User(userId, tenantId, "Member", "human", accessScope = "workspace", status = "active"), Device(deviceId, userId))
    val server = MockWebServer()
    private val certificate = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
    private val serverCertificates = HandshakeCertificates.Builder().heldCertificate(certificate).build()
    private val clientCertificates = HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
    val endpoint: Endpoint
    val sessions: SessionStore
    val api: KCommsApi
    val lease get() = sessions.capture()
    init {
        server.useHttps(serverCertificates.sslSocketFactory(), false)
        server.start()
        endpoint = Endpoint.parse(server.url("/").toString())
        val transport = HttpTransport(HttpTransport.secureClient().newBuilder()
            .sslSocketFactory(clientCertificates.sslSocketFactory(), clientCertificates.trustManager).build())
        sessions = SessionStore(MemoryVault(), transport) { System.nanoTime() / 1_000_000 }
        runBlocking { sessions.install(endpoint, authentication, sessions.resetForSignIn()) }
        api = KCommsApi(sessions)
    }
    inline fun <reified T> respond(value: T) {
        server.enqueue(MockResponse().setHeader("Content-Type", "application/json").setBody(WireJson.encodeToString(value)))
    }
    fun request(): RecordedRequest = checkNotNull(server.takeRequest(2, TimeUnit.SECONDS))
    fun message() = Message(messageId, tenantId, conversationId, userId, commandId, 1,
        body = "message", status = "accepted", insertedAt = "2026-01-01T00:00:00Z")
    fun meeting() = Meeting(commandId, conversationId, userId, "Meeting", "UTC", "2026-01-01T10:00:00", 30, 10,
        "scheduled", 7, listOf(MeetingOccurrence(receiptId, 1, "2026-01-01T10:00:00Z", "2026-01-01T10:30:00Z", "scheduled")), true)
    fun credential() = MediaCredential("wss://media.example.test", "participant-token".repeat(3), 60)
    fun phoneCall() = PhoneCall(callId, "outbound", "answered", "+12025550000", "+12025550123", "1234",
        "2026-01-01T00:00:00Z", 42, false, true, true, true)
    override fun close() { sessions.transport.client.dispatcher.cancelAll(); server.shutdown() }
}

private fun RecordedRequest.json(): JsonObject = WireJson.parseToJsonElement(body.clone().readUtf8()).jsonObject
