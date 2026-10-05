package com.soyuz.kcomms.security

import com.soyuz.kcomms.protocol.*
import kotlinx.coroutines.*
import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.RecordedRequest
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.Assert.*
import org.junit.Test
import java.util.concurrent.TimeUnit
import java.util.concurrent.CountDownLatch
import java.io.IOException

class SessionStoreTest {
    private class MemoryVault : CredentialVault {
        var value = StoredState()
        var clears = 0
        var failSave = false
        override suspend fun load() = value
        override suspend fun save(state: StoredState) {
            if (failSave) throw IOException("Synthetic encrypted-storage failure")
            value = state
        }
        override suspend fun clear() { clears++; value = StoredState() }
    }
    private fun authentication(userId: String = USER, deviceId: String = DEVICE, access: String = "synthetic-access-token-123456") =
        Authentication(access, "synthetic-refresh-token-123456", 3600,
            Tenant(TENANT, "example", "Example"), User(userId, TENANT, "Member", "human", accessScope = "workspace", status = "active"), Device(deviceId, userId))

    @Test fun oldLeaseAndQueuedContentCannotCrossAReplacementLogin() = runTest {
        val vault = MemoryVault(); val sessions = SessionStore(vault, HttpTransport()) { 1000L }
        val endpoint = Endpoint.parse("https://example.test")
        val epoch = sessions.resetForSignIn(); sessions.install(endpoint, authentication(), epoch)
        val old = sessions.capture(); val command = sessions.enqueue(CONVERSATION, "private pending body", old)
        assertEquals(listOf(command), sessions.pending(old))
        val nextEpoch = sessions.resetForSignIn()
        sessions.install(endpoint, authentication(OTHER_USER, OTHER_DEVICE), nextEpoch)
        val replacement = sessions.capture()
        assertNotEquals(old, replacement)
        assertTrue(sessions.pending(replacement).isEmpty())
        assertThrows(IdentityChanged::class.java) { sessions.requireCurrent(old) }
        try { sessions.acknowledge(command, replacement); fail("Old message must not match replacement outbox") }
        catch (_: IllegalArgumentException) { }
        assertTrue(vault.value.outbox.isEmpty())
    }
    @Test fun rejectedSignInEpochCannotInstallCredentialsFromAnEarlierAttempt() = runTest {
        val vault = MemoryVault(); val sessions = SessionStore(vault, HttpTransport()) { 1000L }
        val oldEpoch = sessions.resetForSignIn(); val currentEpoch = sessions.resetForSignIn()
        try { sessions.install(Endpoint.parse("https://example.test"), authentication(), oldEpoch); fail("Stale login accepted") }
        catch (_: IdentityChanged) { }
        assertNull(sessions.identity.value); assertNull(vault.value.session)
        sessions.install(Endpoint.parse("https://example.test"), authentication(), currentEpoch)
        assertEquals(USER, sessions.capture().userId)
    }
    @Test fun exactExpiryClearsCredentialsOutboxAndInMemoryAuthority() = runTest {
        var elapsed = 10L
        val vault = MemoryVault(); val sessions = SessionStore(vault, HttpTransport()) { elapsed }
        val epoch = sessions.resetForSignIn()
        sessions.install(Endpoint.parse("https://example.test"), authentication().copy(expiresIn = 90), epoch)
        sessions.enqueue(CONVERSATION, "pending", sessions.capture())
        elapsed += 90_000
        sessions.expireIfNecessary()
        assertNull(sessions.identity.value); assertNull(vault.value.session); assertTrue(vault.value.outbox.isEmpty())
    }
    @Test fun ownerRoleAndScopeChangesPreserveLoginOutboxAndAccessDeadline() = runTest {
        var elapsed = 1000L
        val vault = MemoryVault(); val sessions = SessionStore(vault, HttpTransport()) { elapsed }
        val original = authentication()
        sessions.install(Endpoint.parse("https://example.test"), original, sessions.resetForSignIn())
        val lease = sessions.capture(); val generation = sessions.captureWorkspace(lease)
        val pending = sessions.enqueue(CONVERSATION, "same immutable pending body", lease)
        elapsed += 5000
        val remaining = sessions.remainingAccessMillis()
        val limited = original.user.copy(accessScope = "conversation_only", role = "owner", displayName = "Current name")
        sessions.updateOwnerMetadata(Me(limited, original.device, original.tenant), lease)
        assertEquals(lease, sessions.capture()); assertEquals(limited, sessions.identity.value?.authentication?.user)
        assertEquals(listOf(pending), sessions.pending(lease)); assertEquals(remaining, sessions.remainingAccessMillis())
        assertEquals(original.accessToken, sessions.identity.value?.authentication?.accessToken)
        assertEquals(limited, vault.value.session?.authentication?.user)
        assertThrows(WorkspaceAccessUnavailable::class.java) { sessions.requireWorkspace(lease, generation) }
        val promoted = limited.copy(accessScope = "workspace", role = "moderator")
        sessions.updateOwnerMetadata(Me(promoted, original.device, original.tenant), lease)
        sessions.requireWorkspace(lease)
        assertEquals(lease, sessions.capture()); assertEquals(listOf(pending), sessions.pending(lease))
        assertThrows(WorkspaceAccessUnavailable::class.java) { sessions.requireWorkspace(lease, generation) }
        val currentGeneration = sessions.captureWorkspace(lease)
        sessions.updateOwnerMetadata(Me(promoted.copy(role = "member"), original.device, original.tenant), lease)
        sessions.requireWorkspace(lease, currentGeneration)
    }
    @Test fun failedOwnerMetadataPersistenceStillWithdrawsWorkspaceAuthorityInMemory() = runTest {
        val vault = MemoryVault(); val sessions = SessionStore(vault, HttpTransport()) { 1000L }
        val original = authentication()
        sessions.install(Endpoint.parse("https://example.test"), original, sessions.resetForSignIn())
        val lease = sessions.capture(); val pending = sessions.enqueue(CONVERSATION, "pending", lease)
        vault.failSave = true
        try {
            sessions.updateOwnerMetadata(Me(original.user.copy(accessScope = "conversation_only"), original.device, original.tenant), lease)
            fail("Synthetic vault failure was ignored")
        } catch (_: IOException) { }
        assertEquals(lease, sessions.capture()); assertEquals(listOf(pending), sessions.pending(lease))
        assertThrows(WorkspaceAccessUnavailable::class.java) { sessions.requireWorkspace(lease) }
    }
    @Test fun anOlderOwnerProjectionCannotRestoreWithdrawnWorkspaceAuthority() = runTest {
        val vault = MemoryVault(); val sessions = SessionStore(vault, HttpTransport()) { 1000L }
        val original = authentication().copy(user = authentication().user.copy(version = 10))
        sessions.install(Endpoint.parse("https://example.test"), original, sessions.resetForSignIn())
        val lease = sessions.capture()
        val limited = original.user.copy(accessScope = "conversation_only", version = 11)
        sessions.updateOwnerMetadata(Me(limited, original.device, original.tenant), lease)
        try {
            sessions.updateOwnerMetadata(Me(original.user, original.device, original.tenant), lease)
            fail("Old workspace metadata replaced newer owner withdrawal")
        } catch (_: ProtocolFailure) { }
        assertEquals(lease, sessions.capture()); assertEquals(limited, sessions.identity.value?.authentication?.user)
        assertThrows(WorkspaceAccessUnavailable::class.java) { sessions.requireWorkspace(lease) }
    }
    @Test fun failedEncryptedWriteCannotChangeTheIdempotentPendingCommandSnapshot() = runTest {
        val vault = MemoryVault(); val sessions = SessionStore(vault, HttpTransport()) { 1000L }
        val epoch = sessions.resetForSignIn()
        sessions.install(Endpoint.parse("https://example.test"), authentication(), epoch)
        val lease = sessions.capture(); vault.failSave = true
        try { sessions.enqueue(CONVERSATION, "unsaved", lease); fail("Failed ciphertext write accepted") }
        catch (_: IOException) { }
        assertTrue(sessions.pending(lease).isEmpty()); assertTrue(vault.value.outbox.isEmpty())
        vault.failSave = false
        val original = sessions.enqueue(CONVERSATION, "original immutable body", lease)
        vault.failSave = true
        try { sessions.acknowledge(original, lease); fail("Failed acknowledgement removed pending command") }
        catch (_: IOException) { }
        try { sessions.discard(original, lease); fail("Failed discard removed pending command") }
        catch (_: IOException) { }
        assertEquals(listOf(original), sessions.pending(lease)); assertEquals(listOf(original), vault.value.outbox)
        vault.failSave = false; sessions.acknowledge(original, lease)
        assertTrue(sessions.pending(lease).isEmpty()); assertTrue(vault.value.outbox.isEmpty())
    }
    @Test fun refreshMayRotateTokensOnlyForTheSameTenantUserAndDevice() = runTest {
        val server = MockWebServer()
        val certificate = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val serverTls = HandshakeCertificates.Builder().heldCertificate(certificate).build()
        val clientTls = HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        server.useHttps(serverTls.sslSocketFactory(), false); server.start()
        try {
            val transport = HttpTransport(HttpTransport.secureClient().newBuilder()
                .sslSocketFactory(clientTls.sslSocketFactory(), clientTls.trustManager).build())
            val vault = MemoryVault()
            val original = authentication()
            val endpoint = Endpoint.parse(server.url("/").toString())
            vault.value = StoredState(StoredSession(endpoint.canonical, "synthetic-lineage", original))
            server.enqueue(MockResponse().setHeader("Content-Type", "application/json")
                .setBody(WireJson.encodeToString(Authentication.serializer(), authentication(deviceId = OTHER_DEVICE))))
            val sessions = SessionStore(vault, transport) { 1000L }
            assertFalse(sessions.restore())
            assertNull(sessions.identity.value); assertNull(vault.value.session)
            val request = withContext(Dispatchers.IO) { server.takeRequest(5, TimeUnit.SECONDS) }!!
            assertEquals("/api/v1/sessions/refresh", request.path)
            assertEquals("POST", request.method)
            assertFalse(request.headers.names().contains("Authorization"))
        } finally { server.shutdown() }
    }
    @Test fun refreshCanChangeScopeAndRoleWithoutReplacingIdentityOrQueuedMessages() = runTest {
        val server = MockWebServer()
        val certificate = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val serverTls = HandshakeCertificates.Builder().heldCertificate(certificate).build()
        val clientTls = HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        server.useHttps(serverTls.sslSocketFactory(), false); server.start()
        try {
            var elapsed = 1000L
            val transport = HttpTransport(HttpTransport.secureClient().newBuilder()
                .sslSocketFactory(clientTls.sslSocketFactory(), clientTls.trustManager).build())
            val vault = MemoryVault(); val sessions = SessionStore(vault, transport) { elapsed }
            val original = authentication().copy(expiresIn = 90)
            sessions.install(Endpoint.parse(server.url("/").toString()), original, sessions.resetForSignIn())
            val lease = sessions.capture(); val pending = sessions.enqueue(CONVERSATION, "retry body", lease)
            val refreshed = authentication(access = "synthetic-rotated-access-token").copy(
                user = original.user.copy(accessScope = "conversation_only", role = "admin"))
            server.enqueue(MockResponse().setHeader("Content-Type", "application/json")
                .setBody(WireJson.encodeToString(Authentication.serializer(), refreshed)))
            elapsed += 31_000
            assertEquals(refreshed, sessions.ensureFresh(lease))
            assertEquals(lease, sessions.capture()); assertEquals(listOf(pending), sessions.pending(lease))
            assertEquals(refreshed.user, vault.value.session?.authentication?.user)
            assertThrows(WorkspaceAccessUnavailable::class.java) { sessions.requireWorkspace(lease) }
            assertEquals("/api/v1/sessions/refresh", withContext(Dispatchers.IO) { server.takeRequest(5, TimeUnit.SECONDS) }!!.path)
        } finally { server.shutdown() }
    }
    @Test fun aDelayedAuthenticatedResponseCannotRestoreContentAfterIdentityReplacement() = runTest {
        val server = MockWebServer()
        val certificate = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val serverTls = HandshakeCertificates.Builder().heldCertificate(certificate).build()
        val clientTls = HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        val arrived = CountDownLatch(1); val release = CountDownLatch(1)
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                arrived.countDown(); release.await(5, TimeUnit.SECONDS)
                return MockResponse().setHeader("Content-Type", "application/json").setBody("{\"private\":\"old account body\"}")
            }
        }
        server.useHttps(serverTls.sslSocketFactory(), false); server.start()
        try {
            val transport = HttpTransport(HttpTransport.secureClient().newBuilder()
                .sslSocketFactory(clientTls.sslSocketFactory(), clientTls.trustManager).build())
            val vault = MemoryVault(); val sessions = SessionStore(vault, transport) { 1000L }
            val endpoint = Endpoint.parse(server.url("/").toString())
            val epoch = sessions.resetForSignIn(); sessions.install(endpoint, authentication(), epoch)
            val oldLease = sessions.capture()
            val delayed = async(Dispatchers.IO) { runCatching { sessions.authorized("GET", "/me", lease = oldLease) } }
            assertTrue(withContext(Dispatchers.IO) { arrived.await(5, TimeUnit.SECONDS) })
            val replacementEpoch = sessions.resetForSignIn()
            sessions.install(endpoint, authentication(OTHER_USER, OTHER_DEVICE), replacementEpoch)
            release.countDown()
            assertTrue(delayed.await().isFailure)
            assertEquals(OTHER_USER, sessions.capture().userId)
            assertEquals(OTHER_DEVICE, vault.value.session?.authentication?.device?.id)
            assertFalse(sessions.isCurrent(oldLease))
        } finally { release.countDown(); server.shutdown() }
    }
    companion object {
        const val TENANT = "11111111-1111-4111-8111-111111111111"
        const val USER = "22222222-2222-4222-8222-222222222222"
        const val DEVICE = "33333333-3333-4333-8333-333333333333"
        const val CONVERSATION = "44444444-4444-4444-8444-444444444444"
        const val OTHER_USER = "55555555-5555-4555-8555-555555555555"
        const val OTHER_DEVICE = "66666666-6666-4666-8666-666666666666"
    }
}
