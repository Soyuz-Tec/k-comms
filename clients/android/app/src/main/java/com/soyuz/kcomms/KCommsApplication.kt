package com.soyuz.kcomms

import android.app.Application
import com.soyuz.kcomms.protocol.HttpTransport
import com.soyuz.kcomms.protocol.KCommsApi
import com.soyuz.kcomms.security.KeystoreCredentialVault
import com.soyuz.kcomms.security.SessionStore
import com.soyuz.kcomms.ui.AppController
import io.livekit.android.LiveKit
import io.livekit.android.util.LoggingLevel

class KCommsApplication : Application() {
    lateinit var controller: AppController
        private set
    override fun onCreate() {
        super.onCreate()
        // Keep participant tokens, relay credentials and call metadata out of SDK diagnostics.
        LiveKit.loggingLevel = LoggingLevel.OFF
        LiveKit.enableWebRTCLogging = false
        val sessions = SessionStore(KeystoreCredentialVault(this), HttpTransport())
        controller = AppController(this, KCommsApi(sessions))
    }
}
