package com.soyuz.kcomms.media

import com.soyuz.kcomms.protocol.*
import java.time.Instant

object MediaAuthorityPolicy {
    fun requireRecent(observedAt: Long, now: Long) {
        if (now < observedAt || now - observedAt >= 10_000)
            throw MediaFailure("Current call access could not be verified. Join again.")
    }

    fun requireCall(call: Call?, participants: List<CallParticipant>, capabilities: MemberCapabilities,
                    callId: String, conversationId: String, tenantId: String, userId: String, now: Instant) {
        if (call == null || call.id != callId || call.conversationId != conversationId ||
            call.tenantId != tenantId || call.status != "active" || call.endedAt != null ||
            Instant.parse(call.expiresAt) <= now ||
            (if (call.mediaKind == "video") !capabilities.allowVideoCalls
                else call.mediaKind != "audio" || !capabilities.allowAudioCalls) ||
            participants.none { it.userId == userId && it.status == "admitted" })
            throw MediaFailure("Your access to this call ended.")
    }

    fun requirePhone(call: PhoneCall, callId: String) {
        if (call.id != callId || call.status !in setOf("ringing", "answered") ||
            call.endedAt != null || !call.activeOnThisDevice)
            throw MediaFailure("This phone call is no longer admitted on this device.")
    }
}
