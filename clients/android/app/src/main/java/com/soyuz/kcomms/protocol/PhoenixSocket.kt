package com.soyuz.kcomms.protocol

import com.soyuz.kcomms.security.IdentityLease
import kotlinx.coroutines.*
import kotlinx.coroutines.channels.Channel
import kotlinx.serialization.json.*
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.ConcurrentHashMap

data class PhoenixEvent(val topic: String, val event: String, val payload: JsonObject,
                        val reference: String? = null, val joinReference: String? = null)
object PhoenixCodec {
    fun encode(joinRef: String?, reference: String, topic: String, event: String, payload: JsonObject) =
        JsonArray(listOf(joinRef?.let(::JsonPrimitive) ?: JsonNull, JsonPrimitive(reference),
            JsonPrimitive(topic), JsonPrimitive(event), payload)).toString()
    fun decode(text: String): PhoenixEvent {
        require(text.toByteArray().size <= 1_048_576)
        val frame = WireJson.parseToJsonElement(text).jsonArray
        require(frame.size == 5)
        fun nullableReference(index: Int): String? {
            if (frame[index] == JsonNull) return null
            val value = frame[index].jsonPrimitive
            require(value.isString && value.content.length in 1..128)
            return value.content
        }
        val topic = frame[2].jsonPrimitive; val event = frame[3].jsonPrimitive
        require(topic.isString && topic.content.length in 1..256 && event.isString && event.content.length in 1..128)
        return PhoenixEvent(topic.content, event.content, frame[4].jsonObject, nullableReference(1), nullableReference(0))
    }
}

/** Foreground only. Each reconnect obtains a new single-use ticket; no bearer URL. */
class PhoenixSocket(private val api: KCommsApi) {
    private val references = AtomicLong()
    private val generations = AtomicLong()
    private var job: Job? = null
    private var socket: WebSocket? = null
    fun stop() {
        generations.incrementAndGet()
        job?.cancel(); job = null; socket?.close(1000, "Foreground connection closed"); socket = null
    }

    fun start(scope: CoroutineScope, lease: IdentityLease, conversationId: String?, afterSequence: Long,
              onEvent: (PhoenixEvent) -> Unit, onReconnected: () -> Unit) {
        stop()
        require(afterSequence >= 0)
        val generation = generations.get()
        job = scope.launch {
            var attempt = 0
            while (isActive && api.sessions.isCurrent(lease) && generations.get() == generation) {
                val closed = CompletableDeferred<Unit>()
                val events = Channel<PhoenixEvent>(32)
                var connectionSocket: WebSocket? = null
                try {
                    val ticket = api.ticket(lease)
                    api.sessions.requireCurrent(lease)
                    val allowedTopics = buildSet {
                        add("user:${lease.userId}")
                        if (conversationId != null) add("conversation:$conversationId")
                    }
                    val endpoint = Endpoint.parse(lease.origin)
                    val joining = ConcurrentHashMap<String, String>()
                    val joined = mutableSetOf<String>()
                    val listener = object : WebSocketListener() {
                        override fun onOpen(webSocket: WebSocket, response: Response) {
                            if (!api.sessions.isCurrent(lease) || generations.get() != generation) { webSocket.cancel(); return }
                            allowedTopics.forEach { topic ->
                                val ref = references.incrementAndGet().toString()
                                joining[ref] = topic
                                webSocket.send(PhoenixCodec.encode(ref, ref, topic, "phx_join", buildJsonObject {
                                    if (topic.startsWith("conversation:")) put("after_sequence", afterSequence)
                                }))
                            }
                        }
                        override fun onMessage(webSocket: WebSocket, text: String) {
                            if (!api.sessions.isCurrent(lease) || generations.get() != generation) { webSocket.cancel(); return }
                            try {
                                val event = PhoenixCodec.decode(text)
                                if (event.topic == "phoenix" || event.topic in allowedTopics) {
                                    if (!events.trySend(event).isSuccess) webSocket.cancel()
                                } else webSocket.cancel()
                            } catch (_: Exception) { webSocket.cancel() }
                        }
                        override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) { closed.complete(Unit) }
                        override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(code, null); closed.complete(Unit) }
                        override fun onClosed(webSocket: WebSocket, code: Int, reason: String) { closed.complete(Unit) }
                    }
                    connectionSocket = api.sessions.transport.client.newWebSocket(endpoint.socketRequest(ticket.ticket), listener)
                    if (generations.get() != generation) { connectionSocket?.cancel(); return@launch }
                    socket = connectionSocket
                    coroutineScope {
                        val heartbeat = launch {
                            while (isActive) {
                                delay(25_000); api.sessions.requireCurrent(lease)
                                connectionSocket?.send(PhoenixCodec.encode(null, references.incrementAndGet().toString(), "phoenix", "heartbeat", buildJsonObject {}))
                            }
                        }
                        val reader = launch {
                            for (event in events) {
                                api.sessions.requireCurrent(lease)
                                if (generations.get() != generation) throw CancellationException()
                                if (event.event in listOf("phx_close", "phx_error")) {
                                    connectionSocket?.cancel(); closed.complete(Unit)
                                } else if (event.event == "phx_reply") {
                                    val topic = event.reference?.let { joining.remove(it) }
                                    if (topic != null) {
                                        if (topic == event.topic && event.payload["status"]?.jsonPrimitive?.content == "ok") {
                                            joined += topic
                                            if (joined == allowedTopics) { attempt = 0; onReconnected() }
                                        } else { connectionSocket?.cancel(); closed.complete(Unit) }
                                    }
                                } else onEvent(event)
                            }
                        }
                        closed.await(); heartbeat.cancel(); reader.cancel()
                    }
                } catch (cancelled: CancellationException) { throw cancelled }
                catch (_: Exception) { /* Backoff is bounded; REST establishes current authority on reconnect. */ }
                finally {
                    events.close(); connectionSocket?.cancel()
                    if (socket === connectionSocket) socket = null
                }
                attempt = (attempt + 1).coerceAtMost(5)
                delay((1000L shl attempt).coerceAtMost(30_000))
            }
        }
    }
}
