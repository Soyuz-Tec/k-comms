package com.soyuz.kcomms.media

import com.soyuz.kcomms.protocol.*
import java.time.Instant
import org.junit.Assert.assertThrows
import org.junit.Test

class MediaAuthorityPolicyTest {
    private val now = Instant.parse("2026-01-01T00:00:00Z")
    private val call = Call("call", "conversation", "video", "active", startedAt = now.toString(),
        expiresAt = now.plusSeconds(60).toString(), tenantId = "tenant")
    private val admitted = listOf(CallParticipant("participant", "user", "admitted"))
    private val allowed = MemberCapabilities(allowAudioCalls = true, allowVideoCalls = true)

    @Test fun ownerProjectionMustKeepExactCallMembershipAndMediaCapability() {
        fun validate(call: Call?, participants: List<CallParticipant> = admitted,
                     capabilities: MemberCapabilities = allowed) = MediaAuthorityPolicy.requireCall(
            call, participants, capabilities, "call", "conversation", "tenant", "user", now)
        validate(call)
        listOf(call.copy(id = "replacement"), call.copy(tenantId = "other"), call.copy(status = "ended"),
            call.copy(expiresAt = now.toString())).forEach { invalid ->
            assertThrows(MediaFailure::class.java) { validate(invalid) }
        }
        assertThrows(MediaFailure::class.java) { validate(null) }
        assertThrows(MediaFailure::class.java) { validate(call, admitted.map { it.copy(status = "evicted") }) }
        assertThrows(MediaFailure::class.java) { validate(call, capabilities = allowed.copy(allowVideoCalls = false)) }
    }

    @Test fun stalledAuthorityRequestCannotExtendTheObservedAdmission() {
        MediaAuthorityPolicy.requireRecent(1000, 10_999)
        assertThrows(MediaFailure::class.java) { MediaAuthorityPolicy.requireRecent(1000, 11_000) }
        assertThrows(MediaFailure::class.java) { MediaAuthorityPolicy.requireRecent(1000, 999) }
    }

    @Test fun phoneAdmissionCannotMoveAcrossCallsDevicesOrTerminalStatus() {
        val phone = PhoneCall("phone", "outbound", "answered", "+12025550000", "+12025550123", "1234",
            now.toString(), 42, false, true, true, true)
        MediaAuthorityPolicy.requirePhone(phone, "phone")
        listOf(phone.copy(id = "replacement"), phone.copy(activeOnThisDevice = false),
            phone.copy(status = "ended"), phone.copy(endedAt = now.toString())).forEach {
            assertThrows(MediaFailure::class.java) { MediaAuthorityPolicy.requirePhone(it, "phone") }
        }
    }
}
