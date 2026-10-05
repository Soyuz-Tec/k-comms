package com.soyuz.kcomms.media

import com.soyuz.kcomms.protocol.MediaCredential
import org.junit.Assert.*
import org.junit.Test
import java.util.Base64

class MediaAdmissionPolicyTest {
    private fun credential(exp: Long = 400) = MediaCredential("wss://media.example.test", token(exp), 300)
    private fun token(exp: Long): String {
        fun encode(value: String) = Base64.getUrlEncoder().withoutPadding().encodeToString(value.toByteArray())
        return "${encode("{\"alg\":\"HS256\"}")}.${encode("{\"exp\":$exp}")}.synthetic-unverified-signature"
    }
    @Test fun jwtClaimCanShortenButNeverExtendBackendAdmissionLifetime() {
        assertEquals(300_000L, MediaAdmissionPolicy.remainingMillis(credential(exp = 10000), null, 100_000))
        assertEquals(40_000L, MediaAdmissionPolicy.remainingMillis(credential(exp = 140), null, 100_000))
    }
    @Test fun callExpiryShortensCredentialEvenIfProviderTokenLastsLonger() {
        assertEquals(10_000L, MediaAdmissionPolicy.remainingMillis(credential(), "1970-01-01T00:01:50Z", 100_000))
    }
    @Test fun expiredAdmissionCannotStartOrContinueCapture() {
        assertThrows(MediaFailure::class.java) { MediaAdmissionPolicy.remainingMillis(credential(exp = 100), null, 100_000) }
        assertThrows(MediaFailure::class.java) { MediaAdmissionPolicy.remainingMillis(credential(), "1970-01-01T00:01:39Z", 100_000) }
    }
    @Test fun unsafeMediaOriginsAndMalformedCredentialsCannotReachSdk() {
        listOf("ws://media.example.test", "https://media.example.test", "wss://user:password@media.example.test", "wss://media.example.test?token=secret").forEach { origin ->
            assertThrows(MediaFailure::class.java) { MediaAdmissionPolicy.remainingMillis(credential().copy(serverUrl = origin), null, 100_000) }
        }
        assertThrows(MediaFailure::class.java) { MediaAdmissionPolicy.remainingMillis(credential().copy(participantToken = "invalid"), null, 100_000) }
        assertThrows(MediaFailure::class.java) { MediaAdmissionPolicy.remainingMillis(credential().copy(expiresIn = 301), null, 100_000) }
    }
    @Test fun keypadMapsExactlyAndRefusesUnsupportedDigits() {
        assertEquals(0, MediaAdmissionPolicy.dtmfCode('0')); assertEquals(9, MediaAdmissionPolicy.dtmfCode('9'))
        assertEquals(10, MediaAdmissionPolicy.dtmfCode('*')); assertEquals(11, MediaAdmissionPolicy.dtmfCode('#'))
        assertThrows(MediaFailure::class.java) { MediaAdmissionPolicy.dtmfCode('x') }
    }
}
