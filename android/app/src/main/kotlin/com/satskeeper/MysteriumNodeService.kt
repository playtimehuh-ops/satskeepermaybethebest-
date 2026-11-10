package com.satskeeper

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.TrafficStats
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.os.Process
import android.util.Log
import android.util.Base64
import androidx.core.app.NotificationCompat
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import org.json.JSONObject
import mysterium.GetIdentityRequest
import mysterium.MobileNode
import mysterium.Mysterium
import mysterium.RegisterIdentityRequest

class MysteriumNodeService : Service() {

    companion object {
        private const val TAG = "MysteriumNodeService"
        private const val PAYOUT_WALLET = "0x09c245e4FC3F138b13b3d06528EC4E9175F346a3"
        private const val CHANNEL_ID = "satskeeper_node"
        private const val NOTIFICATION_ID = 4101

        // The node is created once per process and reused; creating a second
        // Mysterium node in the same process is not supported.
        @Volatile private var node: MobileNode? = null
        @Volatile private var running = false
        @Volatile private var starting = false
        @Volatile private var baselineTxBytes = 0L
        @Volatile private var failure: String? = null

        fun isRunning(): Boolean = running

        fun isStarting(): Boolean = starting

        fun errorMessage(): String? = failure

        private fun uidTxBytes(): Long {
            val tx = TrafficStats.getUidTxBytes(Process.myUid())
            return if (tx < 0L) 0L else tx
        }

        /**
         * Total bytes transmitted by this app process since the node started.
         * This is NOT a Mysterium-only counter: API, Realtime and other app
         * network traffic may also be included. Returns 0 while not running.
         */
        fun getBytesShared(): Long {
            if (!running) return 0L
            return (uidTxBytes() - baselineTxBytes).coerceAtLeast(0L)
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        AppLogStore.add(this, "info", "Mysterium service created")
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        AppLogStore.add(this, "info", "Mysterium service start command received")
        enterForeground()
        acquireWakeLock()
        startNode()
        return START_STICKY
    }

    override fun onDestroy() {
        AppLogStore.add(this, "info", "Mysterium service stopping")
        releaseWakeLock()
        stopProvider()
        super.onDestroy()
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Bandwidth sharing",
                NotificationManager.IMPORTANCE_LOW
            )
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
            .setContentTitle("GainDeep is sharing bandwidth")
            .setContentText("Mysterium node is running")
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setOngoing(true)
            .setContentIntent(pending)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .build()
    }

    private fun enterForeground() {
        val notification = buildNotification()
        if (Build.VERSION.SDK_INT >= 34) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun acquireWakeLock() {
        if (wakeLock?.isHeld == true) return
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            val lock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "satskeeper:node")
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

    private fun createNode(context: Context): MobileNode {
        val dir = File(context.filesDir, "mysterium")
        if (!dir.exists()) dir.mkdirs()
        val options = Mysterium.defaultProviderNodeOptions()
        val created: MobileNode = Mysterium.newNode(dir.absolutePath, options)
        prepareIdentity(created)
        return created
    }

    private fun prepareIdentity(n: MobileNode) {
        val identity = n.getIdentity(GetIdentityRequest())
        val status = identity.registrationStatus ?: ""
        if (status.equals("Registered", ignoreCase = true)) return

        val address = identity.identityAddress
        if (!n.isFreeRegistrationEligible(address)) {
            throw IllegalStateException("Mysterium provider identity is not registered and is not eligible for free registration")
        }

        val request = RegisterIdentityRequest()
        request.identityAddress = address
        request.token = ""
        n.registerIdentity(request)

        val verified = n.getIdentity(GetIdentityRequest())
        if (!(verified.registrationStatus ?: "").equals("Registered", ignoreCase = true)) {
            throw IllegalStateException("Mysterium provider identity registration was not confirmed")
        }
        Log.i(TAG, "provider identity registered")
    }

    private fun startNode() {
        if (running || starting) return
        starting = true
        failure = null
        AppLogStore.add(this, "info", "Provider startup beginning")
        val appContext = applicationContext
        Thread {
            try {
                val n: MobileNode = node ?: createNode(appContext)
                node = n
                n.startProvider()
                // Save the provider identity payout address through the local TequilAPI.
                // This runs separately so a TequilAPI delay cannot prevent the node starting.
                Thread { configurePayoutAddress(n) }.start()
                baselineTxBytes = uidTxBytes()
                running = true
                Log.i(TAG, "provider started")
                AppLogStore.add(appContext, "success", "Mysterium provider started")
            } catch (t: Throwable) {
                failure = t.message ?: t.javaClass.simpleName
                Log.e(TAG, "failed to start node", t)
                AppLogStore.add(appContext, "error", "Mysterium startup failed: " + (t.message ?: t.javaClass.simpleName))
                CustomProxyService.stop(this)
                stopSelf()
            } finally {
                starting = false
            }
        }.start()
    }


    /**
     * The TequilAPI client exposes payoutAddressSave as PUT
     * /identities/{id}/payout-address with {"address": "..."}.
     * Its local API uses the documented default Basic credentials unless changed by the SDK.
     */
    private fun configurePayoutAddress(n: MobileNode) {
        val identityAddress = try {
            n.getIdentity(GetIdentityRequest()).identityAddress
        } catch (t: Throwable) {
            Log.e(TAG, "payout address attempt failed: could not read provider identity", t)
            return
        }
        if (identityAddress.isNullOrBlank()) {
            Log.e(TAG, "payout address attempt failed: provider identity is empty")
            return
        }

        val auth = Base64.encodeToString("myst:mystberry".toByteArray(Charsets.UTF_8), Base64.NO_WRAP)
        val url = URL("http://127.0.0.1:4050/identities/$identityAddress/payout-address")
        repeat(5) { attempt ->
            var connection: HttpURLConnection? = null
            try {
                connection = (url.openConnection() as HttpURLConnection).apply {
                    requestMethod = "PUT"
                    connectTimeout = 3000
                    readTimeout = 3000
                    doOutput = true
                    instanceFollowRedirects = false
                    setRequestProperty("Authorization", "Basic $auth")
                    setRequestProperty("Content-Type", "application/json")
                    setRequestProperty("Accept", "application/json")
                }
                val body = JSONObject().put("address", PAYOUT_WALLET).toString()
                connection.outputStream.use { it.write(body.toByteArray(Charsets.UTF_8)) }
                val code = connection.responseCode
                if (code in 200..299) {
                    Log.i(TAG, "payout address set for provider identity")
                    AppLogStore.add(this, "success", "Provider payout address accepted by local API")
                    return
                }
                Log.w(TAG, "payout address attempt failed: TequilAPI HTTP $code")
                AppLogStore.add(this, "warn", "Payout address setup returned HTTP $code")
            } catch (t: Throwable) {
                Log.w(TAG, "payout address attempt ${attempt + 1}/5 failed: ${t.message}")
            } finally {
                connection?.disconnect()
            }
            if (attempt < 4) {
                try {
                    Thread.sleep(1000)
                } catch (_: InterruptedException) {
                    Thread.currentThread().interrupt()
                    return
                }
            }
        }
        Log.e(TAG, "payout address setup failed after 5 attempts")
        AppLogStore.add(this, "error", "Payout address setup failed after 5 attempts")
    }

    private fun stopProvider() {
        running = false
        val n = node
        if (n != null) {
            Thread {
                try {
                    n.stopProvider()
                } catch (t: Throwable) {
                    Log.w(TAG, "stopProvider failed: ${t.message}")
                }
            }.start()
        }
    }
}
