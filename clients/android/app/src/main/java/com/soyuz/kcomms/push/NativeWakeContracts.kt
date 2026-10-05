package com.soyuz.kcomms.push

import android.os.SystemClock
import com.soyuz.kcomms.protocol.*
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerialName
import kotlinx.serialization.json.*
import java.time.Instant
import java.util.UUID

@Serializable data class NativePushConfiguration(
    @SerialName("protocol_version") val protocolVersion: Int,
    val enabled: Boolean,
    @SerialName("platform_configs") val platformConfigs: List<NativePlatform>,
    @SerialName("wake_ttl_seconds") val wakeTtlSeconds: Int,
    @SerialName("background_device_qualification_required") val deviceQualificationRequired: Boolean,
) {
    fun approves(application: String, qualified: Boolean): Boolean = qualified && enabled && protocolVersion == 1 &&
        wakeTtlSeconds == 30 && deviceQualificationRequired && platformConfigs.any {
            it.enabled && it.platform == "android" && it.channel == "fcm" && it.applicationId == application && it.environment == "production"
        }
}
@Serializable data class NativePlatform(val platform: String, val channel: String,
    @SerialName("application_id") val applicationId: String, val environment: String, val enabled: Boolean)
@Serializable data class NativeRegistration(val id: String, @SerialName("device_id") val deviceId: String,
    val version: Long, val platform: String, val channel: String, @SerialName("application_id") val applicationId: String,
    val environment: String, val status: String, @SerialName("expires_at") val expiresAt: String)
@Serializable data class NativeRegistrationList(val data: List<NativeRegistration>)
@Serializable data class NativeRegistrationResult(val data: NativeRegistration, val replayed: Boolean)
@Serializable data class NativeConfigurationResult(val data: NativePushConfiguration)

data class NativeWakeHint(val id: String, val expiresAt: Instant, val monotonicDeadline: Long, val receivedUptime: Long) {
    fun current(now: Instant = Instant.now(), uptime: Long = SystemClock.elapsedRealtime()) =
        now.isBefore(expiresAt) && uptime >= receivedUptime && uptime < monotonicDeadline
    companion object {
        fun parse(data: Map<String, String>, now: Instant = Instant.now(), uptime: Long = SystemClock.elapsedRealtime()): NativeWakeHint {
            require(data.keys == setOf("protocol_version", "wake_id", "expires_at", "kind"))
            require(data["protocol_version"] == "1" && data["kind"] == "call")
            val id = data.getValue("wake_id"); require(UUID.fromString(id).toString().equals(id, ignoreCase = true))
            val expiry = Instant.parse(data.getValue("expires_at")); val remaining = expiry.toEpochMilli() - now.toEpochMilli()
            require(remaining in 1..30_000)
            return NativeWakeHint(id, expiry, uptime + remaining, uptime)
        }
    }
}
sealed interface NativeWakeAdmission {
    data class Conversation(val value: CallAdmission) : NativeWakeAdmission
    data class Phone(val value: PhoneSession) : NativeWakeAdmission
    companion object {
        fun decode(body: String): NativeWakeAdmission {
            val value = WireJson.decodeFromString<JsonObject>(body)
            return when (value["owner"]?.jsonPrimitive?.content) {
                "conversation" -> Conversation(WireJson.decodeFromString(body))
                "telephony" -> Phone(WireJson.decodeFromString(body))
                else -> throw IllegalArgumentException("Unsupported native call owner")
            }
        }
    }
}
