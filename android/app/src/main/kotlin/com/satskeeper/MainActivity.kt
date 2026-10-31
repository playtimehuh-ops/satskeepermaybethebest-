package com.satskeeper

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val channelName = "com.satskeeper/node"

    override fun onCreate(savedInstanceState: Bundle?) {
        // Gift-card codes are money: block screenshots, screen recording and the
        // task-switcher thumbnail.
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE
        )
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startNode" -> {
                        try {
                            requestNotificationPermission()
                            ContextCompat.startForegroundService(
                                this,
                                Intent(this, MysteriumNodeService::class.java)
                            )
                            result.success(true)
                        } catch (t: Throwable) {
                            result.error("START_FAILED", t.message, null)
                        }
                    }
                    "stopNode" -> {
                        try {
                            stopService(Intent(this, MysteriumNodeService::class.java))
                            result.success(true)
                        } catch (t: Throwable) {
                            result.error("STOP_FAILED", t.message, null)
                        }
                    }
                    "getBytesShared" -> result.success(MysteriumNodeService.getBytesShared())
                    "isRunning" -> result.success(MysteriumNodeService.isRunning())
                    "getStatus" -> result.success(
                        mapOf(
                            "running" to MysteriumNodeService.isRunning(),
                            "starting" to MysteriumNodeService.isStarting(),
                            "error" to MysteriumNodeService.errorMessage()
                        )
                    )
                    else -> result.notImplemented()
                }
            }
    }

    private fun requestNotificationPermission() {
        if (Build.VERSION.SDK_INT >= 33 &&
            checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), 1001)
        }
    }
}
