package com.satskeeper

import android.util.Base64
import java.io.ByteArrayOutputStream
import java.io.IOException
import java.io.InputStream
import java.net.InetAddress
import java.io.InterruptedIOException
import java.net.Proxy
import java.net.UnknownHostException
import java.util.concurrent.TimeUnit
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.intOrNull
import kotlinx.serialization.json.put
import okhttp3.Dns
import okhttp3.HttpUrl
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.MediaType.Companion.toMediaTypeOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/**
 * Executes one proxy request on this phone and turns the answer into Base64 chunk messages.
 *
 * The phone never trusts the gateway: every target is checked here again, DNS is resolved
 * here, and nothing on the phone's own network (localhost, LAN, router, carrier-internal
 * ranges) can be reached. Redirects are NOT followed; the 3xx goes back to the buyer, who
 * asks again through the gateway, so every hop is checked.
 */
class TrafficRouter(private val http: OkHttpClient = buildClient()) {

    /** [messages] are the `chunk` broadcasts to send; [bytes] = request body + response body. */
    class Outcome(val messages: List<JsonObject>, val bytes: Long)

    fun execute(payload: JsonObject): Outcome {
        val id = requestIdOf(payload) ?: return Outcome(emptyList(), 0L)

        val method = (payload.str("method") ?: "GET").uppercase()
        val target = payload.str("target_url")
        val headers = parseHeaders(payload["headers"])
        if (method !in METHODS || target == null || headers == null) return fail(id, "bad_request")

        val encodedBody = payload.str("body_b64")
        val body: ByteArray? = if (encodedBody == null) {
            null
        } else {
            try {
                Base64.decode(encodedBody, Base64.DEFAULT)
            } catch (e: IllegalArgumentException) {
                return fail(id, "bad_request")
            }
        }
        if (body != null && (body.size > MAX_REQUEST_BODY || method == "GET" || method == "HEAD")) {
            return fail(id, "bad_request")
        }
        val maxBytes = minOf(payload.int("max_bytes") ?: MAX_RESPONSE_BYTES, MAX_RESPONSE_BYTES)

        val url = target.toHttpUrlOrNull()
        if (url == null || !isAllowedUrl(url)) return fail(id, "blocked_target")

        val request = try {
            buildRequest(url, method, headers, body)
        } catch (e: IllegalArgumentException) {
            return fail(id, "bad_request")
        }

        return try {
            http.newCall(request).execute().use { response ->
                val raw = readCapped(response.body?.byteStream(), maxBytes)
                    ?: return fail(id, "response_too_large")
                Outcome(
                    chunk(id, response.code, headersToJson(response.headers), raw),
                    (body?.size ?: 0).toLong() + raw.size
                )
            }
        } catch (e: UnknownHostException) {
            fail(id, if (e.message == BLOCKED) "blocked_target" else "upstream_failed")
        } catch (e: InterruptedIOException) {
            fail(id, "upstream_timeout")
        } catch (e: IOException) {
            fail(id, "upstream_failed")
        } catch (e: IllegalArgumentException) {
            fail(id, "bad_request")
        }
    }

    private fun fail(id: String, code: String): Outcome =
        Outcome(listOf(errorMessage(id, code)), 0L)

    private fun buildRequest(
        url: HttpUrl,
        method: String,
        headers: Map<String, String>,
        body: ByteArray?
    ): Request {
        val builder = Request.Builder().url(url)
        var contentType: String? = null
        for ((name, value) in headers) {
            if (name == "content-type") contentType = value else builder.header(name, value)
        }
        if ("user-agent" !in headers) builder.header("User-Agent", DEFAULT_USER_AGENT)
        val mediaType = contentType?.toMediaTypeOrNull()
        val needsBody = method == "POST" || method == "PUT" || method == "PATCH"
        val requestBody = when {
            body != null -> body.toRequestBody(mediaType)
            needsBody -> ByteArray(0).toRequestBody(mediaType)
            else -> null
        }
        builder.method(method, requestBody)
        return builder.build()
    }

    private fun readCapped(stream: InputStream?, max: Int): ByteArray? {
        if (stream == null) return ByteArray(0)
        return stream.use { input ->
            val out = ByteArrayOutputStream()
            val buffer = ByteArray(16 * 1024)
            var tooBig = false
            while (true) {
                val n = input.read(buffer)
                if (n < 0) break
                if (out.size() + n > max) {
                    tooBig = true
                    break
                }
                out.write(buffer, 0, n)
            }
            if (tooBig) null else out.toByteArray()
        }
    }

    private fun headersToJson(headers: okhttp3.Headers): JsonObject = buildJsonObject {
        var count = 0
        for (name in headers.names()) {
            val key = name.lowercase()
            if (key in DROP_RESPONSE_HEADERS || ++count > 50) continue
            val values = headers.values(name).map { it.take(8192) }
            if (key == "set-cookie") {
                put(key, JsonArray(values.map { JsonPrimitive(it) }))
            } else {
                put(key, values.joinToString(", "))
            }
        }
    }

    /**
     * Base64 -> chunks of at most [CHUNK_CHARS] characters (a multiple of 4, so every chunk is
     * valid Base64 on its own). Always at least one chunk. Status and headers ride on seq 0.
     */
    private fun chunk(id: String, status: Int, headers: JsonObject, raw: ByteArray): List<JsonObject> {
        val encoded = Base64.encodeToString(raw, Base64.NO_WRAP)
        val total = maxOf(1, (encoded.length + CHUNK_CHARS - 1) / CHUNK_CHARS)
        return List(total) { seq ->
            val from = seq * CHUNK_CHARS
            val data = encoded.substring(from, minOf(encoded.length, from + CHUNK_CHARS))
            buildJsonObject {
                put("request_id", id)
                put("seq", seq)
                put("total", total)
                if (seq == 0) {
                    put("status", status)
                    put("headers", headers)
                }
                put("data", data)
            }
        }
    }

    private fun parseHeaders(element: JsonElement?): Map<String, String>? {
        if (element == null || element is JsonNull) return emptyMap()
        val obj = element as? JsonObject ?: return null
        if (obj.size > MAX_HEADERS) return null
        val out = LinkedHashMap<String, String>()
        for ((key, v) in obj) {
            val name = key.lowercase()
            val value = (v as? JsonPrimitive)?.contentOrNull ?: return null
            if (!HEADER_NAME.matches(name)) return null
            if (value.length > 4096 || value.any { it == '\r' || it == '\n' || it == '\u0000' }) return null
            if (name !in DROP_REQUEST_HEADERS) out[name] = value
        }
        return out
    }

    companion object {
        /** Base64 characters per chunk. Under Supabase's 256 KB free-tier message limit. */
        const val CHUNK_CHARS = 200_000
        const val MAX_RESPONSE_BYTES = 2 * 1024 * 1024
        private const val MAX_REQUEST_BODY = 100 * 1024
        private const val MAX_HEADERS = 40
        private const val BLOCKED = "blocked_target"
        private const val DEFAULT_USER_AGENT =
            "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) " +
                "Chrome/124.0.0.0 Mobile Safari/537.36"

        private val REQUEST_ID = Regex("^[a-f0-9]{32}$")
        private val HEADER_NAME = Regex("^[a-z0-9!#$%&'*+.^_`|~-]{1,64}$")
        private val IPV4 = Regex("^\\d{1,3}(\\.\\d{1,3}){3}$")
        private val METHODS = setOf("GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS")
        private val DROP_REQUEST_HEADERS = setOf(
            "host", "connection", "content-length", "transfer-encoding", "te", "trailer",
            "upgrade", "keep-alive", "proxy-authorization", "proxy-connection",
            "accept-encoding", "expect"
        )
        private val DROP_RESPONSE_HEADERS = setOf(
            "connection", "keep-alive", "transfer-encoding", "content-length",
            "content-encoding", "upgrade", "proxy-authenticate", "te", "trailer"
        )
        private val BLOCKED_SUFFIXES = listOf(".localhost", ".local", ".internal", ".lan", ".home.arpa")

        fun requestIdOf(payload: JsonObject): String? =
            payload.str("request_id")?.takeIf { REQUEST_ID.matches(it) }

        fun errorMessage(requestId: String, code: String): JsonObject = buildJsonObject {
            put("request_id", requestId)
            put("error", code)
        }

        private fun JsonObject.str(key: String): String? {
            val p = this[key] as? JsonPrimitive ?: return null
            return if (p.isString) p.content else null
        }

        private fun JsonObject.int(key: String): Int? = (this[key] as? JsonPrimitive)?.intOrNull

        private fun buildClient(): OkHttpClient = OkHttpClient.Builder()
            .dns(SafeDns)
            .proxy(Proxy.NO_PROXY)
            .followRedirects(false)
            .followSslRedirects(false)
            .retryOnConnectionFailure(false)
            .connectTimeout(4, TimeUnit.SECONDS)
            .readTimeout(5, TimeUnit.SECONDS)
            .writeTimeout(4, TimeUnit.SECONDS)
            .callTimeout(6, TimeUnit.SECONDS)
            .build()

        /** True for loopback, LAN, link-local, carrier-grade NAT, multicast and other non-public addresses. */
        fun isBlockedAddress(a: InetAddress): Boolean {
            if (a.isAnyLocalAddress || a.isLoopbackAddress || a.isLinkLocalAddress ||
                a.isSiteLocalAddress || a.isMulticastAddress
            ) {
                return true
            }
            val b = a.address
            if (b.size == 4) {
                val o0 = b[0].toInt() and 0xFF
                val o1 = b[1].toInt() and 0xFF
                val o2 = b[2].toInt() and 0xFF
                return o0 == 0 ||
                    (o0 == 100 && o1 in 64..127) ||
                    (o0 == 192 && o1 == 0 && o2 == 0) ||
                    (o0 == 198 && (o1 == 18 || o1 == 19)) ||
                    o0 >= 240
            }
            return (b[0].toInt() and 0xFE) == 0xFC // fc00::/7 unique local
        }

        fun isAllowedUrl(url: HttpUrl): Boolean {
            if (url.scheme != "http" && url.scheme != "https") return false
            if (url.username.isNotEmpty() || url.password.isNotEmpty()) return false
            if (url.port != 80 && url.port != 443) return false
            val host = url.host.lowercase()
            if (host == "localhost" || BLOCKED_SUFFIXES.any { host.endsWith(it) }) return false
            if (IPV4.matches(host) || host.contains(':')) {
                val ip = try {
                    InetAddress.getByName(host) // a literal address: no DNS lookup happens
                } catch (e: Exception) {
                    return false
                }
                return !isBlockedAddress(ip)
            }
            return true
        }

        /** Resolves names with the system resolver but refuses any answer that touches a private address. */
        private object SafeDns : Dns {
            override fun lookup(hostname: String): List<InetAddress> {
                val all = Dns.SYSTEM.lookup(hostname)
                if (all.isEmpty() || all.any { isBlockedAddress(it) }) throw UnknownHostException(BLOCKED)
                return all
            }
        }
    }
}
