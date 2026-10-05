package com.soyuz.kcomms.media

import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.key
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import livekit.org.webrtc.SurfaceViewRenderer

/** Renderer lifetime follows one observed LiveKit publication and removes its sink on teardown. */
@Composable
fun MediaVideo(tile: MediaVideoTile, modifier: Modifier = Modifier) {
    key(tile.room, tile.track) {
        val context = LocalContext.current
        val renderer = remember(tile.room, tile.track) {
            SurfaceViewRenderer(context).also {
                tile.room.initVideoRenderer(it)
                it.setMirror(tile.local)
                it.setZOrderMediaOverlay(tile.local)
            }
        }
        DisposableEffect(renderer, tile.track) {
            tile.track.addRenderer(renderer)
            onDispose {
                // Room termination may already have disposed the underlying RTC track.
                runCatching { tile.track.removeRenderer(renderer) }
                renderer.release()
            }
        }
        AndroidView(factory = { renderer }, modifier = modifier)
    }
}
