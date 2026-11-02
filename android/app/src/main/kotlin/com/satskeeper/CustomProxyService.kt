package com.satskeeper

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.github.jan.supabase.SupabaseClient
import io.github.jan.supabase.createSupabaseClient
import io.github.jan.supabase.postgrest.Postgrest
import io.github.jan.supabase.realtime.Realtime
import io.github.jan.supabase.realtime.RealtimeChannel
import io.github.jan.supabase.realtime.broadcast
import io.github.jan.supabase.realtime.broadcastFlow
import io.github.jan.supabase.realtime.channel
import io.github.jan.supabase.realtime.realtime
import java.io.IOException
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeoutOrNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody

/**
 * Foreground service that turns this phone into a proxy exit for the Vercel gateway.
 *
 *  gateway --broadcast "request"--> proxy_device_{device_id} --> this service
 *  this service --broadcast "chunk" (seq/total)--> proxy_response_{request_id} --> gateway
 *
 * Both channels are PRIVATE. The phone joins with the user's own Supabase JWT, and the
 * Realtime policies in schema.sql only let it listen to its own device channel.
 * Start it with [start] and keep it fresh with [updateToken]; there is no sticky restart,
 * because the token is never written to disk.
 */
class CustomProxyService : Service() {

    private class Config(
        val supabaseUrl: String,
        val anonKey: String,
        val apiBase: String,
        val appKey: String,
        val deviceId: String
    )

    companion object {
        private const val TAG = "CustomProxyService"
        private const val CHANNEL_ID = "satskeeper_proxy"
        private const val NOTIFICATION_ID = 4102
        private const val MAX_CONCURRENT = 4
        private const val JOIN_TIMEOUT_MS = 5_000L
        private const val STALE_AFTER_MS = 45_000L

        const val EXTRA_SUPABASE_URL = "supabase_url"
        const val EXTRA_SUPABASE_ANON_KEY = "supabase_anon_key"
        const val EXTRA_API_BASE = "api_base"
        const val EXTRA_APP_KEY = "app_key"
        const val EXTRA_DEVICE_ID = "device_id"

        private val DEVICE_ID = Regex("^[A-Za-z0-9_-]{8,128}$")
        private val tokenFlow = MutableStateFlow("")
        private val transferred = AtomicLong(0L)
        @Volatile private var running = false
        @Volatile private var connected = false

        fun isRunning(): Boolean = running

        /** True while the private device channel is joined. */
        fun isConnected(): Boolean = connected

        /** Request + response body bytes delivered since the app process started. */
        fun bytesTransferred(): Long = transferred.get()

        /**
         * [apiBase] is the Vercel URL without a trailing slash, [appKey] the same APP_KEY the
         * other endpoints use, [accessToken] the user's current Supabase access token.
         */
        fun start(
            context: Context,
            supabaseUrl: String,
            anonKey: String,
            apiBase: String,
            appKey: String,
            deviceId: String,
            accessToken: String
        ) {
            tokenFlow.value = accessToken
            val intent = Intent(context, CustomProxyService::class.java)
                .putExtra(EXTRA_SUPABASE_URL, supabaseUrl)
                .putExtra(EXTRA_SUPABASE_ANON_KEY, anonKey)
                .putExtra(EXTRA_API_BASE, apiBase)
                .putExtra(EXTRA_APP_KEY, appKey)
                .putExtra(EXTRA_DEVICE_ID, deviceId)
            ContextCompat.startForegroundService(context, intent)
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, CustomProxyService::class.java))
        }

        /** Call every time the app refreshes the Supabase session (about once an hour). */
        fun updateToken(token: String) {
            if (token.isNotBlank()) tokenFlow.value = token
        }
    }

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var job: Job? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private val router = TrafficRouter()
    private val apiHttp = OkHttpClient.Builder().callTimeout(10, TimeUnit.SECONDS).build()

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        enterForeground() // must happen first, even when we are about to stop
        val config = configFrom(intent)
        if (config == null) {
            Log.w(TAG, "missing or invalid configuration, stopping")
            stopSelf()
            return START_NOT_STICKY
        }
        acquireWakeLock()
        if (job?.isActive != true) {
            running = true
            job = scope.launch { listenForever(config) }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        running = false
        connected = false
        job?.cancel()
        scope.cancel()
        releaseWakeLock()
        super.onDestroy()
    }

    private fun configFrom(intent: Intent?): Config? {
        if (intent == null) return null
        val url = intent.getStringExtra(EXTRA_SUPABASE_URL)?.trim()?.trimEnd('/') ?: return null
        val anon = intent.getStringExtra(EXTRA_SUPABASE_ANON_KEY)?.trim() ?: return null
        val api = intent.getStringExtra(EXTRA_API_BASE)?.trim()?.trimEnd('/') ?: return null
        val app = intent.getStringExtra(EXTRA_APP_KEY)?.trim() ?: return null
        val device = intent.getStringExtra(EXTRA_DEVICE_ID)?.trim() ?: return null
        if (!url.startsWith("https://") || !api.startsWith("https://")) return null
        if (anon.isEmpty() || app.isEmpty() || !DEVICE_ID.matches(device)) return null
        if (tokenFlow.value.isEmpty()) return null
        return Config(url, anon, api, app, device)
    }

    // ------------------------------------------------------------------ realtime

    /** Keeps one private-channel session alive; rebuilds the client with back-off when it dies. */
    private suspend fun listenForever(config: Config) {
        var backoffMs = 2_000L
        while (currentCoroutineContext().isActive) {
            val client = createSupabaseClient(config.supabaseUrl, config.anonKey) {
                install(Postgrest)
                install(Realtime)
            }
            try {
                session(client, config)
                backoffMs = 2_000L
            } catch (e: CancellationException) {
                throw e
            } catch (t: Throwable) {
                Log.w(TAG, "session ended: ${t.message}")
            } finally {
                connected = false
                withContext(NonCancellable) {
                    runCatching { client.realtime.removeAllChannels() }
                    runCatching { client.realtime.disconnect() }
                    runCatching { client.close() }
                }
            }
            delay(backoffMs)
            backoffMs = (backoffMs * 2).coerceAtMost(60_000L)
        }
    }

    private suspend fun session(client: SupabaseClient, config: Config) = coroutineScope {
        // The user's JWT is what the Realtime policies check (auth.uid() = device_id).
        client.realtime.setAuth(tokenFlow.value)
        val channel = client.realtime.channel("proxy_device_${config.deviceId}") { isPrivate = true }
        val requests = channel.broadcastFlow<JsonObject>("request")
        val gate = Semaphore(MAX_CONCURRENT)
        val dead = CompletableDeferred<Unit>()

        // Collect before joining so the first request can never be missed.
        launch { requests.collect { payload -> launch { handle(client, config, gate, payload) } } }

        val joined = withTimeoutOrNull(15_000L) {
            channel.subscribe(blockUntilSubscribed = true)
            true
        } ?: false
        if (!joined) throw IllegalStateException("could not join the device channel")
        connected = true
        Log.i(TAG, "listening for proxy requests")

        launch { tokenFlow.drop(1).collect { token -> runCatching { client.realtime.setAuth(token) } } }
        launch {
            channel.status.first { it == RealtimeChannel.Status.UNSUBSCRIBED }
            dead.complete(Unit)
        }
        launch {
            client.realtime.status.collectLatest { status ->
                if (status != Realtime.Status.CONNECTED) {
                    delay(STALE_AFTER_MS)
                    dead.complete(Unit)
                }
            }
        }
        try {
            dead.await()
        } finally {
            connected = false
            this.coroutineContext.cancelChildren()
        }
    }

    private suspend fun handle(client: SupabaseClient, config: Config, gate: Semaphore, payload: JsonObject) {
        val requestId = TrafficRouter.requestIdOf(payload) ?: return
        if (!gate.tryAcquire()) {
            reply(client, requestId, listOf(TrafficRouter.errorMessage(requestId, "busy")))
            return
        }
        try {
            val outcome = withContext(Dispatchers.IO) { router.execute(payload) }
            val delivered = reply(client, requestId, outcome.messages)
            if (delivered && outcome.bytes > 0L) {
                transferred.addAndGet(outcome.bytes)
                trackBytes(config, requestId, outcome.bytes)
            }
        } catch (e: CancellationException) {
            throw e
        } catch (t: Throwable) {
            Log.w(TAG, "request failed: ${t.message}")
        } finally {
            gate.release()
        }
    }

    /** Joins proxy_response_{request_id} and sends every chunk, in order, then leaves again. */
    private suspend fun reply(client: SupabaseClient, requestId: String, messages: List<JsonObject>): Boolean {
        if (messages.isEmpty()) return false
        val channel = client.realtime.channel("proxy_response_${config.deviceId}_$requestId") { isPrivate = true }
        try {
            val joined = withTimeoutOrNull(JOIN_TIMEOUT_MS) {
                channel.subscribe(blockUntilSubscribed = true)
                true
            } ?: false
            if (!joined) return false
            for (message in messages) channel.broadcast("chunk", message)
            return true
        } catch (e: CancellationException) {
            throw e
        } catch (t: Throwable) {
            Log.w(TAG, "could not send response: ${t.message}")
            return false
        } finally {
            withContext(NonCancellable) {
                runCatching { channel.unsubscribe() }
                runCatching { client.realtime.removeChannel(channel) }
            }
        }
    }

    // ------------------------------------------------------------------ accounting

    /** Reports the bytes of one delivered request to the existing Vercel endpoint (best effort, 2 tries). */
    private suspend fun trackBytes(config: Config, requestId: String, bytes: Long) = withContext(Dispatchers.IO) {
        val json = buildJsonObject {
            put("request_id", requestId)
            put("bytes", bytes)
        }.toString()
        repeat(2) { attempt ->
            val request = Request.Builder()
                .url("${config.apiBase}/api/track-custom-bytes")
                .header("x-app-key", config.appKey)
                .header("Authorization", "Bearer ${tokenFlow.value}")
                .post(json.toRequestBody("application/json".toMediaType()))
                .build()
            try {
                apiHttp.newCall(request).execute().use { response ->
                    if (response.isSuccessful) return@withContext
                }
            } catch (e: IOException) {
                Log.w(TAG, "track-custom-bytes failed: ${e.message}")
            }
            if (attempt == 0) delay(1_000L)
        }
    }

    // ------------------------------------------------------------------ foreground plumbing

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(CHANNEL_ID, "Traffic routing", NotificationManager.IMPORTANCE_LOW)
            val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val launch = packageManager.getLaunchIntentForPackage(packageName)
        val pending = if (launch != null) {
            PendingIntent.getActivity(
                this,
                0,
                launch,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
            )
        } else {
            null
        }
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("SatsKeeper is routing traffic")
            .setContentText("Proxy gateway is connected")
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setOngoing(true)
            .setContentIntent(pending)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }

    private fun enterForeground() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            val lock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "satskeeper:proxy")
            lock.setReferenceCounted(false)
            lock.acquire()
            wakeLock = lock
        } catch (t: Throwable) {
            Log.w(TAG, "wake lock unavailable: ${t.message}")
        }
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) wakeLock?.release()
        } catch (t: Throwable) {
            Log.w(TAG, "wake lock release failed: ${t.message}")
        }
        wakeLock = null
    }
}
