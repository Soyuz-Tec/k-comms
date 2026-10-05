package com.soyuz.kcomms.security

/** Monotonic time includes suspend; wall-clock changes must not extend authority. */
class SessionDeadline(private val nowMillis: () -> Long) {
    private var deadline = 0L
    fun install(expiresInSeconds: Long) {
        require(expiresInSeconds in 1..86400)
        deadline = Math.addExact(nowMillis(), Math.multiplyExact(expiresInSeconds, 1000L))
    }
    fun remainingMillis(): Long = (deadline - nowMillis()).coerceAtLeast(0)
    fun clear() { deadline = 0 }
}
