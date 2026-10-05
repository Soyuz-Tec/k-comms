package com.soyuz.kcomms.push

import com.soyuz.kcomms.protocol.WireJson
import java.time.Instant
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.ExperimentalCoroutinesApi
import org.junit.Assert.*
import org.junit.Test

@OptIn(ExperimentalCoroutinesApi::class)
class NativeWakeTest {
    private val now = Instant.parse("2026-10-05T00:00:00Z")
    private val id = "00000000-0000-4000-8000-000000000101"
    private fun payload(seconds: Long = 25) = mapOf("protocol_version" to "1", "wake_id" to id,
        "expires_at" to now.plusSeconds(seconds).toString(), "kind" to "call")
    @Test fun payloadIsOpaqueAndHasBothDeadlineBounds() {
        val hint = NativeWakeHint.parse(payload(), now, 100_000)
        assertTrue(hint.current(now.plusSeconds(1), 101_000)); assertFalse(hint.current(now.minusSeconds(100), 126_000))
        assertFalse(hint.current(now.plusSeconds(26), 101_000)); assertFalse(hint.current(now, 99_000))
    }
    @Test fun expiredFutureAndUnknownContentsAreRejected() {
        for (value in listOf(payload(-1), payload(0), payload(31), payload() + ("caller" to "Private caller"),
            payload() + ("participant_token" to "not-authority"), payload() + ("wake_id" to "invalid"))) {
            assertTrue(runCatching { NativeWakeHint.parse(value, now, 100_000) }.isFailure)
        }
    }
    @Test fun unsignedBuildCannotBeEnabledByBackendConfiguration() {
        val config = NativePushConfiguration(1, true, listOf(NativePlatform("android", "fcm", "com.synthetic.native", "production", true)), 30, true)
        assertFalse(config.approves("com.synthetic.native", false)); assertTrue(config.approves("com.synthetic.native", true))
        assertFalse(config.approves("com.other.native", true)); assertFalse(config.copy(wakeTtlSeconds = 60).approves("com.synthetic.native", true))
    }
    @Test fun unknownOwnerCannotBeMisdecodedAsAuthentication() {
        assertTrue(runCatching { NativeWakeAdmission.decode("{\"owner\":\"unknown\",\"access_token\":\"not-auth\"}") }.isFailure)
    }
    @Test fun lateOldOwnerTokenFailureCannotDisableNewOwner() = runTest {
        var current = "A"; val oldToken = CompletableDeferred<String>(); val effects = mutableListOf<String>()
        var first = true
        val provider = object : NativeTokenProvider {
            override fun setEnabled(enabled: Boolean) { effects += "enabled:$enabled" }
            override suspend fun token(): String = if (first) { first = false; oldToken.await() } else "fresh-B"
            override suspend fun deleteToken() { effects += "delete" }
        }
        val lifecycle = NativeTokenLifecycle(this, provider, { it: String -> it == current },
            { token, identity -> effects += "register:$identity:$token" }, { effects += "ready:$it" }, { effects += "unavailable:$it" })
        val old = launch { runCatching { lifecycle.enable("A") } }; runCurrent()
        current = "B"; lifecycle.invalidate(); val fresh = launch { lifecycle.enable("B") }; runCurrent()
        oldToken.completeExceptionally(IllegalStateException("Old provider failure")); old.join(); fresh.join()
        assertFalse(effects.contains("unavailable:A")); assertFalse(effects.any { it.startsWith("register:A") })
        assertEquals(listOf("enabled:true", "enabled:false", "delete", "enabled:true", "register:B:fresh-B", "ready:B"), effects)
    }
    @Test fun replacementCannotRegisterUntilSdkDeletionCompletes() = runTest {
        var current = "A"; val deletion = CompletableDeferred<Unit>(); val effects = mutableListOf<String>()
        val provider = object : NativeTokenProvider {
            override fun setEnabled(enabled: Boolean) { effects += "enabled:$enabled" }
            override suspend fun token(): String { effects += "token"; return "new-token" }
            override suspend fun deleteToken() { effects += "delete-start"; deletion.await(); effects += "delete-complete" }
        }
        val lifecycle = NativeTokenLifecycle(this, provider, { it: String -> it == current },
            { _, identity -> effects += "register:$identity" }, { effects += "ready:$it" }, { effects += "unavailable:$it" })
        current = "B"; lifecycle.invalidate(); val replacement = launch { lifecycle.enable("B") }; runCurrent()
        assertFalse(effects.contains("token")); assertFalse(effects.contains("register:B"))
        deletion.complete(Unit); replacement.join()
        assertTrue(effects.indexOf("delete-complete") < effects.indexOf("token")); assertEquals("ready:B", effects.last())
    }
    @Test fun uncertainCleanupDoesNotObtainOrRegisterReplacementToken() = runTest {
        val effects = mutableListOf<String>()
        val provider = object : NativeTokenProvider {
            override fun setEnabled(enabled: Boolean) { effects += "enabled:$enabled" }
            override suspend fun token(): String { effects += "token"; return "forbidden" }
            override suspend fun deleteToken() { throw IllegalStateException("Cleanup unavailable") }
        }
        val lifecycle = NativeTokenLifecycle(this, provider, { _: String -> true },
            { _, _ -> effects += "register" }, { effects += "ready" }, { effects += "unavailable" })
        lifecycle.invalidate(); runCurrent(); assertTrue(runCatching { lifecycle.enable("B") }.isFailure)
        assertFalse(effects.contains("token")); assertFalse(effects.contains("register")); assertFalse(effects.contains("ready"))
    }
    @Test fun hungTokenDoesNotPreventConfirmedCleanupAndNewOwnerRegistration() = runTest {
        var current = "A"; val never = CompletableDeferred<String>(); val effects = mutableListOf<String>(); var first = true
        val provider = object : NativeTokenProvider {
            override fun setEnabled(enabled: Boolean) { effects += "enabled:$enabled" }
            override suspend fun token(): String = if (first) { first = false; never.await() } else "fresh-B"
            override suspend fun deleteToken() { effects += "delete" }
        }
        val lifecycle = NativeTokenLifecycle(this, provider, { it: String -> it == current },
            { _, identity -> effects += "register:$identity" }, { effects += "ready:$it" }, { effects += "unavailable:$it" }, 100)
        val old = launch { runCatching { lifecycle.enable("A") } }; runCurrent()
        current = "B"; lifecycle.invalidate(); val fresh = launch { lifecycle.enable("B") }; runCurrent()
        advanceTimeBy(101); runCurrent(); old.join(); fresh.join()
        assertFalse(effects.contains("unavailable:A")); assertFalse(effects.contains("register:A"))
        assertTrue(effects.indexOf("delete") < effects.indexOf("register:B")); assertEquals("ready:B", effects.last())
    }
    @Test fun hungCleanupRemainsFailClosedWithoutObtainingToken() = runTest {
        val never = CompletableDeferred<Unit>(); val effects = mutableListOf<String>()
        val provider = object : NativeTokenProvider {
            override fun setEnabled(enabled: Boolean) { effects += "enabled:$enabled" }
            override suspend fun token(): String { effects += "token"; return "forbidden" }
            override suspend fun deleteToken() { never.await() }
        }
        val lifecycle = NativeTokenLifecycle(this, provider, { _: String -> true },
            { _, _ -> effects += "register" }, { effects += "ready" }, { effects += "unavailable" }, 100)
        lifecycle.invalidate(); runCurrent()
        val replacement = launch { assertTrue(runCatching { lifecycle.enable("B") }.isFailure) }
        advanceTimeBy(301); runCurrent(); replacement.join()
        assertFalse(effects.contains("token")); assertFalse(effects.contains("register")); assertFalse(effects.contains("ready"))
    }

}
