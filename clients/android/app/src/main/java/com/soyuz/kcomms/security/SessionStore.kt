package com.soyuz.kcomms.security

import com.soyuz.kcomms.protocol.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import java.util.UUID
import java.util.concurrent.atomic.AtomicLong

data class IdentityLease(val epoch: Long, val origin: String, val tenantId: String,
                         val userId: String, val deviceId: String, val lineage: String)
data class SessionIdentity(val lease: IdentityLease, val authentication: Authentication, val workspaceGeneration: Long = 0)

/** Every asynchronous result/command is bound to one account/device lineage. */
class SessionStore(private val vault: CredentialVault, val transport: HttpTransport,
                   nowMillis: () -> Long = { android.os.SystemClock.elapsedRealtime() }) {
    private val mutex = Mutex()
    private val counter = AtomicLong(0)
    private val workspaceCounter = AtomicLong(0)
    private var stored = StoredState()
    private val mutableIdentity = MutableStateFlow<SessionIdentity?>(null)
    val identity = mutableIdentity.asStateFlow()
    private val deadline = SessionDeadline(nowMillis)
    fun remainingAccessMillis(): Long = if (identity.value == null) 0 else deadline.remainingMillis()

    fun capture(): IdentityLease = identity.value?.lease ?: throw IdentityChanged()
    fun isCurrent(lease: IdentityLease) = identity.value?.lease == lease
    fun requireCurrent(lease: IdentityLease) { if (!isCurrent(lease)) throw IdentityChanged() }

    fun captureWorkspace(lease: IdentityLease): Long {
        val current = identity.value ?: throw IdentityChanged()
        if (current.lease != lease) throw IdentityChanged()
        if (!current.authentication.user.workspaceEligible) throw WorkspaceAccessUnavailable()
        return current.workspaceGeneration
    }
    fun requireWorkspace(lease: IdentityLease, generation: Long? = null) {
        val current = identity.value ?: throw IdentityChanged()
        if (current.lease != lease) throw IdentityChanged()
        if (!current.authentication.user.workspaceEligible ||
            generation != null && generation != current.workspaceGeneration) throw WorkspaceAccessUnavailable()
    }
    private fun publishIdentity(session: StoredSession) {
        if (identity.value?.authentication?.user?.workspaceEligible != session.authentication.user.workspaceEligible)
            workspaceCounter.incrementAndGet()
        mutableIdentity.value = identityFor(session)
    }

    private fun identityFor(session: StoredSession) = SessionIdentity(
        IdentityLease(counter.get(), session.origin, session.authentication.tenant.id,
            session.authentication.user.id, session.authentication.device.id, session.lineage), session.authentication,
        workspaceCounter.get())

    suspend fun resetForSignIn(): Long {
        val epoch = counter.incrementAndGet(); mutableIdentity.value = null; deadline.clear(); transport.cancelInFlight()
        return mutex.withLock {
            requireSignInEpoch(epoch); stored = StoredState(); vault.clear(); epoch
        }
    }
    fun requireSignInEpoch(epoch: Long) { if (counter.get() != epoch) throw IdentityChanged() }

    suspend fun install(endpoint: Endpoint, authentication: Authentication, signInEpoch: Long) = mutex.withLock {
        requireSignInEpoch(signInEpoch); authentication.validate()
        val session = StoredSession(endpoint.canonical, UUID.randomUUID().toString(), authentication)
        stored = StoredState(session)
        vault.save(stored)
        requireSignInEpoch(signInEpoch); deadline.install(authentication.expiresIn); publishIdentity(session)
    }

    suspend fun restore(): Boolean = mutex.withLock {
        if (mutableIdentity.value != null) return@withLock true
        val restoreEpoch = counter.get()
        var restoreWriteEpoch = restoreEpoch
        val restored = vault.load(); val session = restored.session ?: return@withLock false
        try {
            val endpoint = Endpoint.parse(session.origin)
            session.authentication.validate()
            val body = transport.request(endpoint, "POST", "/sessions/refresh", buildJsonObject {
                put("refresh_token", session.authentication.refreshToken)
            })
            val refreshed = WireJson.decodeFromString<Authentication>(body).also { it.validate() }
            requireSignInEpoch(restoreEpoch)
            sameIdentity(session.authentication, refreshed)
            val restoredEpoch = counter.incrementAndGet()
            restoreWriteEpoch = restoredEpoch
            val replacement = session.copy(authentication = refreshed)
            stored = restored.copy(session = replacement, outbox = restored.outbox.filter { it.belongsTo(replacement) })
            vault.save(stored); requireSignInEpoch(restoredEpoch); deadline.install(refreshed.expiresIn); publishIdentity(replacement)
            true
        } catch (_: Exception) {
            if (counter.get() == restoreWriteEpoch) { stored = StoredState(); vault.clear(); deadline.clear(); mutableIdentity.value = null }
            false
        }
    }

    private fun sameIdentity(expected: Authentication, actual: Authentication) {
        if (expected.tenant.id != actual.tenant.id || expected.user.id != actual.user.id ||
            expected.device.id != actual.device.id) throw IdentityChanged()
    }

    /** Current owner metadata can change without replacing this login's identity or outbox. */
    suspend fun updateOwnerMetadata(me: Me, lease: IdentityLease) = mutex.withLock {
        requireCurrent(lease)
        val session = stored.session ?: throw IdentityChanged()
        val authentication = session.authentication.copy(tenant = me.tenant, user = me.user, device = me.device)
        sameIdentity(session.authentication, authentication)
        if (me.user.tenantId != lease.tenantId || me.device.userId != lease.userId ||
            me.user.accountType != "human" || me.user.status != "active") throw IdentityChanged()
        authentication.validate()
        // Concurrent UI/media /me reads must not restore older owner facts after withdrawal.
        if (me.user.version < session.authentication.user.version) throw ProtocolFailure()
        if (authentication == session.authentication) return@withLock
        val replacement = session.copy(authentication = authentication)
        // A failed encrypted metadata save must not retain withdrawn workspace access in memory.
        stored = stored.copy(session = replacement)
        publishIdentity(replacement)
        vault.save(stored)
        requireCurrent(lease)
        // /me changes no token TTL. Only refresh can install a new access deadline.
    }

    /** Mutex serializes refresh, persisted outbox and identity replacement. */
    private suspend fun refresh(lease: IdentityLease, rejectedToken: String): Authentication = mutex.withLock {
        requireCurrent(lease)
        val session = stored.session ?: throw IdentityChanged()
        if (session.authentication.accessToken != rejectedToken) return@withLock session.authentication
        try {
            val text = transport.request(Endpoint.parse(session.origin), "POST", "/sessions/refresh", buildJsonObject {
                put("refresh_token", session.authentication.refreshToken)
            })
            requireCurrent(lease)
            val next = WireJson.decodeFromString<Authentication>(text).also { it.validate() }
            sameIdentity(session.authentication, next)
            val replacement = session.copy(authentication = next)
            stored = stored.copy(session = replacement); vault.save(stored)
            requireCurrent(lease); deadline.install(next.expiresIn); publishIdentity(replacement)
            next
        } catch (failure: Exception) {
            if (isCurrent(lease) && (failure is ApiFailure && failure.status in listOf(400, 401, 403) ||
                    failure is IdentityChanged || failure is IllegalArgumentException || failure is ProtocolFailure)) {
                counter.incrementAndGet(); mutableIdentity.value = null; deadline.clear(); stored = StoredState(); vault.clear()
                transport.cancelInFlight()
            }
            throw failure
        }
    }

    /** Refresh before admission and after resume; a failed refresh grants no extra time. */
    suspend fun ensureFresh(lease: IdentityLease = capture()): Authentication {
        requireCurrent(lease)
        val current = identity.value?.authentication ?: throw IdentityChanged()
        return if (remainingAccessMillis() <= 60_000) refresh(lease, current.accessToken) else current
    }

    suspend fun expireIfNecessary() { if (identity.value != null && remainingAccessMillis() == 0L) invalidate() }

    suspend fun authorized(method: String, path: String, body: kotlinx.serialization.json.JsonObject? = null,
                           idempotencyKey: String? = null, query: Map<String, String> = emptyMap(),
                           lease: IdentityLease = capture()): String {
        requireCurrent(lease)
        val current = ensureFresh(lease)
        val endpoint = Endpoint.parse(lease.origin)
        val text = try {
            transport.request(endpoint, method, path, body, current.accessToken, idempotencyKey, query)
        } catch (failure: ApiFailure) {
            if (failure.status != 401) throw failure
            val next = refresh(lease, current.accessToken)
            requireCurrent(lease)
            try {
                transport.request(endpoint, method, path, body, next.accessToken, idempotencyKey, query)
            } catch (secondFailure: ApiFailure) {
                if (secondFailure.status == 401 && isCurrent(lease)) invalidate()
                throw secondFailure
            }
        }
        requireCurrent(lease)
        return text
    }

    suspend fun invalidate() {
        val epoch = counter.incrementAndGet(); mutableIdentity.value = null; deadline.clear(); transport.cancelInFlight()
        mutex.withLock { if (counter.get() == epoch) { stored = StoredState(); vault.clear() } }
    }
    suspend fun logout() {
        val old = identity.value
        invalidate()
        // UI/media invalidation precedes network; an unavailable server cannot retain local login.
        if (old != null) try {
            transport.request(Endpoint.parse(old.lease.origin), "DELETE", "/sessions/current", token = old.authentication.accessToken)
        } catch (_: Exception) { /* Server expiry/revocation remains authoritative. */ }
    }

    suspend fun enqueue(conversationId: String, body: String, lease: IdentityLease): PendingMessage = mutex.withLock {
        requireCurrent(lease)
        require(body.isNotBlank() && body.toByteArray().size <= 16000)
        val session = stored.session ?: throw IdentityChanged()
        require(stored.outbox.size < 100) { "Retry or discard pending messages before sending more." }
        val command = PendingMessage(UUID.randomUUID().toString(), lease.origin, lease.tenantId,
            lease.userId, lease.deviceId, lease.lineage, conversationId, body)
        val next = stored.copy(outbox = stored.outbox + command)
        vault.save(next); requireCurrent(lease); stored = next
        command
    }
    suspend fun pending(lease: IdentityLease): List<PendingMessage> = mutex.withLock {
        requireCurrent(lease); stored.outbox.filter { it.belongsTo(stored.session ?: throw IdentityChanged()) }
    }
    suspend fun acknowledge(command: PendingMessage, lease: IdentityLease) = mutex.withLock {
        requireCurrent(lease)
        val original = stored.outbox.find { it.commandId == command.commandId }
        require(original == command && command.belongsTo(stored.session ?: throw IdentityChanged()))
        val next = stored.copy(outbox = stored.outbox.filterNot { it.commandId == command.commandId })
        vault.save(next); requireCurrent(lease); stored = next
    }
    suspend fun discard(command: PendingMessage, lease: IdentityLease) = acknowledge(command, lease)
}
