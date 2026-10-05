package com.soyuz.kcomms.push

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

interface NativeTokenProvider {
    fun setEnabled(enabled: Boolean)
    suspend fun token(): String
    suspend fun deleteToken()
}
/** Serializes SDK deletion, replacement-token acquisition and backend registration.
 * Local invalidation is immediate; a late prior-owner failure cannot disable the
 * newer owner, and uncertain cleanup never permits reuse of an old provider token. */
class NativeTokenLifecycle<I>(private val scope: CoroutineScope, private val provider: NativeTokenProvider,
    private val current: (I) -> Boolean, private val register: suspend (String, I) -> Unit,
    private val ready: (I) -> Unit, private val unavailable: (I) -> Unit,
    private val providerTimeoutMillis: Long = 10_000) {
    private val mutex = Mutex()
    private val epoch = AtomicLong()
    private val cleanupRequired = AtomicBoolean(false)
    fun invalidate() {
        epoch.incrementAndGet(); cleanupRequired.set(true)
        scope.launch { mutex.withLock { cleanup() } }
    }
    suspend fun enable(identity: I) {
        val expected = epoch.get()
        mutex.withLock {
            try {
                requireCurrent(identity, expected)
                check(cleanup()) { "Provider cleanup is unconfirmed" }
                requireCurrent(identity, expected); provider.setEnabled(true)
                val token = withTimeout(providerTimeoutMillis) { provider.token() }; requireCurrent(identity, expected)
                register(token, identity); requireCurrent(identity, expected); ready(identity)
            } catch (failure: Exception) {
                if (epoch.get() == expected && current(identity)) {
                    unavailable(identity); cleanupRequired.set(true); cleanup()
                }
                throw failure
            }
        }
    }
    private fun requireCurrent(identity: I, expected: Long) {
        check(epoch.get() == expected && current(identity)) { "Native token identity changed" }
    }
    private suspend fun cleanup(): Boolean {
        if (!cleanupRequired.get()) return true
        val expected = epoch.get()
        return try {
            provider.setEnabled(false); withTimeout(providerTimeoutMillis) { provider.deleteToken() }
            if (epoch.get() == expected) cleanupRequired.set(false)
            !cleanupRequired.get()
        } catch (_: Exception) { false }
    }
}
