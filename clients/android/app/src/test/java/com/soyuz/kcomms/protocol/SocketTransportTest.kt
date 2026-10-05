package com.soyuz.kcomms.protocol

import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.tls.HandshakeCertificates
import okhttp3.tls.HeldCertificate
import org.junit.Assert.*
import org.junit.Test

class SocketTransportTest {
    @Test fun actualTlsWebSocketHandshakeKeepsTheSingleUseTicketOutOfItsUrl() {
        val certificate = HeldCertificate.Builder().addSubjectAlternativeName("localhost").build()
        val serverTls = HandshakeCertificates.Builder().heldCertificate(certificate).build()
        val clientTls = HandshakeCertificates.Builder().addTrustedCertificate(certificate.certificate).build()
        val server = MockWebServer()
        val client = HttpTransport.secureClient().newBuilder()
            .sslSocketFactory(clientTls.sslSocketFactory(), clientTls.trustManager).build()
        val opened = CountDownLatch(1)
        var socket: WebSocket? = null
        server.useHttps(serverTls.sslSocketFactory(), false)
        server.enqueue(MockResponse().withWebSocketUpgrade(object : WebSocketListener() {
            override fun onClosing(webSocket: WebSocket, code: Int, reason: String) { webSocket.close(code, reason) }
        }))
        server.start()
        try {
            val ticket = "synthetic-single-use-ticket-for-this-handshake"
            val endpoint = Endpoint.parse(server.url("/").toString())
            socket = client.newWebSocket(endpoint.socketRequest(ticket), object : WebSocketListener() {
                override fun onOpen(webSocket: WebSocket, response: Response) { opened.countDown(); webSocket.close(1000, "Test complete") }
            })
            val actual = checkNotNull(server.takeRequest(5, TimeUnit.SECONDS))
            assertTrue(opened.await(5, TimeUnit.SECONDS))
            assertEquals("/socket/websocket?vsn=2.0.0", actual.path)
            assertEquals(setOf("vsn"), actual.requestUrl!!.queryParameterNames)
            assertEquals(listOf(ticket), actual.headers.values("x-k-comms-socket-ticket"))
            assertNull(actual.getHeader("Authorization"))
            assertFalse(actual.path!!.contains(ticket))
            assertEquals("websocket", actual.getHeader("Upgrade"))
        } finally {
            socket?.cancel(); client.connectionPool.evictAll(); client.dispatcher.executorService.shutdown()
            server.shutdown()
        }
    }

    @Test fun unsafeOriginsAndHeaderInjectionAreRejectedBeforeTransport() {
        listOf("http://workspace.example", "https://bearer@workspace.example", "https://workspace.example?token=secret",
            "https://workspace.example#credential", "https://workspace.example/api").forEach {
            assertThrows(IllegalArgumentException::class.java) { Endpoint.parse(it) }
        }
        val endpoint = Endpoint.parse("https://workspace.example")
        listOf("", "x".repeat(1025), "synthetic-ticket-123456\r\nAuthorization: injected", "synthetic ticket 123456789").forEach {
            assertThrows(IllegalArgumentException::class.java) { endpoint.socketRequest(it) }
        }
    }
}
