package com.soyuz.kcomms.push

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import com.soyuz.kcomms.KCommsApplication

class NativeMessagingService : FirebaseMessagingService() {
    override fun onNewToken(token: String) { (application as KCommsApplication).controller.nativeWake.onToken(token) }
    override fun onMessageReceived(message: RemoteMessage) {
        (application as KCommsApplication).controller.nativeWake.receive(message.data)
    }
}
class NativeWakeDismissReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val id = intent.getStringExtra("wake_id") ?: return; val nonce = intent.getStringExtra("nonce") ?: return
        (context.applicationContext as KCommsApplication).controller.nativeWake.dismiss(id, nonce)
    }
}
