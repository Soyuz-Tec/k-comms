package com.soyuz.kcomms.media

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.SystemClock
import android.telecom.DisconnectCause
import androidx.core.content.ContextCompat
import androidx.core.telecom.CallAttributesCompat
import androidx.core.telecom.CallControlResult
import androidx.core.telecom.CallControlScope
import androidx.core.telecom.CallEndpointCompat
import androidx.core.telecom.CallsManager
import com.soyuz.kcomms.protocol.CallAdmission
import com.soyuz.kcomms.protocol.MediaCredential
import com.soyuz.kcomms.protocol.PhoneSession
import com.soyuz.kcomms.protocol.KCommsApi
import com.soyuz.kcomms.protocol.IdentityChanged
import com.soyuz.kcomms.security.IdentityLease
import com.soyuz.kcomms.security.SessionStore
import io.livekit.android.AudioOptions
import io.livekit.android.ConnectOptions
import io.livekit.android.LiveKit
import io.livekit.android.LiveKitOverrides
import io.livekit.android.audio.NoAudioHandler
import io.livekit.android.events.RoomEvent
import io.livekit.android.events.collect
import io.livekit.android.room.Room
import io.livekit.android.room.track.LocalAudioTrack
import io.livekit.android.room.track.VideoTrack
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import livekit.org.webrtc.PeerConnection
import java.security.MessageDigest
import java.util.UUID
import java.time.Instant

enum class MediaPhase { IDLE, CONNECTING, CONNECTED, RECONNECTING, FAILED }
data class MediaEndpoint(val id: String, val label: String, val type: Int)
data class MediaVideoTile(val id: String, val name: String, val local: Boolean, val room: Room, val track: VideoTrack)
data class MediaState(
    val phase: MediaPhase = MediaPhase.IDLE,
    val callId: String? = null,
    val conversationId: String? = null,
    val phoneCallId: String? = null,
    val video: Boolean = false,
    val microphoneEnabled: Boolean = false,
    val cameraEnabled: Boolean = false,
    val held: Boolean = false,
    val endpoints: List<MediaEndpoint> = emptyList(),
    val currentEndpointId: String? = null,
    val error: String? = null,
)

/** One foreground, backend-admitted room. Tokens and relay credentials remain in memory. */
class ForegroundMedia(context: Context, private val sessions: SessionStore, scope: CoroutineScope) {
    private val context = context.applicationContext
    private val lifetime = SupervisorJob()
    private val mediaScope = CoroutineScope(lifetime + Dispatchers.Main.immediate)
    private val mutableState = MutableStateFlow(MediaState())
    val state: StateFlow<MediaState> = mutableState.asStateFlow()
    private val mutableVideoTiles = MutableStateFlow<List<MediaVideoTile>>(emptyList())
    val videoTiles: StateFlow<List<MediaVideoTile>> = mutableVideoTiles.asStateFlow()
    var onUserDisconnect: (() -> Unit)? = null
    private val callsManager = CallsManager(this.context)
    private val api = KCommsApi(sessions)
    private var registered = false
    private var generation = 0L
    private var active: Admission? = null
    private val usedAdmissions = mutableMapOf<String, Long>()
    private val ownerCompletion = scope.coroutineContext[Job]?.invokeOnCompletion { dispose() }

    private class Admission(val lease: IdentityLease, val room: Room, val deadline: Long,
                            val callId: String?, val conversationId: String?, val phoneCallId: String?,
                            val video: Boolean, val incoming: Boolean, parent: Job) {
        val job = SupervisorJob(parent)
        val scope = CoroutineScope(job + Dispatchers.Main.immediate)
        val ready = CompletableDeferred<Unit>()
        val commands = Mutex()
        val endpointCollectors = mutableListOf<Job>()
        var control: CallControlScope? = null
        var telecomJob: Job? = null
        var serviceToken: String? = null
        var endpoints = emptyList<CallEndpointCompat>()
        var userMicrophone = true
        var userCamera = video
        var telecomMuted = false
        var held = false
        var authorityObservedAt = SystemClock.elapsedRealtime()
    }

    init {
        mediaScope.launch {
            sessions.identity.collect { identity ->
                active?.let {
                    if (identity?.lease != it.lease) stopAdmission(it, "The signed-in account changed.")
                    else if (it.phoneCallId != null && identity?.authentication?.user?.workspaceEligible != true)
                        stopAdmission(it, "Your workspace phone access ended.")
                }
            }
        }
    }

    suspend fun connect(admission: CallAdmission, lease: IdentityLease) {
        val call = admission.data
        if (call.status != "active" || call.mediaKind !in setOf("audio", "video"))
            throw MediaFailure("This call is no longer active.")
        validateId(call.id); validateId(call.conversationId)
        connect(admission.credential, lease, call.id, call.conversationId, null,
            call.mediaKind == "video", false, call.expiresAt)
    }

    suspend fun connectPhone(session: PhoneSession, lease: IdentityLease) {
        val call = session.data
        if (call.status !in setOf("ringing", "answered") || call.endedAt != null ||
            !call.activeOnThisDevice || call.direction !in setOf("inbound", "outbound"))
            throw MediaFailure("This phone call is not admitted on this device.")
        validateId(call.id)
        connect(session.credential, lease, null, null, call.id, false, call.direction == "inbound", null)
    }

    private suspend fun connect(credential: MediaCredential, lease: IdentityLease, callId: String?,
                                conversationId: String?, phoneCallId: String?, video: Boolean,
                                incoming: Boolean, callExpiresAt: String?) = withContext(Dispatchers.Main.immediate) {
        sessions.requireCurrent(lease)
        requirePermissions(video)
        if (sessions.remainingAccessMillis() <= 0) throw MediaFailure("Sign in again before joining a call.")
        val remaining = MediaAdmissionPolicy.remainingMillis(credential, callExpiresAt, System.currentTimeMillis())
        val now = SystemClock.elapsedRealtime()
        usedAdmissions.entries.removeAll { it.value <= now }
        val fingerprint = MessageDigest.getInstance("SHA-256").digest(credential.participantToken.toByteArray())
            .joinToString("") { "%02x".format(it) }
        if (usedAdmissions.containsKey(fingerprint)) throw MediaFailure("Join again to request a fresh media admission.")
        val requestGeneration = ++generation
        active?.let { stopAdmission(it) }
        if (requestGeneration != generation) throw CancellationException("Call request superseded")
        sessions.requireCurrent(lease); requirePermissions(video)
        val deadline = now + remaining
        if (SystemClock.elapsedRealtime() >= deadline) throw MediaFailure("Call admission expired. Join again.")
        usedAdmissions[fingerprint] = deadline
        val room = LiveKit.create(context, overrides = LiveKitOverrides(audioOptions = AudioOptions(
            audioHandler = NoAudioHandler(), disableCommunicationModeWorkaround = true,
            disableAudioPrewarming = true, javaAudioDeviceModuleCustomizer = { it.setStopRecordingOnMute(true) },
        )))
        val current = Admission(lease, room, deadline, callId, conversationId, phoneCallId, video, incoming, lifetime)
        active = current
        mutableState.value = MediaState(MediaPhase.CONNECTING, callId, conversationId, phoneCallId, video)
        current.scope.launch {
            try {
                registerTelecom(current)
                current.serviceToken = CallForegroundService.acquire(context, video,
                    onHangup = { userDisconnect(current) },
                    onTerminated = { mediaScope.launch { stopAdmission(current, "The visible call service stopped.") } })
                guard(current)
                watchLifetime(current)
                validateAuthority(current)
                watchAuthority(current)
                current.scope.launch {
                    try {
                        room.events.collect { event ->
                            if (active !== current) return@collect
                            when (event) {
                                is RoomEvent.Disconnected -> stopAdmission(current, "The media connection ended. Join again.")
                                is RoomEvent.Reconnecting -> {
                                    guard(current); mutableState.value = mutableState.value.copy(phase = MediaPhase.RECONNECTING)
                                }
                                is RoomEvent.Reconnected -> {
                                    guard(current)
                                    current.commands.withLock { applyCapture(current) }
                                    mutableState.value = mutableState.value.copy(phase = MediaPhase.CONNECTED)
                                }
                                else -> {
                                    guard(current); updateVideoTiles(current)
                                }
                            }
                        }
                    } catch (cancelled: CancellationException) { throw cancelled }
                    catch (failure: Exception) { stopAdmission(current, (failure as? MediaFailure)?.message ?: "Call authorization ended.") }
                }
                val telecomReady = startTelecom(current)
                withTimeout(7000) { telecomReady.await() }
                guard(current)
                val iceServers = credential.iceServers.map { server ->
                    PeerConnection.IceServer.builder(server.urls).apply {
                        server.username?.let { setUsername(it) }; server.credential?.let { setPassword(it) }
                    }.createIceServer()
                }
                withTimeout(minOf(20000L, current.deadline - SystemClock.elapsedRealtime())) {
                    room.connect(credential.serverUrl, credential.participantToken,
                        ConnectOptions(iceServers = iceServers.takeIf { it.isNotEmpty() }, audio = false, video = false))
                }
                guard(current)
                current.commands.withLock { applyCapture(current) }
                guard(current)
                mutableState.value = mutableState.value.copy(phase = MediaPhase.CONNECTED)
                updateVideoTiles(current)
                current.ready.complete(Unit)
            } catch (_: TimeoutCancellationException) {
                val message = "Media connection timed out. Join again to request a fresh admission."
                current.ready.completeExceptionally(MediaFailure(message))
                stopAdmission(current, message)
            } catch (cancelled: CancellationException) {
                current.ready.completeExceptionally(cancelled)
                if (active === current) withContext(NonCancellable) { stopAdmission(current) }
            } catch (failure: Exception) {
                val message = (failure as? MediaFailure)?.message ?: "Could not connect media. Join again to request a fresh admission."
                current.ready.completeExceptionally(MediaFailure(message))
                stopAdmission(current, message)
            }
        }
        try { current.ready.await() }
        catch (cancelled: CancellationException) {
            withContext(NonCancellable) { if (active === current) stopAdmission(current) }
            throw cancelled
        }
    }

    // MANAGE_OWN_CALLS is a normal manifest permission; recording permissions are checked separately.
    @SuppressLint("MissingPermission")
    private fun registerTelecom(current: Admission) {
        guard(current)
        if (!registered) {
            callsManager.registerAppWithTelecom(CallsManager.CAPABILITY_BASELINE or CallsManager.CAPABILITY_SUPPORTS_VIDEO_CALLING)
            registered = true
        }
    }

    @SuppressLint("MissingPermission")
    private fun startTelecom(current: Admission): CompletableDeferred<Unit> {
        val ready = CompletableDeferred<Unit>()
        current.telecomJob = mediaScope.launch {
            try {
                guard(current)
                val callType = if (current.video) CallAttributesCompat.CALL_TYPE_VIDEO_CALL else CallAttributesCompat.CALL_TYPE_AUDIO_CALL
                callsManager.addCall(
                    CallAttributesCompat("K-Comms call", Uri.parse("sip:foreground@kcomms.invalid"),
                        if (current.incoming) CallAttributesCompat.DIRECTION_INCOMING else CallAttributesCompat.DIRECTION_OUTGOING,
                        callType, CallAttributesCompat.SUPPORTS_SET_INACTIVE),
                    onAnswer = { _ -> telecomHold(current, false) },
                    onDisconnect = { _ ->
                        if (active === current) {
                            try { onUserDisconnect?.invoke() }
                            finally { stopAdmission(current, disconnectTelecom = false) }
                        }
                    },
                    onSetActive = { telecomHold(current, false) },
                    onSetInactive = { telecomHold(current, true) },
                ) {
                    current.control = this
                    current.endpointCollectors += launch {
                        currentCallEndpoint.collect { endpoint ->
                            if (active === current) mutableState.value = mutableState.value.copy(currentEndpointId = endpoint.identifier.toString())
                        }
                    }
                    current.endpointCollectors += launch {
                        availableEndpoints.collect { endpoints ->
                            if (active === current) {
                                current.endpoints = endpoints
                                mutableState.value = mutableState.value.copy(endpoints = endpoints.map {
                                    MediaEndpoint(it.identifier.toString(), it.name.toString(), it.type)
                                })
                            }
                        }
                    }
                    current.endpointCollectors += launch {
                        isMuted.collect { muted ->
                            if (active === current) {
                                current.telecomMuted = muted
                                try { current.commands.withLock { applyCapture(current) } }
                                catch (failure: Exception) { stopAdmission(current, "Microphone state could not be applied.") }
                            }
                        }
                    }
                    launch {
                        try {
                            guard(current)
                            val result = if (current.incoming) answer(callType) else setActive()
                            if (result !is CallControlResult.Success) throw MediaFailure("Android could not activate this call.")
                            guard(current); ready.complete(Unit)
                        } catch (_: Exception) { ready.completeExceptionally(MediaFailure("Android could not activate this call.")) }
                    }
                }
                if (active === current) stopAdmission(current, "Android ended the call.", disconnectTelecom = false)
            } catch (cancelled: CancellationException) {
                ready.completeExceptionally(cancelled)
            } catch (_: Exception) {
                ready.completeExceptionally(MediaFailure("Android could not manage this call."))
                if (active === current) stopAdmission(current, "Android could not manage this call.", disconnectTelecom = false)
            } finally {
                current.endpointCollectors.forEach { it.cancel() }
                current.control = null
                if (!ready.isCompleted) ready.completeExceptionally(MediaFailure("Android ended the call."))
            }
        }
        return ready
    }

    private fun watchLifetime(current: Admission) = current.scope.launch {
        try {
            while (active === current) {
                guard(current)
                delay(minOf(500L, current.deadline - SystemClock.elapsedRealtime()).coerceAtLeast(1))
            }
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) { stopAdmission(current, (failure as? MediaFailure)?.message ?: "Call authorization ended.") }
    }

    private fun watchAuthority(current: Admission) = current.scope.launch {
        try {
            while (active === current) { delay(5000); validateAuthority(current) }
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) { stopAdmission(current, "Current call access could not be verified. Join again.") }
    }

    private suspend fun validateAuthority(current: Admission) {
        guard(current)
        try {
            val me = api.me(current.lease)
            if (current.phoneCallId != null) {
                val call = api.phoneCall(current.phoneCallId, current.lease)
                guard(current)
                MediaAuthorityPolicy.requirePhone(call, current.phoneCallId)
            } else {
                val callId = current.callId ?: throw MediaFailure("The call admission is invalid.")
                val conversationId = current.conversationId ?: throw MediaFailure("The call admission is invalid.")
                val (call, participants) = coroutineScope {
                    val call = async { api.activeCall(conversationId, current.lease) }
                    val participants = async { api.participants(conversationId, callId, current.lease) }
                    call.await() to participants.await()
                }
                guard(current)
                MediaAuthorityPolicy.requireCall(call, participants, me.capabilities, callId, conversationId,
                    current.lease.tenantId, current.lease.userId, Instant.now())
            }
            guard(current)
            current.authorityObservedAt = SystemClock.elapsedRealtime()
        } catch (changed: IdentityChanged) {
            if (sessions.isCurrent(current.lease)) sessions.invalidate()
            throw changed
        }
    }

    private fun guard(current: Admission) {
        if (active !== current || !current.job.isActive) throw CancellationException("Media admission ended")
        sessions.requireCurrent(current.lease)
        if (current.phoneCallId != null) sessions.requireWorkspace(current.lease)
        if (sessions.remainingAccessMillis() <= 0) throw MediaFailure("Your session expired. Sign in again.")
        if (SystemClock.elapsedRealtime() >= current.deadline) throw MediaFailure("Call admission expired. Join again to request a fresh admission.")
        MediaAuthorityPolicy.requireRecent(current.authorityObservedAt, SystemClock.elapsedRealtime())
        requirePermissions(current.video)
    }

    private fun requirePermissions(video: Boolean) {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED)
            throw MediaFailure("Microphone permission is required for calls.")
        if (video && ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED)
            throw MediaFailure("Camera permission is required for video calls.")
    }

    private suspend fun applyCapture(current: Admission) {
        try {
            guard(current)
            val microphone = current.userMicrophone && !current.telecomMuted && !current.held
            val camera = current.video && current.userCamera && !current.held
            current.room.setSpeakerMute(current.held)
            if (current.room.state != Room.State.CONNECTED) {
                // A hold or mute during reconnect must still silence existing published tracks.
                if (!microphone) current.room.localParticipant.setMicrophoneEnabled(false)
                if (current.video && !camera) current.room.localParticipant.setCameraEnabled(false)
                guard(current)
                mutableState.value = mutableState.value.copy(
                    microphoneEnabled = mutableState.value.microphoneEnabled && microphone,
                    cameraEnabled = mutableState.value.cameraEnabled && camera, held = current.held)
                updateVideoTiles(current)
                return
            }
            if (!current.room.localParticipant.setMicrophoneEnabled(microphone)) throw MediaFailure("Microphone could not be enabled.")
            guard(current)
            if (current.video && !current.room.localParticipant.setCameraEnabled(camera)) throw MediaFailure("Camera could not be enabled.")
            guard(current)
            mutableState.value = mutableState.value.copy(microphoneEnabled = microphone, cameraEnabled = camera, held = current.held)
            updateVideoTiles(current)
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (failure: Exception) {
            val message = (failure as? MediaFailure)?.message ?: "The call could not apply its media controls. Join again."
            stopAdmission(current, message)
            throw MediaFailure(message)
        }
    }

    suspend fun setMicrophoneEnabled(enabled: Boolean) = command { current ->
        current.userMicrophone = enabled; applyCapture(current)
    }

    suspend fun setCameraEnabled(enabled: Boolean) = command { current ->
        if (!current.video) throw MediaFailure("This admission permits audio only.")
        current.userCamera = enabled; applyCapture(current)
    }

    suspend fun setHeld(held: Boolean) = withContext(Dispatchers.Main.immediate) {
        val current = active ?: throw MediaFailure("Join a call first.")
        guard(current)
        val control = current.control ?: throw MediaFailure("Android call controls are unavailable.")
        withContext(current.scope.coroutineContext) {
            // Telecom callbacks can also change hold; do not hold the capture mutex during its request.
            val result = if (held) control.setInactive() else control.setActive()
            if (result !is CallControlResult.Success) throw MediaFailure("Android could not change the call hold state.")
            current.commands.withLock { guard(current); current.held = held; applyCapture(current) }
        }
    }

    private suspend fun telecomHold(current: Admission, held: Boolean) {
        try {
            withTimeout(4500) {
                guard(current)
                current.commands.withLock { current.held = held; applyCapture(current) }
            }
        } catch (_: TimeoutCancellationException) {
            stopAdmission(current, "Android could not change the call hold state.")
            throw MediaFailure("The call could not change its hold state.")
        } catch (cancelled: CancellationException) { throw cancelled }
        catch (_: Exception) {
            stopAdmission(current, "Android could not change the call hold state.")
            throw MediaFailure("The call could not change its hold state.")
        }
    }

    suspend fun selectEndpoint(id: String) = command { current ->
        val endpoint = current.endpoints.firstOrNull { it.identifier.toString() == id }
            ?: throw MediaFailure("This audio output is no longer available.")
        if (Build.VERSION.SDK_INT >= 31 && endpoint.type == CallEndpointCompat.TYPE_BLUETOOTH &&
            ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED)
            throw MediaFailure("Bluetooth permission is required for this audio output.")
        val result = current.control?.requestEndpointChange(endpoint)
        guard(current)
        if (result !is CallControlResult.Success) throw MediaFailure("Android could not select this audio output.")
        // Selection is reflected only when Telecom emits currentCallEndpoint.
    }

    /** Caller dispatches only after the backend's current phone-control receipt permits it. */
    suspend fun dtmf(digit: Char, expectedPhoneCallId: String, expectedLease: IdentityLease) = command { current ->
        val code = MediaAdmissionPolicy.dtmfCode(digit)
        if (current.phoneCallId != expectedPhoneCallId || current.lease != expectedLease ||
            current.room.state != Room.State.CONNECTED || current.held)
            throw MediaFailure("A connected phone call is required for the keypad.")
        // Do not retry this uncertain side effect here; the caller completes/reconciles its receipt.
        val result = current.room.localParticipant.publishDtmf(code, digit.toString())
        guard(current)
        if (result.isFailure) throw MediaFailure("The keypad signal could not be confirmed.")
    }

    private suspend fun command(block: suspend (Admission) -> Unit) = withContext(Dispatchers.Main.immediate) {
        val current = active ?: throw MediaFailure("Join a call first.")
        withContext(current.scope.coroutineContext) {
            current.commands.withLock {
                guard(current)
                block(current)
                guard(current)
            }
        }
    }

    private fun updateVideoTiles(current: Admission) {
        if (active !== current) return
        val participants = listOf(current.room.localParticipant) + current.room.remoteParticipants.values
        mutableVideoTiles.value = if (!current.video || current.held) emptyList() else participants.flatMap { participant ->
            participant.trackPublications.values.mapNotNull { publication ->
                val track = publication.track as? VideoTrack ?: return@mapNotNull null
                if (publication.muted) return@mapNotNull null
                val local = participant === current.room.localParticipant
                MediaVideoTile("${participant.sid.value}:${publication.sid}", participant.name?.takeIf { it.isNotBlank() }
                    ?: if (local) "You" else "Participant", local, current.room, track)
            }
        }
    }

    private fun userDisconnect(current: Admission) {
        mediaScope.launch {
            if (active !== current) return@launch
            try { onUserDisconnect?.invoke() }
            finally { stopAdmission(current) }
        }
    }

    suspend fun stop() = withContext(NonCancellable + Dispatchers.Main.immediate) {
        generation += 1
        active?.let { stopAdmission(it) }
        if (active == null) { mutableState.value = MediaState(); mutableVideoTiles.value = emptyList() }
    }

    private suspend fun stopAdmission(current: Admission, error: String? = null, disconnectTelecom: Boolean = true) =
        withContext(NonCancellable + Dispatchers.Main.immediate) {
            if (active !== current) return@withContext
            active = null
            current.ready.completeExceptionally(MediaFailure(error ?: "The call ended."))
            current.job.cancel()
            current.endpointCollectors.forEach { it.cancel() }
            // Stop capture synchronously before any suspendable Telecom cleanup.
            current.room.localParticipant.trackPublications.values.forEach { publication ->
                try { (publication.track as? LocalAudioTrack)?.stopPrewarm(); publication.track?.stop() } catch (_: Exception) { }
            }
            try { current.room.setSpeakerMute(true); current.room.release() } catch (_: Exception) { }
            current.serviceToken?.let { CallForegroundService.release(context, it) }
            mutableVideoTiles.value = emptyList()
            mutableState.value = if (error == null) MediaState() else MediaState(phase = MediaPhase.FAILED, error = error)
            if (disconnectTelecom) {
                withTimeoutOrNull(1500) {
                    try { current.control?.disconnect(DisconnectCause(DisconnectCause.LOCAL)) } catch (_: Exception) { }
                }
                current.telecomJob?.cancel()
            }
            current.control = null
            current.endpoints = emptyList()
        }

    fun dispose() {
        mediaScope.launch {
            stop()
            ownerCompletion?.dispose()
            onUserDisconnect = null
            usedAdmissions.clear()
            lifetime.cancel()
        }
    }

    private fun validateId(id: String) {
        try { UUID.fromString(id) } catch (_: Exception) { throw MediaFailure("The server returned an invalid call identifier.") }
    }
}
