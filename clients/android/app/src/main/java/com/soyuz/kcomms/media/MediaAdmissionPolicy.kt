package com.soyuz.kcomms.media

import com.soyuz.kcomms.protocol.MediaCredential
import com.soyuz.kcomms.protocol.WireJson
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonPrimitive
import kotlinx.serialization.json.longOrNull
import java.net.URI
import java.time.Instant
import java.util.Base64

class MediaFailure(message: String) : Exception(message)

/** Checks admission lifetime without treating unsigned JWT claims as authorization. */
object MediaAdmissionPolicy {
    fun remainingMillis(credential: MediaCredential, callExpiresAt: String?, nowMillis: Long): Long {
        val endpoint = try { URI(credential.serverUrl) } catch (_: Exception) { null }
        if (endpoint == null || endpoint.scheme != "wss" || endpoint.host.isNullOrBlank() ||
            endpoint.userInfo != null || endpoint.fragment != null || endpoint.rawQuery != null ||
            credential.serverUrl.length > 2048 || credential.serverUrl.any { it.isISOControl() } ||
            credential.participantToken.length !in 20..16384 || credential.expiresIn !in 1..300) {
            throw MediaFailure("The server returned an invalid media admission.")
        }
        // exp only shortens the backend response's lifetime. The token is verified by LiveKit.
        val tokenExpiry = try {
            val parts = credential.participantToken.split('.')
            require(parts.size == 3)
            val claims = WireJson.decodeFromString<JsonObject>(
                Base64.getUrlDecoder().decode(parts[1]).toString(Charsets.UTF_8))
            Math.multiplyExact(claims["exp"]?.jsonPrimitive?.longOrNull ?: error("Missing expiry"), 1000L)
        } catch (_: Exception) {
            throw MediaFailure("The server returned an invalid media admission.")
        }
        val callExpiry = callExpiresAt?.let {
            try { Instant.parse(it).toEpochMilli() } catch (_: Exception) {
                throw MediaFailure("The server returned an invalid call expiry.")
            }
        } ?: Long.MAX_VALUE
        val remaining = minOf(credential.expiresIn * 1000, tokenExpiry - nowMillis, callExpiry - nowMillis)
        if (remaining <= 0) throw MediaFailure("Call admission expired. Join again to request a fresh admission.")
        if (credential.iceServers.size > 16 || credential.iceServers.any { server ->
                server.urls.isEmpty() || server.urls.size > 16 || server.urls.any { value ->
                    value.length > 2048 || value.any { it.isISOControl() } ||
                        try { URI(value).scheme !in setOf("stun", "stuns", "turn", "turns") }
                        catch (_: Exception) { true }
                } || (server.username?.length ?: 0) > 4096 || (server.credential?.length ?: 0) > 4096
            }) throw MediaFailure("The server returned invalid media relay settings.")
        return remaining
    }

    fun dtmfCode(digit: Char): Int = when (digit) {
        in '0'..'9' -> digit - '0'
        '*' -> 10
        '#' -> 11
        else -> throw MediaFailure("Choose a digit from 0–9, * or #.")
    }
}
