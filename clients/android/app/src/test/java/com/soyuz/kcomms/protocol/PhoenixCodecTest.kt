package com.soyuz.kcomms.protocol

import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import org.junit.Assert.*
import org.junit.Test

class PhoenixCodecTest {
    @Test fun versionTwoFramesPreserveJoinAndRequestReferences() {
        val payload = buildJsonObject { put("status", "ok") }
        val event = PhoenixCodec.decode(PhoenixCodec.encode("7", "8", "conversation:room", "phx_reply", payload))
        assertEquals("7", event.joinReference)
        assertEquals("8", event.reference)
        assertEquals("conversation:room", event.topic)
        assertEquals(payload, event.payload)
        val heartbeat = PhoenixCodec.decode(PhoenixCodec.encode(null, "9", "phoenix", "heartbeat", buildJsonObject {}))
        assertNull(heartbeat.joinReference)
    }

    @Test fun malformedAndOversizedFramesAreRejectedBeforeDispatch() {
        listOf("{}", "[null,\"1\",\"topic\",\"event\"]", "[null,\"1\",1,\"event\",{}]",
            "[null,\"1\",\"topic\",\"event\",[]]", "[false,\"1\",\"topic\",\"event\",{}]",
            " ".repeat(1_048_577)).forEach { frame ->
            assertThrows(RuntimeException::class.java) { PhoenixCodec.decode(frame) }
        }
    }
}
