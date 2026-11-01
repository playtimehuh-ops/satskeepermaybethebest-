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
import androidx.core.app.NotificationCompat
import java.io.File
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
         * Real bytes transmitted by this app's UID since the node started.
         * The node runs inside this process, so relayed traffic is counted by
         * the kernel's per-UID counters. Returns 0 while the node is not running.
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
        createChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        enterForeground()
        acquireWakeLock()
        startNode()
        return START_STICKY
    }

    override fun onDestroy() {
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
            .setContentTitle("SatsKeeper is sharing bandwidth")
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
        try {
            val identity = n.getIdentity(GetIdentityRequest())
            val status = identity.registrationStatus ?: ""
            if (!status.equals("Registered", ignoreCase = true)) {
                val address = identity.identityAddress
                if (n.isFreeRegistrationEligible(address)) {
                    val request = RegisterIdentityRequest()
                    request.identityAddress = address
                    request.token = ""
                    n.registerIdentity(request)
                }
            }
        } catch (t: Throwable) {
            Log.w(TAG, "identity preparation failed: ${t.message}")
        }
    }

    private fun startNode() {
        if (running || starting) return
        starting = true
        failure = null
        val appContext = applicationContext
        Thread {
            try {
                val n: MobileNode = node ?: createNode(appContext)
                node = n
                n.startProvider()
                baselineTxBytes = uidTxBytes()
                running = true
                Log.i(TAG, "provider started")
            } catch (t: Throwable) {
                failure = t.message ?: t.javaClass.simpleName
                Log.e(TAG, "failed to start node", t)
                stopSelf()
            } finally {
                starting = false
            }
        }.start()
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
