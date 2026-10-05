package com.soyuz.kcomms.push

import android.Manifest
import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.SystemClock
import androidx.core.app.NotificationCompat
import androidx.core.app.Person
import androidx.core.content.ContextCompat
import com.google.firebase.FirebaseApp
import com.google.firebase.FirebaseOptions
import com.google.firebase.messaging.FirebaseMessaging
import com.soyuz.kcomms.BuildConfig
import com.soyuz.kcomms.R
import com.soyuz.kcomms.protocol.KCommsApi
import com.soyuz.kcomms.security.IdentityLease
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.collect
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import java.util.UUID
import com.google.android.gms.tasks.Task
import kotlin.coroutines.resume
import kotlin.coroutines.resumeWithException

/** Opaque hints live only in bounded RAM. Neither receive nor token callbacks
 * open media or claim a phone line. The user opens an explicit answer Activity. */
class NativeWakeCoordinator(context: Context, private val api: KCommsApi, private val scope: CoroutineScope) {
    private val context = context.applicationContext
    private val manager = this.context.getSystemService(NotificationManager::class.java)
    private val preferences = this.context.getSharedPreferences("native_push_choices", Context.MODE_PRIVATE)
    private val mutex = Mutex()
    private val mutableNotice = MutableStateFlow("Background call wake is unavailable until this signed build and deployment are qualified.")
    val notice = mutableNotice.asStateFlow()
    private data class Pending(val hint: NativeWakeHint, val nonce: String, val lease: IdentityLease, val notification: Int)
    private val inbox = mutableMapOf<String, Pending>()
    private val seen = mutableMapOf<String, Long>()
    private val tokens = NativeTokenLifecycle(scope, object : NativeTokenProvider {
        override fun setEnabled(enabled: Boolean) {
            if (FirebaseApp.getApps(context).isNotEmpty()) FirebaseMessaging.getInstance().isAutoInitEnabled = enabled
        }
        override suspend fun token(): String = FirebaseMessaging.getInstance().token.awaitResult()
        override suspend fun deleteToken() {
            if (FirebaseApp.getApps(context).isNotEmpty()) FirebaseMessaging.getInstance().deleteToken().awaitResult()
        }
    }, current = api.sessions::isCurrent, register = { token, lease -> registerToken(token, lease) },
        ready = { mutableNotice.value = "Native registration is current. Incoming notifications open the app for an explicit answer; device qualification remains required." },
        unavailable = { mutableNotice.value = "Native registration could not be confirmed. Keep the app open." })
    private var registration: NativeRegistration? = null
    private val installation: String get() {
        val current = preferences.getString("installation_id", null)
        if (current != null && runCatching { UUID.fromString(current) }.isSuccess) return current
        return UUID.randomUUID().toString().also { preferences.edit().putString("installation_id", it).apply() }
    }
    init {
        scope.launch {
            var previous: IdentityLease? = null
            var ownerVersion = 0L
            api.sessions.identity.collect { current ->
                if (previous != current?.lease) {
                    previous = current?.lease
                    ownerVersion = current?.authentication?.user?.version ?: 0L
                    mutex.withLock { inbox.values.forEach { manager.cancel(it.notification) }; inbox.clear(); seen.clear(); registration = null }
                    if (current == null) tokens.invalidate()
                } else if (current != null && current.authentication.user.version != ownerVersion) {
                    ownerVersion = current.authentication.user.version
                    if (preferences.getBoolean("user_consent", false)) enable()
                }
            }
        }
    }
    fun initializeQualifiedSdk(): Boolean {
        if (!BuildConfig.NATIVE_PUSH_QUALIFIED || !preferences.getBoolean("user_consent", false)) return false
        return runCatching {
            if (FirebaseApp.getApps(context).isEmpty()) {
                val appId = context.getString(R.string.native_fcm_application_id)
                val project = context.getString(R.string.native_fcm_project_id)
                val sender = context.getString(R.string.native_fcm_sender_id)
                val key = context.getString(R.string.native_fcm_api_key)
                require(appId.isNotBlank() && project.isNotBlank() && sender.isNotBlank() && key.isNotBlank())
                FirebaseApp.initializeApp(context, FirebaseOptions.Builder().setApplicationId(appId).setProjectId(project)
                    .setGcmSenderId(sender).setApiKey(key).build())
            }
            FirebaseMessaging.getInstance().isAutoInitEnabled = false
            true
        }.getOrDefault(false)
    }
    fun enable() = scope.launch {
        val lease = runCatching { api.sessions.capture() }.getOrNull() ?: return@launch
        try {
            api.me(lease)
            val config = api.nativePushConfiguration(lease)
            require(config.approves(BuildConfig.APPLICATION_ID, BuildConfig.NATIVE_PUSH_QUALIFIED))
            require(hasNotificationPermission() && hasMicrophonePermission())
            api.sessions.requireCurrent(lease)
            preferences.edit().putBoolean("user_consent", true).apply()
            require(initializeQualifiedSdk())
            mutableNotice.value = "Confirming the native provider token and current registration…"
            tokens.enable(lease)
        } catch (_: Exception) {
            // Every UI/SDK mutation from an old flight is fenced to its lease.
            if (api.sessions.isCurrent(lease)) {
                if (!hasNotificationPermission() || !hasMicrophonePermission()) tokens.invalidate()
                mutableNotice.value = "Native wake is unavailable. Deployment qualification, provider setup, current registration and permissions are required."
            }
        }
    }
    fun onToken(token: String, expected: IdentityLease? = null) {
        if (!BuildConfig.NATIVE_PUSH_QUALIFIED || !preferences.getBoolean("user_consent", false)) return
        // The callback token itself is never authority. Obtain the current SDK
        // token through the same serialized cleanup/replacement lifecycle.
        scope.launch {
            try {
                if (expected != null) api.sessions.requireCurrent(expected)
                if (api.sessions.identity.value == null && expected == null) api.sessions.restore()
                val lease = expected ?: api.sessions.capture(); api.me(lease)
                require(api.nativePushConfiguration(lease).approves(BuildConfig.APPLICATION_ID, true))
                api.sessions.requireCurrent(lease)
                require(preferences.getBoolean("user_consent", false) && hasNotificationPermission() && hasMicrophonePermission())
                tokens.enable(lease)
            } catch (_: Exception) {
                // OS withdrawal is global; a stale identity callback otherwise
                // has no permission to mutate the newer owner's lifecycle.
                if (!hasNotificationPermission() || !hasMicrophonePermission()) tokens.invalidate()
            }
        }
    }
    private suspend fun registerToken(token: String, lease: IdentityLease) {
        api.sessions.requireCurrent(lease)
        require(preferences.getBoolean("user_consent", false) && hasNotificationPermission() && hasMicrophonePermission())
        val current = api.nativeRegistrations(lease).firstOrNull { it.channel == "fcm" }
        val receipt = api.registerNativePush(token, installation, BuildConfig.APPLICATION_ID, current?.version ?: 0, lease)
        api.sessions.requireCurrent(lease)
        require(receipt.data.deviceId == lease.deviceId && receipt.data.status == "active")
        registration = receipt.data
    }
    fun receive(data: Map<String, String>) {
        if (!BuildConfig.NATIVE_PUSH_QUALIFIED || !preferences.getBoolean("user_consent", false)) return
        val hint = runCatching { NativeWakeHint.parse(data) }.getOrNull() ?: return
        scope.launch {
            try {
                if (api.sessions.identity.value == null) api.sessions.restore()
                val lease = api.sessions.capture(); api.me(lease)
                require(api.nativePushConfiguration(lease).approves(BuildConfig.APPLICATION_ID, true))
                api.sessions.requireCurrent(lease); require(hint.current() && hasNotificationPermission())
                mutex.withLock {
                    seen.entries.removeAll { it.value <= SystemClock.elapsedRealtime() }
                    if (seen.containsKey(hint.id) || inbox.size >= 16 || seen.size >= 128) return@withLock
                    seen[hint.id] = hint.monotonicDeadline
                    val nonce = UUID.randomUUID().toString(); val id = nonce.hashCode()
                    val entry = Pending(hint, nonce, lease, id); inbox[hint.id] = entry; show(entry)
                    scope.launch {
                        delay((hint.monotonicDeadline - SystemClock.elapsedRealtime()).coerceAtLeast(0))
                        dismiss(hint.id, nonce)
                    }
                }
            } catch (_: Exception) { /* Opaque unauthoritative hints are dropped without diagnostics. */ }
        }
    }
    suspend fun takeAnswer(id: String, nonce: String): Pair<NativeWakeHint, IdentityLease> = mutex.withLock {
        val entry = inbox[id] ?: throw IllegalArgumentException("This incoming call is no longer available")
        require(entry.nonce == nonce && entry.hint.current() && api.sessions.isCurrent(entry.lease))
        require(hasMicrophonePermission())
        inbox.remove(id); manager.cancel(entry.notification)
        entry.hint to entry.lease
    }
    fun dismiss(id: String, nonce: String) = scope.launch {
        mutex.withLock { inbox[id]?.takeIf { it.nonce == nonce }?.let { inbox.remove(id); manager.cancel(it.notification) } }
    }
    fun invalidate() {
        preferences.edit().putBoolean("user_consent", false).apply()
        scope.launch { mutex.withLock { inbox.values.forEach { manager.cancel(it.notification) }; inbox.clear(); seen.clear() } }
        registration = null; tokens.invalidate()
    }
    private fun hasNotificationPermission() = Build.VERSION.SDK_INT < 33 ||
        ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) == PackageManager.PERMISSION_GRANTED
    private fun hasMicrophonePermission() = ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED
    @SuppressLint("MissingPermission")
    private fun show(entry: Pending) {
        manager.createNotificationChannel(NotificationChannel("native_calls", "Incoming K-Comms calls", NotificationManager.IMPORTANCE_HIGH))
        val answer = PendingIntent.getActivity(context, entry.notification, Intent(context, NativeWakeAnswerActivity::class.java)
            .putExtra("wake_id", entry.hint.id).putExtra("nonce", entry.nonce), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_CANCEL_CURRENT)
        val decline = PendingIntent.getBroadcast(context, entry.notification, Intent(context, NativeWakeDismissReceiver::class.java)
            .putExtra("wake_id", entry.hint.id).putExtra("nonce", entry.nonce), PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_CANCEL_CURRENT)
        val caller = Person.Builder().setName("K-Comms call").build()
        val notification = NotificationCompat.Builder(context, "native_calls").setSmallIcon(R.drawable.ic_call)
            .setContentTitle("Incoming K-Comms call").setContentText("Open the app to answer with current account access.")
            .setCategory(NotificationCompat.CATEGORY_CALL).setVisibility(NotificationCompat.VISIBILITY_SECRET)
            .setPriority(NotificationCompat.PRIORITY_HIGH).setStyle(NotificationCompat.CallStyle.forIncomingCall(caller, decline, answer))
            .setContentIntent(answer).setAutoCancel(true).setTimeoutAfter((entry.hint.monotonicDeadline - SystemClock.elapsedRealtime()).coerceAtLeast(1))
            .build()
        manager.notify(entry.notification, notification)
    }
}

private suspend fun <T> Task<T>.awaitResult(): T = suspendCancellableCoroutine { continuation ->
    addOnCompleteListener { result ->
        if (!continuation.isActive) return@addOnCompleteListener
        if (result.isSuccessful) continuation.resume(result.result)
        else continuation.resumeWithException(IllegalStateException("Native provider operation could not be confirmed"))
    }
}
