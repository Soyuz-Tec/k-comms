package com.soyuz.kcomms.push

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.lifecycle.lifecycleScope
import androidx.lifecycle.Lifecycle
import kotlinx.coroutines.flow.first
import com.soyuz.kcomms.KCommsApplication
import com.soyuz.kcomms.ui.KCommsApp
import kotlinx.coroutines.launch

/** Explicit user foreground entry. No receiver starts a microphone/camera FGS,
 * a LiveKit room, or a CoreTelecom call before this user's answer action. */
class NativeWakeAnswerActivity : ComponentActivity() {
    private val controller get() = (application as KCommsApplication).controller
    private var message by mutableStateOf("Verifying current call access…")
    private var answered by mutableStateOf(false)
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            if (answered) KCommsApp(controller)
            else MaterialTheme { Column(Modifier.padding(24.dp)) {
                Text(message); Button(onClick = { finish() }) { Text("Close") }
            } }
        }
        lifecycleScope.launch {
            lifecycle.currentStateFlow.first { it.isAtLeast(Lifecycle.State.STARTED) }
            try {
                val id = intent.getStringExtra("wake_id") ?: error("Missing hint")
                val nonce = intent.getStringExtra("nonce") ?: error("Missing local action")
                val (hint, lease) = controller.nativeWake.takeAnswer(id, nonce)
                controller.answerNativeWake(hint, lease); answered = true
            } catch (_: Exception) { message = "This call could not be admitted with current access and microphone permission. Open K-Comms to review current calls." }
        }
    }
    override fun onStart() { super.onStart(); controller.foreground(true) }
    override fun onStop() { if (!isChangingConfigurations) controller.foreground(false); super.onStop() }
}
