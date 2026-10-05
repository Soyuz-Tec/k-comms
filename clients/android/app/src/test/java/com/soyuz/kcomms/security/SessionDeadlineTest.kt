package com.soyuz.kcomms.security

import org.junit.Assert.*
import org.junit.Test

class SessionDeadlineTest {
    @Test fun authorityExpiresAcrossDeviceSuspendAndCannotBeExtendedByWallClockChange() {
        var monotonic = 500L
        val deadline = SessionDeadline { monotonic }
        deadline.install(90)
        monotonic += 30_000
        assertEquals(60_000L, deadline.remainingMillis())
        // Monotonic elapsed time includes screen-off/suspend, unlike a UI tick counter.
        monotonic += 120_000
        assertEquals(0L, deadline.remainingMillis())
    }
    @Test fun replacementAdmissionReceivesANewDeadlineAndClearRemovesAuthority() {
        var monotonic = 1000L
        val deadline = SessionDeadline { monotonic }
        deadline.install(1); monotonic += 1000; assertEquals(0L, deadline.remainingMillis())
        deadline.install(60); assertEquals(60_000L, deadline.remainingMillis())
        deadline.clear(); assertEquals(0L, deadline.remainingMillis())
    }
    @Test fun malformedLifetimesCannotCreateAuthority() {
        val deadline = SessionDeadline { 0L }
        listOf(0L, -1L, 86401L).forEach { seconds ->
            assertThrows(IllegalArgumentException::class.java) { deadline.install(seconds) }
        }
    }
}
