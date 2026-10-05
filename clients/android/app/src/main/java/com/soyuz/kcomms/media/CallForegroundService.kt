package com.soyuz.kcomms.media

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Person
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.content.ContextCompat
import com.soyuz.kcomms.R
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeout
import java.util.UUID

/** Visible, non-restarting service for media already admitted from the foreground UI. */
class CallForegroundService : Service() {
    private var token: String? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val requested = intent?.getStringExtra(EXTRA_TOKEN)
        if (intent?.action == ACTION_STOP) {
            if (token == null || requested == token) { stopForeground(STOP_FOREGROUND_REMOVE); stopSelfResult(startId) }
            return START_NOT_STICKY
        }
        if (intent?.action == ACTION_HANGUP) {
            val admitted = registration?.takeIf { it.token == requested && requested == token }
            if (admitted != null) admitted.onHangup()
            else if (token == null || requested == token) { stopForeground(STOP_FOREGROUND_REMOVE); stopSelfResult(startId) }
            return START_NOT_STICKY
        }
        val admitted = registration?.takeIf { it.token == requested }
        if (admitted == null) { stopSelfResult(startId); return START_NOT_STICKY }
        token = admitted.token
        try {
            check(ContextCompat.checkSelfPermission(this, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED)
            if (admitted.video) check(ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED)
            val manager = getSystemService(NotificationManager::class.java)
            manager.createNotificationChannel(NotificationChannel(CHANNEL, "Ongoing calls", NotificationManager.IMPORTANCE_LOW).apply {
                setSound(null, null); lockscreenVisibility = Notification.VISIBILITY_PRIVATE
            })
            val hangup = PendingIntent.getService(this, 0,
                Intent(this, CallForegroundService::class.java).setAction(ACTION_HANGUP).putExtra(EXTRA_TOKEN, admitted.token),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)
            val builder = Notification.Builder(this, CHANNEL)
                .setSmallIcon(R.drawable.ic_call).setContentTitle("K-Comms call")
                .setContentText(if (admitted.video) "Video call in progress" else "Audio call in progress")
                .setCategory(Notification.CATEGORY_CALL).setVisibility(Notification.VISIBILITY_PRIVATE)
                .setOngoing(true).setOnlyAlertOnce(true)
            packageManager.getLaunchIntentForPackage(packageName)?.let { launch ->
                builder.setContentIntent(PendingIntent.getActivity(this, 1, launch,
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE))
            }
            if (Build.VERSION.SDK_INT >= 31) {
                builder.setStyle(Notification.CallStyle.forOngoingCall(
                    Person.Builder().setName("K-Comms call").setImportant(true).build(), hangup))
            } else {
                builder.addAction(Notification.Action.Builder(R.drawable.ic_call, "Leave call", hangup).build())
            }
            if (Build.VERSION.SDK_INT >= 29) {
                var types = ServiceInfo.FOREGROUND_SERVICE_TYPE_PHONE_CALL
                if (Build.VERSION.SDK_INT >= 30) {
                    types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE
                    if (admitted.video) types = types or ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA
                }
                startForeground(NOTIFICATION_ID, builder.build(), types)
            } else startForeground(NOTIFICATION_ID, builder.build())
            admitted.ready.complete(Unit)
        } catch (_: Exception) {
            admitted.ready.completeExceptionally(MediaFailure("Android could not start the visible call service."))
            admitted.onTerminated()
            stopForeground(STOP_FOREGROUND_REMOVE); stopSelfResult(startId)
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        registration?.takeIf { it.token == token }?.let {
            it.ready.completeExceptionally(MediaFailure("The call service stopped."))
            it.onTerminated()
        }
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL = "kcomms-active-call"
        private const val NOTIFICATION_ID = 4101
        private const val EXTRA_TOKEN = "foreground_instance"
        private const val ACTION_START = "com.soyuz.kcomms.media.START"
        private const val ACTION_STOP = "com.soyuz.kcomms.media.STOP"
        private const val ACTION_HANGUP = "com.soyuz.kcomms.media.HANGUP"
        private data class Registration(val token: String, val video: Boolean,
            val ready: CompletableDeferred<Unit>, val onHangup: () -> Unit, val onTerminated: () -> Unit)
        // Accessed on the main dispatcher. No participant credentials or backend IDs enter an Intent.
        private var registration: Registration? = null

        internal suspend fun acquire(context: Context, video: Boolean, onHangup: () -> Unit,
                                     onTerminated: () -> Unit): String {
            if (registration != null) throw MediaFailure("Another call is already using the media service.")
            val admitted = Registration(UUID.randomUUID().toString(), video, CompletableDeferred(), onHangup, onTerminated)
            registration = admitted
            try {
                ContextCompat.startForegroundService(context,
                    Intent(context, CallForegroundService::class.java).setAction(ACTION_START).putExtra(EXTRA_TOKEN, admitted.token))
                withTimeout(5000) { admitted.ready.await() }
                return admitted.token
            } catch (failure: Exception) {
                release(context, admitted.token)
                throw failure
            }
        }

        internal fun release(context: Context, token: String) {
            if (registration?.token != token) return
            registration = null
            try {
                context.startService(Intent(context, CallForegroundService::class.java)
                    .setAction(ACTION_STOP).putExtra(EXTRA_TOKEN, token))
            } catch (_: Exception) { context.stopService(Intent(context, CallForegroundService::class.java)) }
        }
    }
}
