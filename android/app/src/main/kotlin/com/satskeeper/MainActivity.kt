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
    private val proxyChannelName = "com.satskeeper/proxy"

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
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, proxyChannelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "startProxy" -> {
                        try {
                            requestNotificationPermission()
                            val args = call.arguments as? Map<*, *>
                                ?: throw IllegalArgumentException("Missing proxy configuration")
                            fun required(key: String): String =
                                (args[key] as? String)?.takeIf { it.isNotBlank() }
                                    ?: throw IllegalArgumentException("Missing $key")
                            CustomProxyService.start(
                                this,
                                required("supabaseUrl"),
                                required("supabaseAnonKey"),
                                required("apiBase"),
                                required("appKey"),
                                required("deviceId"),
                                required("accessToken")
                            )
                            result.success(true)
                        } catch (t: Throwable) {
                            result.error("PROXY_START_FAILED", t.message, null)
                        }
                    }
                    "updateProxyToken" -> {
                        try {
                            CustomProxyService.updateToken(
                                (call.arguments as? String)?.takeIf { it.isNotBlank() }
                                    ?: throw IllegalArgumentException("Missing access token")
                            )
                            result.success(true)
                        } catch (t: Throwable) {
                            result.error("PROXY_TOKEN_FAILED", t.message, null)
                        }
                    }
                    "stopProxy" -> {
                        try {
                            CustomProxyService.stop(this)
                            result.success(true)
                        } catch (t: Throwable) {
                            result.error("PROXY_STOP_FAILED", t.message, null)
                        }
                    }
                    "proxyStatus" -> result.success(
                        mapOf(
                            "running" to CustomProxyService.isRunning(),
                            "connected" to CustomProxyService.isConnected(),
                            "bytesTransferred" to CustomProxyService.bytesTransferred()
                        )
                    )
                    else -> result.notImplemented()
                }
            }

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
