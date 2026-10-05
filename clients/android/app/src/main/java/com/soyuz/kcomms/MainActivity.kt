package com.soyuz.kcomms

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import com.soyuz.kcomms.ui.KCommsApp

class MainActivity : ComponentActivity() {
    private val controller get() = (application as KCommsApplication).controller
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent { KCommsApp(controller) }
    }
    override fun onStart() { super.onStart(); controller.foreground(true) }
    override fun onStop() { if (!isChangingConfigurations) controller.foreground(false); super.onStop() }
}
