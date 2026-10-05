package com.soyuz.kcomms.protocol

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.io.ByteArrayOutputStream
import java.util.concurrent.TimeUnit

class Endpoint private constructor(val origin: HttpUrl) {
    val canonical: String get() = origin.toString().trimEnd('/')
    fun api(path: String, query: Map<String, String> = emptyMap()): HttpUrl {
        require(path.startsWith('/') && !path.contains("..") && !path.contains('?'))
        return origin.newBuilder().encodedPath("/api/v1$path").apply {
            query.forEach { (key, value) -> addQueryParameter(key, value) }
        }.build()
    }
    fun socketRequest(ticket: String): Request {
        require(ticket.length in 20..1024 && ticket.all { it.code in 33..126 })
        val url = origin.newBuilder().scheme("https").encodedPath("/socket/websocket")
            .addQueryParameter("vsn", "2.0.0").build()
        return Request.Builder().url(url).header("x-k-comms-socket-ticket", ticket).build()
    }

    companion object {
        fun parse(value: String): Endpoint {
            val url = value.trim().toHttpUrl()
            require(url.isHttps && url.username.isEmpty() && url.password.isEmpty() &&
                url.encodedPath == "/" && url.query == null && url.fragment == null) {
                "Use a bare HTTPS workspace origin."
            }
            return Endpoint(url)
        }
    }
}

class HttpTransport(val client: OkHttpClient = secureClient()) {
    companion object {
        const val MAX_BODY_BYTES = 1_048_576
        fun secureClient() = OkHttpClient.Builder().connectTimeout(5, TimeUnit.SECONDS)
            .readTimeout(15, TimeUnit.SECONDS).writeTimeout(15, TimeUnit.SECONDS)
            .callTimeout(20, TimeUnit.SECONDS).followRedirects(false).followSslRedirects(false)
            .retryOnConnectionFailure(false).build()
    }

    suspend fun request(endpoint: Endpoint, method: String, path: String,
                        body: JsonObject? = null, token: String? = null,
                        idempotencyKey: String? = null, query: Map<String, String> = emptyMap()): String =
        withContext(Dispatchers.IO) {
            val requestBody = body?.toString()?.toRequestBody("application/json".toMediaType())
            val builder = Request.Builder().url(endpoint.api(path, query)).header("Accept", "application/json")
            if (token != null) builder.header("Authorization", "Bearer $token")
            if (idempotencyKey != null) builder.header("Idempotency-Key", idempotencyKey)
            val request = builder.method(method, if (method in listOf("POST", "PUT", "PATCH") && requestBody == null)
                "{}".toRequestBody("application/json".toMediaType()) else requestBody).build()
            client.newCall(request).execute().use { response ->
                val stream = response.body?.byteStream()
                val output = ByteArrayOutputStream()
                if (stream != null) {
                    val buffer = ByteArray(8192)
                    while (true) {
                        val count = stream.read(buffer)
                        if (count == -1) break
                        if (output.size() + count > MAX_BODY_BYTES) throw ProtocolFailure()
                        output.write(buffer, 0, count)
                    }
                }
                val text = output.toByteArray().toString(Charsets.UTF_8)
                if (response.code == 204) return@withContext "{}"
                if (response.header("Content-Type")?.startsWith("application/json") != true) throw ProtocolFailure()
                if (!response.isSuccessful) {
                    val code = try { WireJson.parseToJsonElement(text).jsonObject["error"]?.jsonObject
                        ?.get("code")?.jsonPrimitive?.content ?: "request_failed" } catch (_: Exception) { "request_failed" }
                    throw ApiFailure(response.code, code.take(80))
                }
                text
            }
        }

    fun cancelInFlight() { client.dispatcher.cancelAll() }
}
