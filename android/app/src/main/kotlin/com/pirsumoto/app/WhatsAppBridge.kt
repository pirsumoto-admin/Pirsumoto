package com.pirsumoto.app

// =============================================================================
// [WHATSAPP-DISABLED] WhatsApp Bridge (Kotlin)
// =============================================================================
// This file contains the Android-side WhatsApp integration:
//   - WhatsAppBridgeController  : MethodChannel handler (called from Dart)
//   - WhatsAppBridgeEvents       : EventChannel sink (pushes events to Dart)
//   - WhatsAppDaemonService      : Foreground service watching WhatsApp media files
//   - WhatsAppNotificationListenerService : Intercepts WhatsApp notifications
//   - WhatsAppBootReceiver        : Restarts the daemon on boot
//   - WhatsAppAutoPublishStore    : Persists auto-publish vehicle data
//
// The entire bridge is NO LONGER ACTIVATED by the main app.
// MainActivity.kt no longer registers the MethodChannel or EventChannel.
// The file is preserved for reference and potential re-activation.
// =============================================================================

import android.app.Activity
import android.app.AppOpsManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.RemoteInput
import android.app.Service
import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.database.ContentObserver
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.os.FileObserver
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.provider.MediaStore
import android.provider.Settings
import android.service.notification.NotificationListenerService
import android.service.notification.StatusBarNotification
import android.util.Log
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale
import java.util.Date
import java.text.SimpleDateFormat
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.Executors
import kotlin.math.abs

class WhatsAppBridgeController(private val activity: Activity) {
    fun handle(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "configure" -> {
                val backendUrl = call.argument<String>("backendUrl")?.trim().orEmpty()
                WhatsAppBridgeConfig.update(
                    activity,
                    backendUrl = backendUrl,
                    deviceToken = call.argument<String>("deviceToken")?.trim().orEmpty(),
                    autoReplyEnabled = call.argument<Boolean>("autoReplyEnabled") ?: true,
                    watchBusinessWhatsApp = call.argument<Boolean>("watchBusinessWhatsApp") ?: true
                )
                result.success(true)
            }

            "start" -> {
                WhatsAppBridgeConfig.setDaemonEnabled(activity, true)
                val intent = Intent(activity, WhatsAppDaemonService::class.java)
                    .setAction(WhatsAppDaemonService.ACTION_START)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    activity.startForegroundService(intent)
                } else {
                    activity.startService(intent)
                }
                result.success(true)
            }

            "stop" -> {
                WhatsAppBridgeConfig.setDaemonEnabled(activity, false)
                activity.startService(
                    Intent(activity, WhatsAppDaemonService::class.java)
                        .setAction(WhatsAppDaemonService.ACTION_STOP)
                )
                result.success(true)
            }

            "getStatus" -> result.success(statusMap())

            "consumePendingAutoPublish" -> {
                result.success(WhatsAppAutoPublishStore.consume())
            }

            "sendReplyToWhatsApp" -> {
                val senderKey = call.argument<String>("senderKey")?.trim().orEmpty()
                val message = call.argument<String>("message")?.trim().orEmpty()
                if (senderKey.isBlank() || message.isBlank()) {
                    result.success(false)
                } else {
                    result.success(
                        WhatsAppBridgeProcessor.sendReplyFromApp(
                            activity.applicationContext,
                            senderKey,
                            message
                        )
                    )
                }
            }

            "launchAutoPublish" -> {
                val map = call.argument<Map<String, String>>("vehicleData") ?: emptyMap()
                if (map.isNotEmpty()) {
                    WhatsAppAutoPublishLauncher.launch(activity.applicationContext, map)
                    result.success(true)
                } else {
                    result.success(false)
                }
            }

            "scanRecentImages" -> {
                val count = call.argument<Int>("count") ?: 10
                val recentFiles = WhatsAppBridgeProcessor.findAllRecentImageFiles(
                    targetTimestamp = System.currentTimeMillis(),
                    expectedCount = count,
                    maxWindowMs = 30 * 60 * 1000L
                )
                result.success(recentFiles.map { it.absolutePath })
            }

            "openNotificationListenerSettings" -> {
                activity.startActivity(Intent(Settings.ACTION_NOTIFICATION_LISTENER_SETTINGS))
                result.success(true)
            }

            "requestRebindNotificationListener" -> {
                requestRebindNotificationListener()
                result.success(true)
            }

            "openAllFilesAccessSettings" -> {
                openAllFilesAccessSettings()
                result.success(true)
            }

            "openBatteryOptimizationSettings" -> {
                openBatteryOptimizationSettings()
                result.success(true)
            }

            "openAppNotificationSettings" -> {
                openAppNotificationSettings()
                result.success(true)
            }

            "openOverlayPermissionSettings" -> {
                openOverlayPermissionSettings()
                result.success(true)
            }

            "openFullScreenIntentSettings" -> {
                openFullScreenIntentSettings()
                result.success(true)
            }

            "openXiaomiAutostartSettings" -> {
                openXiaomiAutostartSettings()
                result.success(true)
            }

            "openXiaomiPermissionSettings" -> {
                openXiaomiPermissionSettings()
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }

    private fun statusMap(): Map<String, Any?> {
        return mapOf(
            "configured" to true,
            "running" to WhatsAppBridgeConfig.isDaemonEnabled(activity),
            "backendUrl" to WhatsAppBridgeConfig.backendUrl(activity),
            "autoReplyEnabled" to WhatsAppBridgeConfig.isAutoReplyEnabled(activity),
            "notificationListenerEnabled" to isNotificationListenerEnabled(activity),
            "notificationListenerConnected" to WhatsAppNotificationListenerService.isConnected,
            "allFilesAccessGranted" to hasAllFilesAccess(),
            "batteryOptimizationIgnored" to isIgnoringBatteryOptimizations(),
            "overlayPermissionGranted" to hasOverlayPermission(),
            "fullScreenIntentAllowed" to canUseFullScreenIntent(),
            "watchBusinessWhatsApp" to WhatsAppBridgeConfig.watchBusinessWhatsApp(activity),
            "isXiaomi" to isXiaomiDevice(),
            "xiaomiBackgroundPopupGranted" to isXiaomiBackgroundPopupPermissionGranted()
        )
    }

    private fun isNotificationListenerEnabled(context: Context): Boolean {
        val expected = ComponentName(context, WhatsAppNotificationListenerService::class.java)
        val enabled = Settings.Secure.getString(
            context.contentResolver,
            "enabled_notification_listeners"
        ) ?: return false

        return enabled.split(":").any { flattened ->
            val component = ComponentName.unflattenFromString(flattened)
            component?.packageName == expected.packageName &&
                component.className == expected.className
        }
    }

    private fun hasAllFilesAccess(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            Environment.isExternalStorageManager()
        } else {
            true
        }
    }

    private fun isIgnoringBatteryOptimizations(): Boolean {
        val powerManager = activity.getSystemService(Context.POWER_SERVICE) as PowerManager
        return powerManager.isIgnoringBatteryOptimizations(activity.packageName)
    }

    private fun hasOverlayPermission(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            Settings.canDrawOverlays(activity)
        } else {
            true
        }
    }

    private fun canUseFullScreenIntent(): Boolean {
        return if (Build.VERSION.SDK_INT >= 34) {
            val manager = activity.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.canUseFullScreenIntent()
        } else {
            true
        }
    }

    private fun openAllFilesAccessSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            try {
                activity.startActivity(
                    Intent(Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION).apply {
                        data = Uri.parse("package:${activity.packageName}")
                    }
                )
                return
            } catch (e: Exception) {
                Log.w(TAG, "Could not open app all-files settings", e)
            }
            activity.startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
        } else {
            activity.startActivity(
                Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:${activity.packageName}")
                }
            )
        }
    }

    private fun requestRebindNotificationListener() {
        if (WhatsAppNotificationListenerService.isConnected) {
            Log.d(TAG, "NotificationListenerService is ALREADY connected. Skipping requestRebind.")
            return
        }
        val component = ComponentName(activity, WhatsAppNotificationListenerService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                NotificationListenerService.requestRebind(component)
                Log.d(TAG, "Requested rebind for NotificationListenerService via requestRebind API")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to request rebind for NotificationListenerService via requestRebind API", e)
            }
        }

        // Programmatic reset trick (Component Toggle) for dead/zombie bindings (common on MIUI/Xiaomi)
        Handler(Looper.getMainLooper()).postDelayed({
            if (!WhatsAppNotificationListenerService.isConnected) {
                Log.w(TAG, "NotificationListenerService still not connected after requestRebind API. Executing PackageManager component toggle for zombie service recovery...")
                try {
                    val pm = activity.packageManager
                    pm.setComponentEnabledSetting(
                        component,
                        android.content.pm.PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
                        android.content.pm.PackageManager.DONT_KILL_APP
                    )
                    pm.setComponentEnabledSetting(
                        component,
                        android.content.pm.PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
                        android.content.pm.PackageManager.DONT_KILL_APP
                    )
                    Log.d(TAG, "Successfully toggled ComponentEnabledSetting for NotificationListenerService")
                } catch (e: Exception) {
                    Log.e(TAG, "Failed PackageManager component reset for NotificationListenerService", e)
                }
            }
        }, 400L)
    }

    private fun openBatteryOptimizationSettings() {
        if (isXiaomiDevice()) {
            try {
                val intent = Intent().apply {
                    setClassName("com.miui.powerkeeper", "com.miui.powerkeeper.ui.HiddenAppsConfigActivity")
                    putExtra("package_name", activity.packageName)
                    putExtra("package_label", activity.applicationInfo.loadLabel(activity.packageManager))
                }
                activity.startActivity(intent)
                return
            } catch (e: Exception) {
                Log.w(TAG, "Could not open MIUI powerkeeper settings", e)
            }
        }

        val powerManager = activity.getSystemService(Context.POWER_SERVICE) as PowerManager
        if (powerManager.isIgnoringBatteryOptimizations(activity.packageName)) return

        try {
            activity.startActivity(
                Intent(Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS).apply {
                    data = Uri.parse("package:${activity.packageName}")
                }
            )
        } catch (e: Exception) {
            Log.w(TAG, "Could not open battery optimization request", e)
            activity.startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
        }
    }

    private fun openAppNotificationSettings() {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
            }
        } else {
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                data = Uri.parse("package:${activity.packageName}")
            }
        }
        activity.startActivity(intent)
    }

    private fun openOverlayPermissionSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            activity.startActivity(
                Intent(Settings.ACTION_MANAGE_OVERLAY_PERMISSION).apply {
                    data = Uri.parse("package:${activity.packageName}")
                }
            )
        }
    }

    private fun openFullScreenIntentSettings() {
        if (Build.VERSION.SDK_INT >= 34) {
            try {
                activity.startActivity(
                    Intent("android.settings.MANAGE_APP_USE_FULL_SCREEN_INTENT").apply {
                        data = Uri.parse("package:${activity.packageName}")
                        putExtra(Settings.EXTRA_APP_PACKAGE, activity.packageName)
                    }
                )
                return
            } catch (e: Exception) {
                Log.w(TAG, "Could not open full-screen intent settings", e)
            }
        }
        openAppNotificationSettings()
    }

    private fun isXiaomiDevice(): Boolean {
        val manufacturer = Build.MANUFACTURER.lowercase(Locale.getDefault())
        val brand = Build.BRAND.lowercase(Locale.getDefault())
        return manufacturer.contains("xiaomi") || manufacturer.contains("redmi") || manufacturer.contains("poco") ||
                brand.contains("xiaomi") || brand.contains("redmi") || brand.contains("poco")
    }

    private fun isXiaomiBackgroundPopupPermissionGranted(): Boolean {
        if (!isXiaomiDevice()) return true
        return try {
            val appOps = activity.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
            val mode = if (Build.VERSION.SDK_INT >= 29) {
                appOps.unsafeCheckOpNoThrow(
                    "android:bg_start_activity",
                    android.os.Process.myUid(),
                    activity.packageName
                )
            } else {
                @Suppress("DEPRECATION")
                appOps.checkOpNoThrow(
                    "android:bg_start_activity",
                    android.os.Process.myUid(),
                    activity.packageName
                )
            }
            mode == AppOpsManager.MODE_ALLOWED
        } catch (e: Exception) {
            try {
                val appOps = activity.getSystemService(Context.APP_OPS_SERVICE) as AppOpsManager
                val method = appOps.javaClass.getMethod(
                    "checkOpNoThrow",
                    Int::class.javaPrimitiveType,
                    Int::class.javaPrimitiveType,
                    String::class.java
                )
                val mode = method.invoke(appOps, 10021, android.os.Process.myUid(), activity.packageName) as Int
                mode == AppOpsManager.MODE_ALLOWED
            } catch (e2: Exception) {
                Log.w(TAG, "Could not check Xiaomi background popup permission", e2)
                true
            }
        }
    }

    private fun openXiaomiAutostartSettings() {
        try {
            val intent = Intent().apply {
                setClassName(
                    "com.miui.securitycenter",
                    "com.miui.permcenter.autostart.AutoStartManagementActivity"
                )
            }
            activity.startActivity(intent)
            return
        } catch (e: Exception) {
            Log.w(TAG, "Could not open MIUI autostart settings", e)
            openAppNotificationSettings()
        }
    }

    private fun openXiaomiPermissionSettings() {
        try {
            val intent = Intent("miui.intent.action.APP_PERM_EDITOR").apply {
                setClassName(
                    "com.miui.securitycenter",
                    "com.miui.permcenter.permissions.PermissionsEditorActivity"
                )
                putExtra("extra_pkgname", activity.packageName)
            }
            activity.startActivity(intent)
            return
        } catch (e: Exception) {
            Log.w(TAG, "Could not open MIUI perm editor, falling back to app details", e)
            try {
                val intent = Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS).apply {
                    data = Uri.parse("package:${activity.packageName}")
                }
                activity.startActivity(intent)
            } catch (e2: Exception) {
                Log.e(TAG, "Could not open app details settings", e2)
            }
        }
    }

    companion object {
        private const val TAG = "WA-BridgeController"
    }
}

object WhatsAppBridgeEvents {
    private const val TAG = "WA-BridgeEvents"
    private const val MAX_PENDING_EVENTS = 50
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null
    private val pendingEvents = mutableListOf<Map<String, Any?>>()

    fun attach(sink: EventChannel.EventSink?) {
        mainHandler.post {
            eventSink = sink
            if (sink != null) {
                flushPendingEventsLocked()
            }
        }
    }

    fun hasActiveSink(): Boolean {
        return eventSink != null
    }

    fun detach() {
        mainHandler.post {
            eventSink = null
        }
    }

    fun emit(name: String, data: Map<String, Any?> = emptyMap()) {
        mainHandler.post {
            val payload = mapOf(
                "event" to name,
                "timestamp" to System.currentTimeMillis(),
                "data" to data
            )
            val sink = eventSink
            if (sink != null) {
                try {
                    sink.success(payload)
                } catch (e: Exception) {
                    Log.w(TAG, "Event delivery failed (FlutterJNI detached?), queuing event: ${e.message}")
                    eventSink = null
                    queueEventLocked(payload)
                }
            } else {
                Log.d(TAG, "No active EventSink, queuing event '$name'")
                queueEventLocked(payload)
            }
        }
    }

    private fun queueEventLocked(payload: Map<String, Any?>) {
        if (pendingEvents.size >= MAX_PENDING_EVENTS) {
            pendingEvents.removeAt(0)
        }
        pendingEvents.add(payload)
    }

    private fun flushPendingEventsLocked() {
        val sink = eventSink ?: return
        if (pendingEvents.isEmpty()) return
        Log.d(TAG, "Flushing ${pendingEvents.size} pending bridge events to Flutter")
        val eventsToFlush = pendingEvents.toList()
        pendingEvents.clear()
        for (payload in eventsToFlush) {
            try {
                sink.success(payload)
            } catch (e: Exception) {
                Log.w(TAG, "Failed to flush pending event to Flutter: ${e.message}")
                eventSink = null
                queueEventLocked(payload)
                break
            }
        }
    }
}

object WhatsAppAutoPublishStore {
    const val ACTION_AUTO_PUBLISH = "com.pirsumoto.app.ACTION_AUTO_PUBLISH_FROM_WHATSAPP"
    private const val EXTRA_VEHICLE_DATA = "vehicleDataJson"

    @Volatile
    private var pendingVehicleData: Map<String, String>? = null

    fun set(vehicleData: Map<String, String>) {
        pendingVehicleData = vehicleData.toMap()
    }

    fun captureIntent(intent: Intent?): Boolean {
        if (intent?.action != ACTION_AUTO_PUBLISH) return false
        val jsonText = intent.getStringExtra(EXTRA_VEHICLE_DATA).orEmpty()
        val parsed = parseVehicleData(jsonText)
        if (parsed.isNotEmpty()) {
            set(parsed)
        }
        return parsed.isNotEmpty()
    }

    fun consume(): Map<String, String> {
        val data = pendingVehicleData ?: return emptyMap()
        pendingVehicleData = null
        return data
    }

    fun intent(context: Context, vehicleData: Map<String, String>): Intent {
        return Intent(context, MainActivity::class.java)
            .setAction(ACTION_AUTO_PUBLISH)
            .putExtra(EXTRA_VEHICLE_DATA, toJson(vehicleData))
            .addFlags(
                Intent.FLAG_ACTIVITY_NEW_TASK or
                    Intent.FLAG_ACTIVITY_CLEAR_TOP or
                    Intent.FLAG_ACTIVITY_SINGLE_TOP
            )
    }

    private fun toJson(vehicleData: Map<String, String>): String {
        val json = JSONObject()
        vehicleData.forEach { (key, value) -> json.put(key, value) }
        return json.toString()
    }

    private fun parseVehicleData(jsonText: String): Map<String, String> {
        if (jsonText.isBlank()) return emptyMap()
        return try {
            val json = JSONObject(jsonText)
            val result = linkedMapOf<String, String>()
            json.keys().forEach { key ->
                val value = json.opt(key)?.toString()?.trim()
                if (!value.isNullOrBlank() && value != "null") {
                    result[key] = value
                }
            }
            result
        } catch (e: Exception) {
            Log.e("WA-AutoPublish", "Failed to parse auto-publish vehicle data", e)
            emptyMap()
        }
    }
}

object WhatsAppAutoPublishLauncher {
    private const val TAG = "WA-AutoPublish"
    private const val CHANNEL_ID = "pirsumoto_whatsapp_auto_publish_v2"
    private const val NOTIFICATION_ID = 41902
    private val mainHandler = Handler(Looper.getMainLooper())

    fun launch(context: Context, vehicleData: Map<String, String>) {
        if (vehicleData.isEmpty()) return
        val appContext = context.applicationContext
        WhatsAppAutoPublishStore.set(vehicleData)
        wakeScreen(appContext)
        val intent = WhatsAppAutoPublishStore.intent(appContext, vehicleData)
        postFullScreenLaunchNotification(appContext, intent)

        mainHandler.post {
            try {
                appContext.startActivity(intent)
                WhatsAppBridgeEvents.emit(
                    "autoPublishLaunchRequested",
                    mapOf("vehicleData" to vehicleData)
                )
            } catch (e: Exception) {
                Log.e(TAG, "Failed to launch app for WhatsApp auto publish", e)
                WhatsAppBridgeEvents.emit(
                    "error",
                    mapOf("message" to "Failed to launch app for WhatsApp auto publish")
                )
            }
        }
    }

    @Suppress("DEPRECATION")
    private fun wakeScreen(context: Context) {
        try {
            val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            val wakeLock = powerManager.newWakeLock(
                PowerManager.SCREEN_BRIGHT_WAKE_LOCK or
                    PowerManager.ACQUIRE_CAUSES_WAKEUP or
                    PowerManager.ON_AFTER_RELEASE,
                "Pirsumoto:WhatsAppAutoPublish"
            )
            wakeLock.acquire(10_000L)
        } catch (e: Exception) {
            Log.w(TAG, "Could not wake screen for auto publish", e)
        }
    }

    private fun postFullScreenLaunchNotification(context: Context, intent: Intent) {
        try {
            val manager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val channel = NotificationChannel(
                    CHANNEL_ID,
                    "Pirsumoto WhatsApp auto publish",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description = "Starts Yad2 automation when WhatsApp vehicle data is complete"
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                }
                manager.createNotificationChannel(channel)
            }

            val pendingIntent = PendingIntent.getActivity(
                context,
                System.currentTimeMillis().toInt(),
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Notification.Builder(context, CHANNEL_ID)
            } else {
                @Suppress("DEPRECATION")
                Notification.Builder(context)
            }

            @Suppress("DEPRECATION")
            val notification = builder
                .setContentTitle("Pirsumoto")
                .setContentText("מתחיל פרסום ביד2")
                .setSmallIcon(context.applicationInfo.icon)
                .setContentIntent(pendingIntent)
                .setFullScreenIntent(pendingIntent, true)
                .setCategory(Notification.CATEGORY_ALARM)
                .setPriority(Notification.PRIORITY_HIGH)
                .setVisibility(Notification.VISIBILITY_PUBLIC)
                .setAutoCancel(true)
                .addAction(
                    Notification.Action.Builder(
                        context.applicationInfo.icon,
                        "פרסום",
                        pendingIntent
                    ).build()
                )
                .apply {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        setTimeoutAfter(15_000L)
                    }
                }
                .build()

            manager.notify(NOTIFICATION_ID, notification)
        } catch (e: Exception) {
            Log.w(TAG, "Could not post auto-publish launch notification", e)
        }
    }
}

object WhatsAppBridgeConfig {
    private const val PREFS = "pirsumoto_whatsapp_bridge"
    private const val KEY_BACKEND_URL = "backend_url"
    private const val KEY_DEVICE_TOKEN = "device_token"
    private const val KEY_AUTO_REPLY = "auto_reply_enabled"
    private const val KEY_DAEMON_ENABLED = "daemon_enabled"
    private const val KEY_WATCH_BUSINESS = "watch_business_whatsapp"

    fun update(
        context: Context,
        backendUrl: String,
        deviceToken: String,
        autoReplyEnabled: Boolean,
        watchBusinessWhatsApp: Boolean
    ) {
        prefs(context).edit()
            .putString(KEY_BACKEND_URL, backendUrl)
            .putString(KEY_DEVICE_TOKEN, deviceToken)
            .putBoolean(KEY_AUTO_REPLY, autoReplyEnabled)
            .putBoolean(KEY_WATCH_BUSINESS, watchBusinessWhatsApp)
            .apply()
    }

    fun backendUrl(context: Context): String = prefs(context).getString(KEY_BACKEND_URL, "").orEmpty()
    fun deviceToken(context: Context): String = prefs(context).getString(KEY_DEVICE_TOKEN, "").orEmpty()
    fun isAutoReplyEnabled(context: Context): Boolean = prefs(context).getBoolean(KEY_AUTO_REPLY, true)
    fun watchBusinessWhatsApp(context: Context): Boolean = prefs(context).getBoolean(KEY_WATCH_BUSINESS, true)
    fun isDaemonEnabled(context: Context): Boolean = prefs(context).getBoolean(KEY_DAEMON_ENABLED, false)

    fun setDaemonEnabled(context: Context, enabled: Boolean) {
        prefs(context).edit().putBoolean(KEY_DAEMON_ENABLED, enabled).apply()
    }

    private fun prefs(context: Context): SharedPreferences {
        return context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    }
}

class WhatsAppDaemonService : Service() {
    private var voiceNoteObserver: WhatsAppVoiceNoteObserver? = null
    private var imageObserver: WhatsAppImageObserver? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopVoiceObserver()
            stopImageObserver()
            stopForeground(STOP_FOREGROUND_REMOVE_COMPAT)
            stopSelf()
            return START_NOT_STICKY
        }

        if (intent?.action == ACTION_BRING_TO_FOREGROUND) {
            Log.i(TAG, "ACTION_BRING_TO_FOREGROUND received in WhatsAppDaemonService")
            MainActivity.bringToForeground(this)
            return START_STICKY
        }

        startForeground(NOTIFICATION_ID, buildNotification())
        startVoiceObserver()
        startImageObserver()
        WhatsAppBridgeEvents.emit("daemonStarted")
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        Log.w(TAG, "onTaskRemoved triggered (app swiped away/killed). Scheduling daemon service auto-restart...")
        if (WhatsAppBridgeConfig.isDaemonEnabled(this)) {
            scheduleDaemonRestart(applicationContext, 1000L)
        }
    }

    override fun onDestroy() {
        stopVoiceObserver()
        stopImageObserver()
        WhatsAppBridgeEvents.emit("daemonStopped")
        if (WhatsAppBridgeConfig.isDaemonEnabled(this)) {
            Log.w(TAG, "WhatsAppDaemonService onDestroy called while daemon enabled! Scheduling auto-restart...")
            scheduleDaemonRestart(applicationContext, 2000L)
        }
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun scheduleDaemonRestart(context: Context, delayMs: Long = 1000L) {
        try {
            val intent = Intent(context, WhatsAppBootReceiver::class.java).apply {
                action = ACTION_RESTART_DAEMON
            }
            val pendingIntent = PendingIntent.getBroadcast(
                context,
                1099,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            val alarmManager = context.getSystemService(Context.ALARM_SERVICE) as android.app.AlarmManager
            val triggerAt = android.os.SystemClock.elapsedRealtime() + delayMs
            alarmManager.setAndAllowWhileIdle(
                android.app.AlarmManager.ELAPSED_REALTIME_WAKEUP,
                triggerAt,
                pendingIntent
            )
            Log.d(TAG, "Scheduled daemon restart alarm in ${delayMs}ms")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to schedule daemon service restart alarm", e)
        }
    }

    private fun startVoiceObserver() {
        if (voiceNoteObserver != null) return

        voiceNoteObserver = WhatsAppVoiceNoteObserver(applicationContext) { file ->
            WhatsAppBridgeProcessor.onVoiceNoteFile(applicationContext, file)
        }

        try {
            voiceNoteObserver?.start()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start WhatsApp voice-note observer", e)
            WhatsAppBridgeEvents.emit("error", mapOf("message" to "Failed to watch WhatsApp voice notes"))
        }
    }

    private fun stopVoiceObserver() {
        voiceNoteObserver?.stop()
        voiceNoteObserver = null
    }

    private fun startImageObserver() {
        if (imageObserver != null) return

        imageObserver = WhatsAppImageObserver(applicationContext) { file ->
            WhatsAppBridgeProcessor.onImageFile(applicationContext, file)
        }

        try {
            imageObserver?.start()
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start WhatsApp image observer", e)
            WhatsAppBridgeEvents.emit("error", mapOf("message" to "Failed to watch WhatsApp images"))
        }
    }

    private fun stopImageObserver() {
        imageObserver?.stop()
        imageObserver = null
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Pirsumoto WhatsApp bridge",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Keeps the WhatsApp message bridge active"
        }

        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        val openAppIntent = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }

        return builder
            .setContentTitle("Pirsumoto WhatsApp bridge")
            .setContentText("Listening for dealership WhatsApp updates")
            .setSmallIcon(applicationInfo.icon)
            .setContentIntent(openAppIntent)
            .setOngoing(true)
            .build()
    }

    companion object {
        const val ACTION_START = "com.pirsumoto.app.whatsapp_bridge.START"
        const val ACTION_STOP = "com.pirsumoto.app.whatsapp_bridge.STOP"
        const val ACTION_RESTART_DAEMON = "com.pirsumoto.app.whatsapp_bridge.RESTART_DAEMON"
        const val ACTION_BRING_TO_FOREGROUND = "com.pirsumoto.app.whatsapp_bridge.BRING_TO_FOREGROUND"
        private const val CHANNEL_ID = "pirsumoto_whatsapp_bridge"
        private const val NOTIFICATION_ID = 4172
        private const val TAG = "WA-Daemon"

        private val STOP_FOREGROUND_REMOVE_COMPAT =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) Service.STOP_FOREGROUND_REMOVE else 1

        fun bringAppToForeground(context: Context) {
            try {
                val intent = Intent(context, WhatsAppDaemonService::class.java).apply {
                    action = ACTION_BRING_TO_FOREGROUND
                }
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
            } catch (e: Exception) {
                Log.e(TAG, "Failed to send ACTION_BRING_TO_FOREGROUND to WhatsAppDaemonService: $e")
                MainActivity.bringToForeground(context)
            }
        }
    }
}

class WhatsAppBootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        Log.d("WA-BootReceiver", "Received broadcast action: ${intent.action}")
        if (!WhatsAppBridgeConfig.isDaemonEnabled(context)) return

        val serviceIntent = Intent(context, WhatsAppDaemonService::class.java)
            .setAction(WhatsAppDaemonService.ACTION_START)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
            Log.d("WA-BootReceiver", "Successfully started/restarted WhatsAppDaemonService")
        } catch (e: Exception) {
            Log.e("WA-BootReceiver", "Failed to start WhatsAppDaemonService from BootReceiver", e)
        }
    }
}

object WhatsAppImageObserverManager {
    private var observer: WhatsAppImageObserver? = null

    @Synchronized
    fun ensureStarted(context: Context) {
        if (observer != null) return
        Log.d("WA-ImageObserverMgr", "Ensuring WhatsAppImageObserver is STARTED...")
        observer = WhatsAppImageObserver(context.applicationContext) { file ->
            Log.d("WA-ImageObserverMgr", "Image file detected on disk: ${file.absolutePath}")
            WhatsAppBridgeProcessor.onImageFile(context.applicationContext, file)
        }
        try {
            observer?.start()
            Log.d("WA-ImageObserverMgr", "WhatsAppImageObserver started successfully!")
        } catch (e: Exception) {
            Log.e("WA-ImageObserverMgr", "Failed to start WhatsAppImageObserver", e)
        }
    }
}

class WhatsAppNotificationListenerService : NotificationListenerService() {
    override fun onListenerConnected() {
        super.onListenerConnected()
        isConnected = true
        Log.d(TAG, "NotificationListenerService CONNECTED to Android system")
        WhatsAppImageObserverManager.ensureStarted(applicationContext)
        WhatsAppBridgeEvents.emit("notificationListenerConnected")
    }

    override fun onListenerDisconnected() {
        super.onListenerDisconnected()
        isConnected = false
        Log.w(TAG, "NotificationListenerService DISCONNECTED from Android system!")
        WhatsAppBridgeEvents.emit("notificationListenerDisconnected")
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                requestRebind(ComponentName(this, WhatsAppNotificationListenerService::class.java))
            } catch (e: Exception) {
                Log.e(TAG, "Failed to auto-rebind NotificationListenerService", e)
            }
        }
    }

    override fun onNotificationPosted(sbn: StatusBarNotification?) {
        if (sbn == null) return
        if (!isSupportedWhatsAppPackage(sbn.packageName)) return

        WhatsAppImageObserverManager.ensureStarted(applicationContext)
        val notification = sbn.notification ?: return
        val extras = notification.extras
        val title = extras?.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim().orEmpty()
        val text = extras?.getCharSequence(Notification.EXTRA_TEXT)?.toString()?.trim().orEmpty()
        Log.d(TAG, "[NOTIFICATION-RECEIVED] Package: ${sbn.packageName} | Title: '$title' | Text: '$text'")

        val replyAction = WhatsAppBridgeProcessor.findDirectReplyAction(notification)
        if (replyAction != null) {
            Log.d(TAG, "[REPLY-ACTION-FOUND] Direct reply action captured for notification: '$title'")
            if (title.isNotEmpty()) {
                WhatsAppBridgeProcessor.updateReplyAction(title, replyAction)
            }
        } else {
            Log.w(TAG, "[REPLY-ACTION-MISSING] No direct reply action in notification for: '$title'")
        }

        val message = WhatsAppBridgeProcessor.fromNotification(sbn, notification)
        if (message == null) {
            Log.d(TAG, "[NOTIFICATION-IGNORED] Notification ignored (not a user message or non-message notification)")
            return
        }

        Log.d(TAG, "[MESSAGE-DISPATCHING] Sender: '${message.senderName}' | Type: ${message.type} | Text: '${message.text}'")
        WhatsAppBridgeProcessor.onNotification(applicationContext, message, replyAction)
    }

    private fun isSupportedWhatsAppPackage(packageName: String): Boolean {
        if (packageName == "com.whatsapp") return true
        return packageName == "com.whatsapp.w4b" &&
            WhatsAppBridgeConfig.watchBusinessWhatsApp(applicationContext)
    }

    companion object {
        private const val TAG = "WA-Listener"
        @Volatile
        var isConnected: Boolean = false
    }
}

class WhatsAppVoiceNoteObserver(
    private val context: Context,
    private val onReady: (File) -> Unit
) {
    private val observers = mutableMapOf<String, FileObserver>()
    private val mainHandler = Handler(Looper.getMainLooper())

    fun start() {
        val roots = voiceNoteRoots()
        roots.forEach { root ->
            if (root.exists()) {
                watchRecursively(root)
            } else {
                Log.w(TAG, "WhatsApp voice-note root does not exist yet: ${root.absolutePath}")
            }
        }

        WhatsAppBridgeEvents.emit(
            "voiceObserverStarted",
            mapOf("watchedDirectories" to observers.size)
        )
    }

    fun stop() {
        observers.values.forEach { it.stopWatching() }
        observers.clear()
    }

    private fun voiceNoteRoots(): List<File> {
        val external = Environment.getExternalStorageDirectory()
        return listOf(
            File(external, "Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Voice Notes"),
            File(external, "Android/media/com.whatsapp.w4b/WhatsApp Business/Media/WhatsApp Business Voice Notes"),
            File(external, "WhatsApp/Media/WhatsApp Voice Notes")
        )
    }

    private fun watchRecursively(root: File) {
        if (!root.isDirectory || observers.containsKey(root.absolutePath)) return
        root.walkTopDown()
            .filter { it.isDirectory }
            .forEach { directory -> watchDirectory(directory) }
    }

    @Suppress("DEPRECATION")
    private fun watchDirectory(directory: File) {
        if (observers.containsKey(directory.absolutePath)) return

        val observer = object : FileObserver(directory.absolutePath, FILE_EVENTS) {
            override fun onEvent(event: Int, path: String?) {
                if (path.isNullOrBlank()) return
                val cleanEvent = event and FileObserver.ALL_EVENTS
                val child = File(directory, path)

                if ((cleanEvent and FileObserver.CREATE) != 0 && child.isDirectory) {
                    mainHandler.postDelayed({ watchRecursively(child) }, 500L)
                    return
                }

                if (!isVoiceNoteFile(child)) return
                mainHandler.postDelayed({ waitUntilStable(child) }, 1200L)
            }
        }

        observer.startWatching()
        observers[directory.absolutePath] = observer
    }

    private fun waitUntilStable(file: File) {
        if (!file.exists() || !file.canRead()) return

        val firstLength = file.length()
        mainHandler.postDelayed({
            if (file.exists() && file.canRead() && file.length() == firstLength && file.length() > 0L) {
                onReady(file)
            }
        }, 800L)
    }

    private fun isVoiceNoteFile(file: File): Boolean {
        val name = file.name.lowercase()
        return name.endsWith(".ogg") || name.endsWith(".opus")
    }

    companion object {
        private const val TAG = "WA-VoiceObserver"
        private const val FILE_EVENTS =
            FileObserver.CLOSE_WRITE or FileObserver.MOVED_TO or FileObserver.CREATE
    }
}

class WhatsAppImageObserver(
    private val context: Context,
    private val onReady: (File) -> Unit
) {
    private val observers = mutableMapOf<String, FileObserver>()
    private val mainHandler = Handler(Looper.getMainLooper())
    private var mediaContentObserver: ContentObserver? = null

    fun start() {
        startFileObservers()
        startMediaStoreObserver()
    }

    private fun startFileObservers() {
        val roots = imageRoots()
        var watchedCount = 0
        roots.forEach { root ->
            if (root.exists()) {
                Log.d(TAG, "Watching image root: ${root.absolutePath}")
                watchRecursively(root)
                watchedCount++
            } else {
                Log.w(TAG, "WhatsApp image root does not exist yet: ${root.absolutePath}")
            }
        }
        Log.d(TAG, "Started watching $watchedCount roots and ${observers.size} directories total")

        WhatsAppBridgeEvents.emit(
            "imageObserverStarted",
            mapOf("watchedDirectories" to observers.size)
        )
    }

    private fun startMediaStoreObserver() {
        try {
            mediaContentObserver = object : ContentObserver(mainHandler) {
                override fun onChange(selfChange: Boolean, uri: Uri?) {
                    super.onChange(selfChange, uri)
                    checkLatestMediaStoreImage()
                }
            }
            context.contentResolver.registerContentObserver(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                true,
                mediaContentObserver!!
            )
            Log.d(TAG, "MediaStore ContentObserver registered for Xiaomi image detection")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to register MediaStore ContentObserver", e)
        }
    }

    private fun checkLatestMediaStoreImage() {
        try {
            val projection = arrayOf(
                MediaStore.Images.Media._ID,
                MediaStore.Images.Media.DATA,
                MediaStore.Images.Media.DATE_MODIFIED,
                MediaStore.Images.Media.DATE_ADDED
            )
            val sortOrder = "${MediaStore.Images.Media.DATE_ADDED} DESC, ${MediaStore.Images.Media._ID} DESC"
            context.contentResolver.query(
                MediaStore.Images.Media.EXTERNAL_CONTENT_URI,
                projection,
                null,
                null,
                sortOrder
            )?.use { cursor ->
                var count = 0
                val dataIndex = cursor.getColumnIndex(MediaStore.Images.Media.DATA)
                val dateAddedIndex = cursor.getColumnIndex(MediaStore.Images.Media.DATE_ADDED)
                val dateModIndex = cursor.getColumnIndex(MediaStore.Images.Media.DATE_MODIFIED)
                val nowSec = System.currentTimeMillis() / 1000L

                while (cursor.moveToNext() && count < 15) {
                    count++
                    if (dataIndex != -1) {
                        val filePath = cursor.getString(dataIndex)
                        val dateAddedSec = if (dateAddedIndex != -1) cursor.getLong(dateAddedIndex) else 0L
                        val dateModSec = if (dateModIndex != -1) cursor.getLong(dateModIndex) else 0L
                        val maxTimeSec = maxOf(dateAddedSec, dateModSec)

                        if (!filePath.isNullOrBlank() && (maxTimeSec == 0L || nowSec - maxTimeSec <= 600L)) {
                            val file = File(filePath)
                            if (file.exists() && isImageFile(file) && isWhatsAppOrGalleryImage(filePath)) {
                                Log.d(TAG, "Recent MediaStore image detected: ${file.absolutePath}")
                                waitUntilStable(file)
                            }
                        }
                    }
                }
            }
        } catch (e: Exception) {
            Log.w(TAG, "Error querying MediaStore for recent image", e)
        }
    }

    private fun isWhatsAppOrGalleryImage(path: String): Boolean {
        val lower = path.lowercase(Locale.getDefault())
        return lower.contains("whatsapp") ||
                lower.contains("com.whatsapp") ||
                lower.contains("pictures") ||
                lower.contains("dcim")
    }

    fun stop() {
        mediaContentObserver?.let {
            try {
                context.contentResolver.unregisterContentObserver(it)
            } catch (e: Exception) {
                Log.w(TAG, "Error unregistering ContentObserver", e)
            }
        }
        mediaContentObserver = null

        observers.values.forEach { it.stopWatching() }
        observers.clear()
    }

    private fun imageRoots(): List<File> {
        val external = Environment.getExternalStorageDirectory()
        return listOf(
            File(external, "Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images"),
            File(external, "Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images/Private"),
            File(external, "Android/media/com.whatsapp.w4b/WhatsApp Business/Media/WhatsApp Business Images"),
            File(external, "Android/media/com.whatsapp.w4b/WhatsApp Business/Media/WhatsApp Business Images/Private"),
            File(external, "WhatsApp/Media/WhatsApp Images"),
            File(external, "WhatsApp/Media/WhatsApp Images/Private"),
            File(external, "Pictures/WhatsApp"),
            File(external, "DCIM/WhatsApp"),
            File("/storage/emulated/999/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images"),
            File("/storage/emulated/999/Android/media/com.whatsapp.w4b/WhatsApp Business/Media/WhatsApp Business Images")
        )
    }

    private fun watchRecursively(root: File) {
        if (!root.isDirectory || observers.containsKey(root.absolutePath)) return
        root.walkTopDown()
            .filter { it.isDirectory }
            .forEach { directory -> watchDirectory(directory) }
    }

    @Suppress("DEPRECATION")
    private fun watchDirectory(directory: File) {
        if (observers.containsKey(directory.absolutePath)) return

        val observer = object : FileObserver(directory.absolutePath, FILE_EVENTS) {
            override fun onEvent(event: Int, path: String?) {
                if (path.isNullOrBlank()) return
                val cleanEvent = event and FileObserver.ALL_EVENTS
                val child = File(directory, path)

                Log.d(TAG, "FileObserver event: $cleanEvent for ${child.absolutePath}")

                if ((cleanEvent and FileObserver.CREATE) != 0 && child.isDirectory) {
                    Log.d(TAG, "New directory created, watching: ${child.absolutePath}")
                    mainHandler.postDelayed({ watchRecursively(child) }, 150L)
                    return
                }

                if (!isImageFile(child)) {
                    Log.d(TAG, "Ignoring non-image file: ${child.absolutePath}")
                    return
                }
                Log.d(TAG, "Image file detected by observer: ${child.absolutePath}")
                mainHandler.postDelayed({ waitUntilStable(child) }, 150L)
            }
        }

        observer.startWatching()
        observers[directory.absolutePath] = observer
    }

    private fun waitUntilStable(file: File) {
        if (!file.exists() || !file.canRead()) return

        val firstLength = file.length()
        mainHandler.postDelayed({
            if (file.exists() && file.canRead() && file.length() == firstLength && file.length() > 0L) {
                Log.d(TAG, "Image file stable and ready: ${file.absolutePath}")
                onReady(file)
            } else {
                Log.d(TAG, "Image file not stable yet: ${file.absolutePath}, length: ${file.length()}, firstLength: $firstLength")
            }
        }, 200L)
    }

    private fun isImageFile(file: File): Boolean {
        val name = file.name.lowercase()
        return name.endsWith(".jpg") ||
            name.endsWith(".jpeg") ||
            name.endsWith(".png") ||
            name.endsWith(".webp") ||
            name.endsWith(".heic")
    }

    companion object {
        private const val TAG = "WA-ImageObserver"
        private const val FILE_EVENTS =
            FileObserver.CLOSE_WRITE or FileObserver.MOVED_TO or FileObserver.CREATE
    }
}

object WhatsAppBridgeProcessor {
    private const val TAG = "WA-Processor"
    private const val AUDIO_MATCH_WINDOW_MS = 60_000L
    private const val IMAGE_MATCH_WINDOW_MS = 60_000L
    private const val MAX_CACHE_SIZE = 60
    private const val MAX_REPLY_AGE_MS = 90 * 60 * 1000L
    private const val DUPLICATE_MESSAGE_WINDOW_MS = 3 * 1000L
    private const val CHECKING_REPLY = "בודק את הנתונים"

    private val executor = Executors.newSingleThreadExecutor()
    private val lock = Any()
    private val recentNotifications = linkedMapOf<String, Long>()
    private val recentMessageFingerprints = linkedMapOf<String, Long>()
    private val replyActions = linkedMapOf<String, ReplyHandle>()
    private val pendingAudioMessages = mutableListOf<IncomingWhatsAppMessage>()
    private val unmatchedAudioFiles = mutableListOf<AudioFileCandidate>()
    private val pendingImageMessages = mutableListOf<IncomingWhatsAppMessage>()
    private val unmatchedImageFiles = mutableListOf<ImageFileCandidate>()
    private var lastActiveImageMessage: IncomingWhatsAppMessage? = null
    private var lastActiveImageMessageTime: Long = 0L
    private val replyDebounceRunnableMap = mutableMapOf<String, Runnable>()
    private val mainHandler = Handler(Looper.getMainLooper())

    fun fromNotification(
        sbn: StatusBarNotification,
        notification: Notification
    ): IncomingWhatsAppMessage? {
        if ((notification.flags and Notification.FLAG_GROUP_SUMMARY) != 0) return null

        val extras = notification.extras ?: Bundle.EMPTY
        val title = extras.getCharSequence(Notification.EXTRA_TITLE)?.toString()?.trim().orEmpty()
        val text = extractMessageText(extras)
        val conversationTitle = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            extras.getCharSequence(Notification.EXTRA_CONVERSATION_TITLE)?.toString()?.trim()
        } else {
            null
        }

        if (title.isEmpty() && text.isEmpty()) return null
        if (isNonMessageNotification(title, text)) return null
        if (looksLikePirsumotoReply(text)) return null

        val type = when {
            looksLikeVoiceMessage(text) -> "audio"
            looksLikeImageMessage(extras, text) -> {
                Log.d(TAG, "Notification looks like an image message. text: $text")
                "image"
            }
            else -> "text"
        }
        val messageId = "${sbn.key}:${sbn.postTime}:${text.hashCode()}"
        val senderKey = listOfNotNull(conversationTitle, title)
            .joinToString("|")
            .ifBlank { sbn.key }

        return IncomingWhatsAppMessage(
            id = messageId,
            notificationKey = sbn.key,
            packageName = sbn.packageName,
            senderName = title.ifBlank { null },
            senderKey = senderKey,
            conversationTitle = conversationTitle,
            text = text.ifBlank { null },
            type = type,
            timestamp = sbn.postTime
        )
    }

    fun findDirectReplyAction(notification: Notification): Notification.Action? {
        val actions = notification.actions ?: return null
        return actions.firstOrNull { action ->
            action.remoteInputs != null && action.remoteInputs.isNotEmpty()
        }
    }

    fun updateReplyAction(senderKey: String, action: Notification.Action) {
        if (senderKey.isBlank()) return
        synchronized(lock) {
            replyActions[senderKey] = ReplyHandle(action, System.currentTimeMillis())
            val cleanKey = senderKey.split("|").firstOrNull()?.trim()
            if (!cleanKey.isNullOrBlank()) {
                replyActions[cleanKey] = ReplyHandle(action, System.currentTimeMillis())
            }
            trimReplyActionsLocked()
        }
    }

    fun onNotification(
        context: Context,
        message: IncomingWhatsAppMessage,
        directReplyAction: Notification.Action?
    ) {
        if (directReplyAction != null) {
            updateReplyAction(message.senderKey, directReplyAction)
            message.senderName?.let { updateReplyAction(it, directReplyAction) }
        }

        if (looksLikePirsumotoReply(message.text.orEmpty())) return
        if (!markNotificationSeen(message)) return

        WhatsAppBridgeEvents.emit(
            "messageReceived",
            mapOf(
                "type" to message.type,
                "senderName" to message.senderName,
                "senderKey" to message.senderKey,
                "conversationTitle" to message.conversationTitle,
                "text" to message.text
            )
        )

        when (message.type) {
            "audio" -> enqueueAudioMessage(context, message)
            "image" -> enqueueImageMessage(context, message)
            else -> processTextMessage(context.applicationContext, message)
        }
    }

    fun onVoiceNoteFile(context: Context, file: File) {
        val candidate = AudioFileCandidate(file.absolutePath, System.currentTimeMillis())
        val match = synchronized(lock) {
            trimAudioCachesLocked()
            val matchingMessage = pendingAudioMessages.minByOrNull { message ->
                abs(candidate.timestamp - message.timestamp)
            }?.takeIf { message ->
                abs(candidate.timestamp - message.timestamp) <= AUDIO_MATCH_WINDOW_MS
            }

            if (matchingMessage != null) {
                pendingAudioMessages.remove(matchingMessage)
                matchingMessage
            } else {
                unmatchedAudioFiles.add(candidate)
                null
            }
        }

        if (match != null) {
            processAudioMessage(context.applicationContext, match, file)
        }
    }

    fun onImageFile(context: Context, file: File) {
        val candidate = ImageFileCandidate(file.absolutePath, System.currentTimeMillis())
        Log.d(TAG, "onImageFile received file: ${file.absolutePath} at ${candidate.timestamp}")
        val match = synchronized(lock) {
            trimImageCachesLocked()
            Log.d(TAG, "Looking for matching notification among ${pendingImageMessages.size} pending image messages")
            val matchingMessage = pendingImageMessages.minByOrNull { message ->
                abs(candidate.timestamp - message.timestamp)
            }?.takeIf { message ->
                abs(candidate.timestamp - message.timestamp) <= IMAGE_MATCH_WINDOW_MS
            }

            if (matchingMessage != null) {
                Log.d(TAG, "Found matching notification for image file: ${matchingMessage.id}")
                lastActiveImageMessage = matchingMessage
                lastActiveImageMessageTime = System.currentTimeMillis()
                matchingMessage
            } else if (lastActiveImageMessage != null &&
                abs(candidate.timestamp - lastActiveImageMessageTime) <= IMAGE_MATCH_WINDOW_MS) {
                Log.d(TAG, "Re-using last active image message for batch image file: ${file.name}")
                lastActiveImageMessage
            } else {
                Log.d(TAG, "No matching notification found within ${IMAGE_MATCH_WINDOW_MS}ms. Adding to unmatchedImageFiles.")
                unmatchedImageFiles.add(candidate)
                null
            }
        }

        if (match != null) {
            processImageMessage(context.applicationContext, match, file)
        }
    }

    private fun enqueueAudioMessage(context: Context, message: IncomingWhatsAppMessage) {
        val matchingFile = synchronized(lock) {
            trimAudioCachesLocked()
            val candidate = unmatchedAudioFiles.minByOrNull { file ->
                abs(file.timestamp - message.timestamp)
            }?.takeIf { file ->
                abs(file.timestamp - message.timestamp) <= AUDIO_MATCH_WINDOW_MS
            }

            if (candidate != null) {
                unmatchedAudioFiles.remove(candidate)
                File(candidate.path)
            } else {
                pendingAudioMessages.add(message)
                null
            }
        }

        if (matchingFile != null) {
            processAudioMessage(context.applicationContext, message, matchingFile)
        }
    }

    private fun extractExpectedImageCount(text: String?): Int {
        if (text == null) return 1
        val numRegex = Regex("\\d+")
        val match = numRegex.find(text)
        return match?.value?.toIntOrNull() ?: 1
    }

    private fun enqueueImageMessage(context: Context, message: IncomingWhatsAppMessage) {
        WhatsAppImageObserverManager.ensureStarted(context)
        val dateFormat = SimpleDateFormat("mm:ss.SSS", Locale.getDefault())
        val msgTimeStr = dateFormat.format(Date(message.timestamp))
        Log.d(TAG, "enqueueImageMessage for notification: ${message.id}")
        Log.d(TAG, "Message timestamp: ${message.timestamp} ($msgTimeStr)")
        
        val stateExpectedCount = WhatsAppLocalInventoryValidator.getExpectedImageCount(context, message.senderKey)
        val notificationExpectedCount = extractExpectedImageCount(message.text)
        val expectedCount = if (stateExpectedCount > 0) stateExpectedCount else notificationExpectedCount
        
        val matchingFiles = synchronized(lock) {
            trimImageCachesLocked()
            lastActiveImageMessage = message
            lastActiveImageMessageTime = System.currentTimeMillis()
            Log.d(TAG, "Looking for matching image files among ${unmatchedImageFiles.size} unmatched files")

            val candidates = unmatchedImageFiles.filter { file ->
                val diff = abs(file.timestamp - message.timestamp)
                diff <= IMAGE_MATCH_WINDOW_MS
            }.sortedBy { abs(it.timestamp - message.timestamp) }

            if (candidates.isNotEmpty()) {
                Log.d(TAG, "Found ${candidates.size} matching image files in cache for batch notification")
                val subset = candidates.take(expectedCount)
                unmatchedImageFiles.removeAll(subset.toSet())
                subset.map { File(it.path) }
            } else {
                Log.d(TAG, "No match in cache. Actively scanning directories for recent image files...")
                val activeScanFiles = findAllRecentImageFiles(message.timestamp, expectedCount)
                if (activeScanFiles.isNotEmpty()) {
                    Log.d(TAG, "Found ${activeScanFiles.size} recent image files via active scan")
                    activeScanFiles
                } else {
                    Log.d(TAG, "No matching image file found within ${IMAGE_MATCH_WINDOW_MS}ms. Adding to pendingImageMessages.")
                    pendingImageMessages.add(message)
                    emptyList()
                }
            }
        }

        for (matchingFile in matchingFiles) {
            processImageMessage(context.applicationContext, message, matchingFile)
        }

        mainHandler.postDelayed({
            val delayedFiles = synchronized(lock) {
                if (pendingImageMessages.contains(message)) {
                    val scanFiles = findAllRecentImageFiles(message.timestamp, expectedCount)
                    if (scanFiles.isNotEmpty()) {
                        Log.d(TAG, "Delayed active scan found ${scanFiles.size} recent image files!")
                        pendingImageMessages.remove(message)
                        scanFiles
                    } else emptyList()
                } else emptyList()
            }
            for (file in delayedFiles) {
                processImageMessage(context.applicationContext, message, file)
            }
        }, 400L)
    }

    private fun findRecentImageFile(targetTimestamp: Long): File? {
        return findAllRecentImageFiles(targetTimestamp, 1).firstOrNull()
    }

    fun findAllRecentImageFiles(
        targetTimestamp: Long,
        expectedCount: Int,
        maxWindowMs: Long = 30 * 60 * 1000L
    ): List<File> {
        val external = Environment.getExternalStorageDirectory()
        val roots = listOf(
            File(external, "Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images"),
            File(external, "Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images/Private"),
            File(external, "Android/media/com.whatsapp.w4b/WhatsApp Business/Media/WhatsApp Business Images"),
            File(external, "Android/media/com.whatsapp.w4b/WhatsApp Business/Media/WhatsApp Business Images/Private"),
            File(external, "WhatsApp/Media/WhatsApp Images"),
            File(external, "WhatsApp/Media/WhatsApp Images/Private"),
            File(external, "Pictures/WhatsApp"),
            File(external, "DCIM/WhatsApp"),
            File("/storage/emulated/999/Android/media/com.whatsapp/WhatsApp/Media/WhatsApp Images"),
            File("/storage/emulated/999/Android/media/com.whatsapp.w4b/WhatsApp Business/Media/WhatsApp Business Images")
        )

        val matches = mutableListOf<File>()

        for (root in roots) {
            if (!root.exists() || !root.isDirectory) continue

            root.walkTopDown().maxDepth(2).forEach { file ->
                if (!file.isFile || !isImageFile(file)) return@forEach

                val lastMod = file.lastModified()
                val diffWithTarget = abs(lastMod - targetTimestamp)

                if (diffWithTarget <= maxWindowMs) {
                    matches.add(file)
                }
            }
        }

        return matches.distinctBy { it.absolutePath }
            .sortedBy { abs(it.lastModified() - targetTimestamp) }
            .take(expectedCount)
    }

    private fun isImageFile(file: File): Boolean {
        val name = file.name.lowercase(Locale.getDefault())
        return name.endsWith(".jpg") ||
            name.endsWith(".jpeg") ||
            name.endsWith(".png") ||
            name.endsWith(".webp") ||
            name.endsWith(".heic")
    }

    private fun processTextMessage(context: Context, message: IncomingWhatsAppMessage) {
        val rawText = message.text.orEmpty().trim()
        if (isSystemNotificationMessage(rawText) || looksLikePirsumotoReply(rawText)) {
            Log.d(TAG, "Ignoring system notification or self reply: $rawText")
            return
        }

        executor.execute {
            if (WhatsAppBridgeEvents.hasActiveSink()) {
                // Active Flutter EventSink: Let Flutter handle text validation & auto-reply to avoid duplicate replies
                WhatsAppBridgeEvents.emit(
                    "whatsappTextReceived",
                    mapOf(
                        "senderName" to message.senderName,
                        "senderKey" to message.senderKey,
                        "text" to rawText,
                        "timestamp" to message.timestamp
                    )
                )
            } else {
                // Background / Detached: Process natively in Kotlin
                val result = WhatsAppLocalInventoryValidator.process(
                    context = context,
                    senderKey = message.senderKey,
                    text = rawText,
                    audioFile = null
                )

                val vehicleData = withWhatsAppMetadata(message, result.vehicleData)

                WhatsAppBridgeEvents.emit(
                    "locallyProcessed",
                    mapOf(
                        "senderName" to message.senderName,
                        "missingFields" to result.missingFieldKeys,
                        "updatedFields" to result.updatedFieldKeys,
                        "readyToPublish" to result.readyToPublish,
                        "autoPublishRequested" to result.autoPublishRequested,
                        "vehicleData" to vehicleData
                    )
                )

                if (!result.replyHebrew.isNullOrBlank()) {
                    maybeSendReply(context, message.senderKey, result.replyHebrew)
                }

                if (result.autoPublishRequested && vehicleData.isNotEmpty()) {
                    WhatsAppAutoPublishLauncher.launch(context, vehicleData)
                }
            }
        }
    }

    private fun isSystemNotificationMessage(text: String): Boolean {
        val trimmed = text.trim()
        return trimmed.startsWith("תהליך") ||
               trimmed.startsWith("האוטומציה") ||
               trimmed.startsWith("פרטי הרכב") ||
               trimmed.startsWith("מצאתי את הרכב") ||
               trimmed.startsWith("נמצאו שגיאות") ||
               trimmed.startsWith("חסרים עדיין") ||
               trimmed.startsWith("התקבלו") ||
               trimmed.startsWith("מתחיל פרסום") ||
               trimmed.startsWith("קיבלתי") ||
               trimmed.startsWith("נקלטה") ||
               trimmed.contains("חיפוש הודעות") ||
               trimmed.contains("משתקבלות הודעות")
    }

    private fun processAudioMessage(context: Context, message: IncomingWhatsAppMessage, file: File) {
        WhatsAppBridgeEvents.emit(
            "audioMatched",
            mapOf("senderName" to message.senderName, "fileName" to file.name)
        )

        executor.execute {
            maybeSendReply(context, message.senderKey, CHECKING_REPLY)
            val audioResult = WhatsAppOpenAiAudioProcessor.processAudio(file)
            if (audioResult?.transcript != null) {
                WhatsAppBridgeEvents.emit(
                    "audioTranscribed",
                    mapOf(
                        "senderName" to message.senderName,
                        "audioFileName" to file.name,
                        "transcript" to audioResult.transcript
                    )
                )
            } else {
                WhatsAppBridgeEvents.emit(
                    "error",
                    mapOf(
                        "message" to "Audio transcription failed",
                        "audioFileName" to file.name
                    )
                )
            }

            val result = WhatsAppLocalInventoryValidator.process(
                context = context,
                senderKey = message.senderKey,
                text = audioResult?.transcript ?: message.text.orEmpty(),
                audioFile = file,
                extractedFields = audioResult?.inventoryFields ?: emptyMap(),
                audioTranscriptionAttempted = true
            )
            val vehicleData = withWhatsAppMetadata(message, result.vehicleData)
            WhatsAppBridgeEvents.emit(
                "locallyProcessed",
                mapOf(
                    "senderName" to message.senderName,
                    "missingFields" to result.missingFieldKeys,
                    "updatedFields" to result.updatedFieldKeys,
                    "audioFileName" to file.name,
                    "readyToPublish" to result.readyToPublish,
                    "autoPublishRequested" to result.autoPublishRequested,
                    "vehicleData" to vehicleData
                )
            )
            val reply = result.replyHebrew
            maybeSendReply(context, message.senderKey, reply)
            if (result.autoPublishRequested) {
                WhatsAppAutoPublishLauncher.launch(context, vehicleData)
            }
        }
    }

    private fun processImageMessage(context: Context, message: IncomingWhatsAppMessage, file: File) {
        Log.d(TAG, "Starting processImageMessage for file: ${file.name} and message: ${message.id}")
        WhatsAppBridgeEvents.emit(
            "imageMatched",
            mapOf("senderName" to message.senderName, "fileName" to file.name)
        )

        executor.execute {
            if (WhatsAppBridgeEvents.hasActiveSink()) {
                WhatsAppBridgeEvents.emit(
                    "whatsappImageReceived",
                    mapOf(
                        "senderName" to message.senderName,
                        "senderKey" to message.senderKey,
                        "imageFilePath" to file.absolutePath,
                        "imageFileName" to file.name,
                        "timestamp" to message.timestamp
                    )
                )
            } else {
                val result = WhatsAppLocalInventoryValidator.processImage(
                    context = context,
                    senderKey = message.senderKey,
                    imageFile = file
                )

                WhatsAppBridgeEvents.emit(
                    "locallyProcessed",
                    mapOf(
                        "senderName" to message.senderName,
                        "missingFields" to result.missingFieldKeys,
                        "updatedFields" to result.updatedFieldKeys,
                        "readyToPublish" to result.readyToPublish,
                        "autoPublishRequested" to result.autoPublishRequested,
                        "vehicleData" to result.vehicleData
                    )
                )

                if (!result.replyHebrew.isNullOrBlank()) {
                    maybeSendReply(context, message.senderKey, result.replyHebrew)
                }

                if (result.autoPublishRequested && result.vehicleData.isNotEmpty()) {
                    WhatsAppAutoPublishLauncher.launch(context, result.vehicleData)
                }
            }
        }
    }

    private fun scheduleDebouncedReply(context: Context, senderKey: String, reply: String?) {
        if (reply.isNullOrBlank()) return
        synchronized(lock) {
            replyDebounceRunnableMap[senderKey]?.let { mainHandler.removeCallbacks(it) }
            val runnable = Runnable {
                synchronized(lock) { replyDebounceRunnableMap.remove(senderKey) }
                maybeSendReply(context, senderKey, reply)
            }
            replyDebounceRunnableMap[senderKey] = runnable
            mainHandler.postDelayed(runnable, 300L)
        }
    }

    fun sendReplyFromApp(context: Context, senderKey: String, reply: String): Boolean {
        return maybeSendReply(context.applicationContext, senderKey, reply)
    }

    private fun maybeSendReply(context: Context, senderKey: String, reply: String?): Boolean {
        if (reply.isNullOrBlank()) return false
        if (!WhatsAppBridgeConfig.isAutoReplyEnabled(context)) return false

        val handle = synchronized(lock) {
            trimReplyActionsLocked()
            val cleanKey1 = senderKey.split("|").firstOrNull()?.trim().orEmpty()
            val cleanKey2 = senderKey.split("|").lastOrNull()?.trim().orEmpty()
            replyActions[senderKey]
                ?: replyActions[cleanKey1]
                ?: replyActions[cleanKey2]
                ?: replyActions.values.maxByOrNull { it.receivedAt }?.takeIf {
                    System.currentTimeMillis() - it.receivedAt <= 90 * 60 * 1000L
                }
        } ?: run {
            Log.w(TAG, "No direct-reply action found for senderKey: $senderKey")
            WhatsAppBridgeEvents.emit("error", mapOf("message" to "No WhatsApp direct-reply action is available for $senderKey"))
            return false
        }

        try {
            val remoteInputs = handle.action.remoteInputs ?: return false
            val replyIntent = Intent().addFlags(Intent.FLAG_RECEIVER_FOREGROUND)
            val replyBundle = Bundle()
            remoteInputs.forEach { remoteInput ->
                replyBundle.putCharSequence(remoteInput.resultKey, reply)
            }
            RemoteInput.addResultsToIntent(remoteInputs, replyIntent, replyBundle)
            handle.action.actionIntent.send(context, 0, replyIntent)
            WhatsAppBridgeEvents.emit("replySent", mapOf("senderKey" to senderKey))
            return true
        } catch (e: PendingIntent.CanceledException) {
            Log.e(TAG, "WhatsApp direct reply action expired", e)
            WhatsAppBridgeEvents.emit("error", mapOf("message" to "WhatsApp direct-reply action expired"))
            return false
        }
    }

    private fun withWhatsAppMetadata(
        message: IncomingWhatsAppMessage,
        vehicleData: Map<String, String>
    ): Map<String, String> {
        if (vehicleData.isEmpty()) return vehicleData
        val enriched = linkedMapOf<String, String>()
        enriched.putAll(vehicleData)
        enriched["whatsapp_origin"] = "true"
        enriched["whatsapp_sender_key"] = message.senderKey
        message.senderName?.takeIf { it.isNotBlank() }?.let { enriched["whatsapp_sender_name"] = it }
        message.conversationTitle?.takeIf { it.isNotBlank() }?.let { enriched["whatsapp_conversation_title"] = it }
        return enriched
    }

    private fun markNotificationSeen(message: IncomingWhatsAppMessage): Boolean {
        synchronized(lock) {
            val now = System.currentTimeMillis()
            trimNotificationDedupeLocked(now)

            if (recentNotifications.containsKey(message.id)) return false

            val fingerprint = message.stableFingerprint()
            val lastSeenAt = recentMessageFingerprints[fingerprint]
            if (lastSeenAt != null && now - lastSeenAt < DUPLICATE_MESSAGE_WINDOW_MS) {
                WhatsAppBridgeEvents.emit(
                    "duplicateMessageDropped",
                    mapOf("senderName" to message.senderName, "type" to message.type)
                )
                return false
            }

            recentNotifications[message.id] = now
            recentMessageFingerprints[fingerprint] = now
            trimNotificationDedupeLocked(now)
            return true
        }
    }

    private fun trimNotificationDedupeLocked(now: Long) {
        val cutoff = now - DUPLICATE_MESSAGE_WINDOW_MS
        recentNotifications.entries.removeAll { it.value < cutoff }
        recentMessageFingerprints.entries.removeAll { it.value < cutoff }

        while (recentNotifications.size > MAX_CACHE_SIZE) {
            val firstKey = recentNotifications.keys.firstOrNull() ?: break
            recentNotifications.remove(firstKey)
        }
        while (recentMessageFingerprints.size > MAX_CACHE_SIZE) {
            val firstKey = recentMessageFingerprints.keys.firstOrNull() ?: break
            recentMessageFingerprints.remove(firstKey)
        }
    }

    private fun IncomingWhatsAppMessage.stableFingerprint(): String {
        if (type == "audio" || type == "image") {
            return "$packageName|$senderKey|$type|$notificationKey|$timestamp"
        }
        val normalizedText = text
            .orEmpty()
            .lowercase()
            .replace(Regex("\\s+"), " ")
            .trim()
            .take(500)
        return "$packageName|$senderKey|$type|$normalizedText"
    }

    private fun trimReplyActionsLocked() {
        val cutoff = System.currentTimeMillis() - MAX_REPLY_AGE_MS
        replyActions.entries.removeAll { it.value.receivedAt < cutoff }
        while (replyActions.size > MAX_CACHE_SIZE) {
            val firstKey = replyActions.keys.firstOrNull() ?: break
            replyActions.remove(firstKey)
        }
    }

    private fun trimAudioCachesLocked() {
        val cutoff = System.currentTimeMillis() - (2 * 60 * 1000L)
        pendingAudioMessages.removeAll { it.timestamp < cutoff }
        unmatchedAudioFiles.removeAll { it.timestamp < cutoff }
        while (pendingAudioMessages.size > MAX_CACHE_SIZE) pendingAudioMessages.removeAt(0)
        while (unmatchedAudioFiles.size > MAX_CACHE_SIZE) unmatchedAudioFiles.removeAt(0)
    }

    private fun trimImageCachesLocked() {
        val cutoff = System.currentTimeMillis() - (2 * 60 * 1000L)
        pendingImageMessages.removeAll { it.timestamp < cutoff }
        unmatchedImageFiles.removeAll { it.timestamp < cutoff }
        while (pendingImageMessages.size > MAX_CACHE_SIZE) pendingImageMessages.removeAt(0)
        while (unmatchedImageFiles.size > MAX_CACHE_SIZE) unmatchedImageFiles.removeAt(0)
    }

    private fun extractMessageText(extras: Bundle): String {
        val bigText = extras.getCharSequence(Notification.EXTRA_BIG_TEXT)?.toString()?.trim()
        if (!bigText.isNullOrBlank()) return bigText

        val lines = extras.getCharSequenceArray(Notification.EXTRA_TEXT_LINES)
        val lastLine = lines?.lastOrNull()?.toString()?.trim()
        if (!lastLine.isNullOrBlank()) return lastLine

        return extras.getCharSequence(Notification.EXTRA_TEXT)?.toString()?.trim().orEmpty()
    }

    private fun looksLikeVoiceMessage(text: String): Boolean {
        val lower = text.lowercase()
        return lower.contains("voice message") ||
            lower.contains("audio message") ||
            lower.contains("ptt") ||
            lower.contains("\u05d4\u05d5\u05d3\u05e2\u05d4 \u05e7\u05d5\u05dc\u05d9\u05ea") ||
            lower.contains("\u05d4\u05d5\u05d3\u05e2\u05ea \u05e9\u05de\u05e2")
    }

    private fun looksLikeImageMessage(extras: Bundle, text: String): Boolean {
        if (looksLikePirsumotoReply(text)) return false
        if (extras.get(Notification.EXTRA_PICTURE) != null ||
            extras.get("android.picture") != null ||
            extras.getString("android.template", "").contains("BigPictureStyle")) {
            return true
        }
        val lower = text.lowercase(Locale.getDefault()).trim()
        return lower == "photo" ||
               lower == "photos" ||
               lower == "picture" ||
               lower == "pictures" ||
               lower.contains("תמונה") ||
               lower.contains("תמונות") ||
               lower.contains("photo") ||
               lower.contains("picture") ||
               lower.contains("📷") ||
               lower.startsWith("📷")
    }

    private fun isNonMessageNotification(title: String, text: String): Boolean {
        val cleanTitle = title.replace("\u200F", "").replace("\u200E", "").trim()
        val combined = "$cleanTitle $text".lowercase(Locale.getDefault())
        return cleanTitle == "WhatsApp" ||
            cleanTitle == "וואטסאפ" ||
            cleanTitle == "את/ה" ||
            cleanTitle == "אתה" ||
            cleanTitle == "את" ||
            cleanTitle == "You" ||
            combined.contains("whatsapp web") ||
            combined.contains("checking for new messages") ||
            combined.contains("חיפוש הודעות") ||
            combined.contains("משתקבלות הודעות") ||
            combined.contains("מגבה") ||
            combined.contains("גיבוי") ||
            combined.contains("backup") ||
            combined.contains("connected")
    }

    private fun looksLikePirsumotoReply(text: String): Boolean {
        val norm = text.trim().lowercase(Locale.getDefault())
        return norm == "מבטל" ||
               norm == "הפרסום בוטל." ||
               norm == "הפרסום בוטל" ||
               norm.startsWith("מבטל") ||
               norm.startsWith("עדכון הנתונים נעצר") ||
               norm.startsWith("נקלטה תמונה") ||
               norm.startsWith("התקבלו") ||
               norm.startsWith("ממתין להעלאת") ||
               norm.startsWith("מתחיל פרסום") ||
               norm.startsWith("הפרסום בוטל") ||
               norm.startsWith("תהליך") ||
               norm.startsWith("האוטומציה") ||
               norm.startsWith("פרטי הרכב") ||
               norm.startsWith("מצאתי את הרכב") ||
               norm.startsWith("לא נמצאו") ||
               norm.startsWith("לא זיהיתי") ||
               norm.startsWith("נמצאו שגיאות") ||
               norm.startsWith("חסרים עדיין") ||
               norm.startsWith("קיבלתי") ||
               norm.contains("כמה תמונות תרצה להעלות") ||
               norm.contains("השב מספר תמונות") ||
               norm.contains("פרטי הרכב לאישור")
    }
}

object WhatsAppOpenAiAudioProcessor {
    data class AudioProcessingResult(
        val transcript: String,
        val inventoryFields: Map<String, String>
    )

    private const val TAG = "WA-AudioOpenAI"
    private const val OPENAI_TRANSCRIBE_KEY =
        "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"
    private const val OPENAI_CHAT_KEY =
        "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"

    fun processAudio(audioFile: File): AudioProcessingResult? {
        return try {
            if (!audioFile.exists() || !audioFile.canRead() || audioFile.length() <= 0L) {
                Log.e(TAG, "Audio file is missing, unreadable, or empty: ${audioFile.absolutePath}")
                return null
            }

            val transcript = transcribe(audioFile)?.trim()
            if (transcript.isNullOrBlank()) return null

            val inventoryFields = extractInventoryFields(transcript)
            AudioProcessingResult(
                transcript = transcript,
                inventoryFields = inventoryFields
            )
        } catch (e: Exception) {
            Log.e(TAG, "Failed to process WhatsApp audio", e)
            null
        }
    }

    private fun transcribe(audioFile: File): String? {
        val boundary = "----PirsumotoBoundary${System.currentTimeMillis()}"
        val connection = (URL("https://api.openai.com/v1/audio/transcriptions").openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = 20000
            readTimeout = 120000
            doOutput = true
            setRequestProperty("Authorization", "Bearer $OPENAI_TRANSCRIBE_KEY")
            setRequestProperty("Content-Type", "multipart/form-data; boundary=$boundary")
            setRequestProperty("Accept", "application/json")
        }

        return try {
            connection.outputStream.use { output ->
                writeMultipartField(output, boundary, "model", "whisper-1")
                writeMultipartField(output, boundary, "language", "he")
                writeMultipartFile(
                    output = output,
                    boundary = boundary,
                    name = "file",
                    file = audioFile,
                    uploadFileName = audioUploadFileName(audioFile),
                    mimeType = audioMimeType(audioFile)
                )
                output.write("--$boundary--\r\n".toByteArray(Charsets.UTF_8))
            }

            val responseCode = connection.responseCode
            val responseText = readResponse(connection, responseCode)
            if (responseCode != 200) {
                Log.e(TAG, "Transcription failed: $responseCode $responseText")
                return null
            }

            JSONObject(responseText).optString("text").takeIf { it.isNotBlank() }
        } finally {
            connection.disconnect()
        }
    }

    private fun extractInventoryFields(transcript: String): Map<String, String> {
        val body = JSONObject()
            .put("model", "gpt-4-turbo")
            .put(
                "messages",
                JSONArray()
                    .put(
                        JSONObject()
                            .put("role", "system")
                            .put(
                                "content",
                                "Extract structured car details from the Hebrew transcript and return a JSON response. Ensure all fields are included, even if values are missing, return null."
                            )
                    )
                    .put(JSONObject().put("role", "user").put("content", transcript))
            )
            .put(
                "functions",
                JSONArray().put(
                    JSONObject()
                        .put("name", "extract_car_details")
                        .put(
                            "description",
                            "Extract car details including registration number, mileage, and ownership from a Hebrew transcript."
                        )
                        .put("parameters", extractionParameters())
                )
            )
            .put("function_call", JSONObject().put("name", "extract_car_details"))

        val connection = (URL("https://api.openai.com/v1/chat/completions").openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"
            connectTimeout = 20000
            readTimeout = 120000
            doOutput = true
            setRequestProperty("Authorization", "Bearer $OPENAI_CHAT_KEY")
            setRequestProperty("Content-Type", "application/json; charset=utf-8")
            setRequestProperty("Accept", "application/json")
        }

        return try {
            connection.outputStream.use { output ->
                output.write(body.toString().toByteArray(Charsets.UTF_8))
            }

            val responseCode = connection.responseCode
            val responseText = readResponse(connection, responseCode)
            if (responseCode != 200) {
                Log.e(TAG, "Field extraction failed: $responseCode $responseText")
                return emptyMap()
            }

            val argsText = JSONObject(responseText)
                .optJSONArray("choices")
                ?.optJSONObject(0)
                ?.optJSONObject("message")
                ?.optJSONObject("function_call")
                ?.optString("arguments")
                .orEmpty()
            if (argsText.isBlank()) return emptyMap()

            mapAudioServiceFieldsToInventory(JSONObject(argsText))
        } catch (e: Exception) {
            Log.e(TAG, "Failed to extract fields from transcript", e)
            emptyMap()
        } finally {
            connection.disconnect()
        }
    }

    private fun extractionParameters(): JSONObject {
        val ownershipEnum = JSONArray()
            .put("פרטית")
            .put("חברה")
            .put("השכרה")
            .put("ליסינג")
            .put("מונית")
            .put("לימוד נהיגה")
            .put("ייבוא אישי")
            .put("ייבוא מקביל")
            .put("ממשלתי")
            .put("או״ם")
            .put("השכרה / החכר")

        val properties = JSONObject()
            .put("license", JSONObject().put("type", "string"))
            .put("month", JSONObject().put("type", "string"))
            .put("test", JSONObject().put("type", "string"))
            .put(
                "hand",
                JSONObject()
                    .put("type", "string")
                    .put(
                        "enum",
                        JSONArray()
                            .put("יד ראשונה")
                            .put("יד שנייה")
                            .put("יד שלישית")
                            .put("יד רביעית")
                            .put("יד חמישית")
                            .put("יד שישית")
                            .put("יד שביעית")
                            .put("יד שמינית")
                            .put("יד תשיעית")
                            .put("יד עשירית")
                    )
            )
            .put("ownership", JSONObject().put("type", "string").put("enum", ownershipEnum))
            .put("prevOwnership", JSONObject().put("type", "string").put("enum", ownershipEnum))
            .put("km", JSONObject().put("type", "integer"))
            .put("price", JSONObject().put("type", "integer"))
            .put(
                "vehicleCondition",
                JSONObject()
                    .put("type", "string")
                    .put(
                        "enum",
                        JSONArray()
                            .put("מצוין")
                            .put("טוב מאוד")
                            .put("טוב")
                            .put("סביר")
                            .put("גרוע")
                    )
            )
            .put("description", JSONObject().put("type", "string"))

        return JSONObject()
            .put("type", "object")
            .put("properties", properties)
    }

    private fun mapAudioServiceFieldsToInventory(json: JSONObject): Map<String, String> {
        val result = linkedMapOf<String, String>()
        putJsonString(result, "license_plate", json, "license")
        putJsonString(result, "test_month", json, "month")

        val test = json.optString("test").takeIf { it.isNotBlank() && it != "null" }
        if (test != null) {
            val parts = test.split(",", "/", "-", ".").map { it.trim() }
            if (parts.size >= 2) {
                result["test_month"] = parts[0]
                result["test_year"] = parts[1]
            }
        }

        putJsonString(result, "hand", json, "hand")
        putJsonString(result, "current_ownership", json, "ownership")
        putJsonString(result, "previous_ownership", json, "prevOwnership")
        putJsonString(result, "km", json, "km")
        putJsonString(result, "price", json, "price")
        putJsonString(result, "vehicle_condition", json, "vehicleCondition")
        putJsonString(result, "description", json, "description")
        return result
    }

    private fun putJsonString(
        result: MutableMap<String, String>,
        targetKey: String,
        json: JSONObject,
        sourceKey: String
    ) {
        if (!json.has(sourceKey) || json.isNull(sourceKey)) return
        val value = json.opt(sourceKey)?.toString()?.trim()
        if (!value.isNullOrBlank() && value != "null") {
            result[targetKey] = value
        }
    }

    private fun writeMultipartField(
        output: java.io.OutputStream,
        boundary: String,
        name: String,
        value: String
    ) {
        output.write("--$boundary\r\n".toByteArray(Charsets.UTF_8))
        output.write("Content-Disposition: form-data; name=\"$name\"\r\n\r\n".toByteArray(Charsets.UTF_8))
        output.write(value.toByteArray(Charsets.UTF_8))
        output.write("\r\n".toByteArray(Charsets.UTF_8))
    }

    private fun writeMultipartFile(
        output: java.io.OutputStream,
        boundary: String,
        name: String,
        file: File,
        uploadFileName: String,
        mimeType: String
    ) {
        output.write("--$boundary\r\n".toByteArray(Charsets.UTF_8))
        output.write(
            "Content-Disposition: form-data; name=\"$name\"; filename=\"$uploadFileName\"\r\n".toByteArray(Charsets.UTF_8)
        )
        output.write("Content-Type: $mimeType\r\n\r\n".toByteArray(Charsets.UTF_8))
        file.inputStream().use { input -> input.copyTo(output) }
        output.write("\r\n".toByteArray(Charsets.UTF_8))
    }

    private fun readResponse(connection: HttpURLConnection, responseCode: Int): String {
        val stream = if (responseCode in 200..299) {
            connection.inputStream
        } else {
            connection.errorStream
        }
        return stream?.bufferedReader()?.use { it.readText() }.orEmpty()
    }

    private fun audioMimeType(file: File): String {
        return when {
            file.name.endsWith(".opus", ignoreCase = true) -> "audio/ogg"
            file.name.endsWith(".m4a", ignoreCase = true) -> "audio/mp4"
            else -> "audio/ogg"
        }
    }

    private fun audioUploadFileName(file: File): String {
        return when {
            file.name.endsWith(".opus", ignoreCase = true) -> "${file.nameWithoutExtension}.ogg"
            file.name.endsWith(".m4a", ignoreCase = true) -> file.name
            file.name.endsWith(".ogg", ignoreCase = true) -> file.name
            else -> "${file.nameWithoutExtension.ifBlank { "audio" }}.ogg"
        }
    }
}

object WhatsAppLocalInventoryValidator {
    data class ValidationResult(
        val replyHebrew: String?,
        val missingFieldKeys: List<String>,
        val updatedFieldKeys: List<String>,
        val readyToPublish: Boolean,
        val autoPublishRequested: Boolean,
        val vehicleData: Map<String, String>
    )

    private data class InventoryField(
        val key: String,
        val hebrewLabel: String
    )

    private data class RegistryLookup(
        val found: Boolean,
        val fields: Map<String, String> = emptyMap()
    )

    private const val PREFS = "pirsumoto_whatsapp_inventory_states"
    private const val ADMIN_LINE = "\n\n*לביטול התהליך השב ביטול*"
    private const val DATA_GOV_SEARCH_URL = "https://data.gov.il/api/3/action/datastore_search"
    private const val VEHICLE_RESOURCE_ID = "053cea08-09bc-40ec-8f7a-156f0677aff3"
    private const val GEAR_RESOURCE_ID = "142afde2-6228-49f9-8a29-9b6c3a0cbe40"
    private const val KEY_IMAGE_EXPECTED_COUNT = "image_expected_count"
    private const val KEY_IMAGE_RECEIVED_COUNT = "image_received_count"
    private const val KEY_IMAGE_PATHS = "image_paths"
    private const val KEY_AUTO_PUBLISH_STARTED = "auto_publish_started"
    private val prefsLock = Any()
    private val fields = listOf(
        InventoryField("license_plate", "מספר רכב"),
        InventoryField("maker", "יצרן"),
        InventoryField("model", "דגם"),
        InventoryField("year", "שנת ייצור"),
        InventoryField("fuel_type", "סוג דלק"),
        InventoryField("color", "צבע"),
        InventoryField("month", "חודש עלייה לכביש"),
        InventoryField("test_month", "חודש טסט"),
        InventoryField("test_year", "שנת טסט"),
        InventoryField("hand", "יד"),
        InventoryField("current_ownership", "בעלות נוכחית"),
        InventoryField("previous_ownership", "בעלות קודמת"),
        InventoryField("km", "קילומטראז'"),
        InventoryField("price", "מחיר"),
        InventoryField("vehicle_condition", "מצב כללי"),
        InventoryField("description", "תיאור חופשי"),
        InventoryField("gear_type", "סוג גיר"),
        InventoryField("data_found", "נמצא במאגר"),
        InventoryField(KEY_IMAGE_EXPECTED_COUNT, "מספר תמונות מתוכנן"),
        InventoryField(KEY_IMAGE_RECEIVED_COUNT, "מספר תמונות שהתקבלו"),
        InventoryField(KEY_IMAGE_PATHS, "נתיבי תמונות"),
        InventoryField(KEY_AUTO_PUBLISH_STARTED, "פרסום הופעל")
    )
    private val missingDetailKeys = listOf("price", "km", "vehicle_condition")


    fun process(
        context: Context,
        senderKey: String,
        text: String,
        audioFile: File?,
        extractedFields: Map<String, String> = emptyMap(),
        audioTranscriptionAttempted: Boolean = false
    ): ValidationResult {
        val trimmedText = text.trim()
        val state = loadState(context, senderKey)
        
        if (state[KEY_AUTO_PUBLISH_STARTED] == "true") {
            clearState(context, senderKey)
            state.clear()
            state.putAll(emptyState())
        }
        
        state["license_plate"] = normalizeFieldValue("license_plate", state["license_plate"])

        val initialMissingFields = missingFieldsForState(state)
        val initiallyReadyToPublish = isReadyToPublish(state, initialMissingFields)
        val expectedCount = state[KEY_IMAGE_EXPECTED_COUNT]?.toIntOrNull() ?: -1
        val receivedCount = state[KEY_IMAGE_RECEIVED_COUNT]?.toIntOrNull() ?: 0
        val imagesComplete = expectedCount >= 0 && receivedCount >= expectedCount

        val isCancel = isCancelCommand(trimmedText) || 
            (!initiallyReadyToPublish && trimmedText == "0") ||
            (initiallyReadyToPublish && imagesComplete && trimmedText == "1")

        if (isCancel) {
            clearState(context, senderKey)
            return ValidationResult(
                replyHebrew = "מבטל",
                missingFieldKeys = missingDetailKeys,
                updatedFieldKeys = emptyList(),
                readyToPublish = false,
                autoPublishRequested = false,
                vehicleData = emptyMap()
            )
        }

        if (initiallyReadyToPublish) {
            val isPublish = isPublishCommand(trimmedText) || (imagesComplete && trimmedText == "0")
            
            if (isPublish) {
                return requestAutoPublish(
                    context = context,
                    senderKey = senderKey,
                    state = state,
                    // If the user wants to keep the channel open for the login gate, do NOT reply with "מתחיל פרסום ביד2 עכשיו" because that consumes the notification intent.
                    reply = null
                )
            }

            val plannedImageCount = parseImageCountCommand(trimmedText)
            if (plannedImageCount != null) {
                return handleImageCountCommand(context, senderKey, state, plannedImageCount)
            }
        }

        val previousLicense = state["license_plate"].orEmpty()
        val missingBeforeExtraction = missingFieldsForState(state).map { it.key }
        val allExtractedFields = linkedMapOf<String, String>()
        allExtractedFields.putAll(extractFields(trimmedText))
        val positionalExtracted = extractPositionalFields(trimmedText, missingBeforeExtraction, allExtractedFields)
        positionalExtracted.forEach { (key, value) ->
            if (!allExtractedFields.containsKey(key)) {
                allExtractedFields[key] = value
            }
        }
        extractedFields.forEach { (key, value) ->
            if (value.isNotBlank()) allExtractedFields[key] = value
        }
        val shouldOverwrite = looksLikeExplicitCorrection(trimmedText)
        val updatedFieldKeys = mutableListOf<String>()

        allExtractedFields.forEach { (key, value) ->
            val normalizedValue = normalizeFieldValue(key, value)
            val currentValue = state[key]
            val shouldUpdateLicense = key == "license_plate" &&
                !normalizedValue.isNullOrBlank() &&
                currentValue != normalizedValue
            if (!normalizedValue.isNullOrBlank() && (currentValue.isNullOrBlank() || shouldOverwrite || shouldUpdateLicense)) {
                state[key] = normalizedValue
                updatedFieldKeys.add(key)
            }
        }

        val licenseChanged = previousLicense != state["license_plate"].orEmpty() &&
            state["license_plate"].orEmpty().isNotBlank()
        if (licenseChanged) {
            clearRegistryFields(state)
            clearImagePlanFields(state)
        }
        updatedFieldKeys.addAll(enrichFromVehicleRegistry(state, force = licenseChanged))

        saveState(context, senderKey, state)

        val missingFields = missingFieldsForState(state)
        val readyToPublish = state["data_found"] == "true" && missingFields.isEmpty()
        val audioNotice = if (audioFile != null && updatedFieldKeys.isEmpty()) {
            if (audioTranscriptionAttempted) {
                "התקבלה הודעה קולית, אך לא הצלחתי לתמלל ממנה פרטי רכב תקינים. נא לשלוח את הפרטים כטקסט או להקליט שוב בצורה ברורה."
            } else {
                "התקבלה הודעה קולית, אך לא הופעל תמלול אוטומטי. נא לשלוח את פרטי הרכב כטקסט."
            }
        } else {
            null
        }

        val isFirstTurn = licenseChanged || previousLicense.isBlank()

        return ValidationResult(
            replyHebrew = composeReply(state, missingFields, audioNotice, readyToPublish, isFirstTurn),
            missingFieldKeys = missingFields.map { it.key },
            updatedFieldKeys = updatedFieldKeys.distinct(),
            readyToPublish = readyToPublish,
            autoPublishRequested = false,
            vehicleData = vehicleData(state)
        )
    }

    fun processImage(
        context: Context,
        senderKey: String,
        imageFile: File
    ): ValidationResult {
        val state = loadState(context, senderKey)
        state["license_plate"] = normalizeFieldValue("license_plate", state["license_plate"])
        val missingFields = missingFieldsForState(state)
        val readyToPublish = isReadyToPublish(state, missingFields)

        if (!readyToPublish) {
            return ValidationResult(
                replyHebrew = "קיבלתי תמונה, אבל לפני העלאת תמונות צריך להשלים את פרטי הרכב.\n\n" +
                    composeReply(state, missingFields, null, false),
                missingFieldKeys = missingFields.map { it.key },
                updatedFieldKeys = emptyList(),
                readyToPublish = false,
                autoPublishRequested = false,
                vehicleData = vehicleData(state)
            )
        }

        if (state[KEY_AUTO_PUBLISH_STARTED] == "true") {
            return ValidationResult(
                replyHebrew = null,
                missingFieldKeys = emptyList(),
                updatedFieldKeys = emptyList(),
                readyToPublish = true,
                autoPublishRequested = false,
                vehicleData = vehicleData(state)
            )
        }

        val expectedCount = state[KEY_IMAGE_EXPECTED_COUNT]?.toIntOrNull() ?: 0

        val imagePaths = parseImagePaths(state[KEY_IMAGE_PATHS])
        val existingNames = imagePaths.map { File(it).name.lowercase(Locale.getDefault()) }.toSet()
        val fileName = imageFile.name.lowercase(Locale.getDefault())

        if (existingNames.contains(fileName) || imagePaths.contains(imageFile.absolutePath)) {
            return ValidationResult(
                replyHebrew = null,
                missingFieldKeys = emptyList(),
                updatedFieldKeys = emptyList(),
                readyToPublish = true,
                autoPublishRequested = false,
                vehicleData = vehicleData(state)
            )
        }

        // Strong constraint: never upload more than expected count
        if (expectedCount > 0 && imagePaths.size >= expectedCount) {
            return ValidationResult(
                replyHebrew = null,
                missingFieldKeys = emptyList(),
                updatedFieldKeys = emptyList(),
                readyToPublish = true,
                autoPublishRequested = false,
                vehicleData = vehicleData(state)
            )
        }

        imagePaths.add(imageFile.absolutePath)
        val finalPaths = if (expectedCount > 0 && imagePaths.size > expectedCount) {
            imagePaths.takeLast(expectedCount)
        } else {
            imagePaths
        }
        val receivedCount = finalPaths.size
        state[KEY_IMAGE_PATHS] = encodeImagePaths(finalPaths)
        state[KEY_IMAGE_RECEIVED_COUNT] = receivedCount.toString()
        saveState(context, senderKey, state)

        return if (expectedCount > 0) {
            if (receivedCount >= expectedCount) {
                ValidationResult(
                    replyHebrew = "התקבלו $receivedCount מתוך $expectedCount תמונות (עיבוד הושלם).\nלפרסום שלח 0\nלביטול השב ביטול",
                    missingFieldKeys = emptyList(),
                    updatedFieldKeys = listOf(KEY_IMAGE_PATHS, KEY_IMAGE_RECEIVED_COUNT),
                    readyToPublish = true,
                    autoPublishRequested = false,
                    vehicleData = vehicleData(state)
                )
            } else {
                ValidationResult(
                    replyHebrew = "נקלטה תמונה $receivedCount מתוך $expectedCount, מעבד...",
                    missingFieldKeys = emptyList(),
                    updatedFieldKeys = listOf(KEY_IMAGE_PATHS, KEY_IMAGE_RECEIVED_COUNT),
                    readyToPublish = true,
                    autoPublishRequested = false,
                    vehicleData = vehicleData(state)
                )
            }
        } else {
            ValidationResult(
                replyHebrew = null,
                missingFieldKeys = emptyList(),
                updatedFieldKeys = listOf(KEY_IMAGE_PATHS, KEY_IMAGE_RECEIVED_COUNT),
                readyToPublish = true,
                autoPublishRequested = false,
                vehicleData = vehicleData(state)
            )
        }
    }

    private fun handleImageCountCommand(
        context: Context,
        senderKey: String,
        state: MutableMap<String, String?>,
        plannedImageCount: Int
    ): ValidationResult {
        state[KEY_IMAGE_EXPECTED_COUNT] = plannedImageCount.toString()
        state[KEY_AUTO_PUBLISH_STARTED] = null

        if (plannedImageCount == 0) {
            state[KEY_IMAGE_PATHS] = null
            state[KEY_IMAGE_RECEIVED_COUNT] = "0"
            return requestAutoPublish(
                context = context,
                senderKey = senderKey,
                state = state,
                reply = "מתחיל פרסום ביד2 עכשיו בלי תמונות."
            )
        }

        // Strong constraint: reset image paths and wait for exactly plannedImageCount images from WhatsApp
        state[KEY_IMAGE_PATHS] = encodeImagePaths(emptyList())
        state[KEY_IMAGE_RECEIVED_COUNT] = "0"
        saveState(context, senderKey, state)

        return ValidationResult(
            replyHebrew = "ממתין להעלאת $plannedImageCount תמונות",
            missingFieldKeys = emptyList(),
            updatedFieldKeys = listOf(KEY_IMAGE_EXPECTED_COUNT, KEY_IMAGE_RECEIVED_COUNT, KEY_IMAGE_PATHS),
            readyToPublish = true,
            autoPublishRequested = false,
            vehicleData = vehicleData(state)
        )
    }

    private fun requestAutoPublish(
        context: Context,
        senderKey: String,
        state: MutableMap<String, String?>,
        reply: String?
    ): ValidationResult {
        val missingFields = missingFieldsForState(state)
        val readyToPublish = isReadyToPublish(state, missingFields)
        if (!readyToPublish) {
            return ValidationResult(
                replyHebrew = composeReply(state, missingFields, null, false),
                missingFieldKeys = missingFields.map { it.key },
                updatedFieldKeys = emptyList(),
                readyToPublish = false,
                autoPublishRequested = false,
                vehicleData = vehicleData(state)
            )
        }

        val expected = state[KEY_IMAGE_EXPECTED_COUNT]?.toIntOrNull() ?: 0
        var currentImages = parseImagePaths(state[KEY_IMAGE_PATHS])
        if (expected > 0) {
            if (currentImages.size < expected) {
                return ValidationResult(
                    replyHebrew = "עדיין חסרות ${expected - currentImages.size} תמונות. התקבלו ${currentImages.size} מתוך $expected. יש להעלות בדיוק $expected תמונות.",
                    missingFieldKeys = emptyList(),
                    updatedFieldKeys = emptyList(),
                    readyToPublish = false,
                    autoPublishRequested = false,
                    vehicleData = vehicleData(state)
                )
            } else if (currentImages.size > expected) {
                currentImages = currentImages.takeLast(expected).toMutableList()
                state[KEY_IMAGE_PATHS] = encodeImagePaths(currentImages)
                state[KEY_IMAGE_RECEIVED_COUNT] = expected.toString()
                saveState(context, senderKey, state)
            }
        }

        state[KEY_AUTO_PUBLISH_STARTED] = "true"
        saveState(context, senderKey, state)

        return ValidationResult(
            replyHebrew = reply,
            missingFieldKeys = emptyList(),
            updatedFieldKeys = listOf(KEY_AUTO_PUBLISH_STARTED),
            readyToPublish = true,
            autoPublishRequested = true,
            vehicleData = vehicleData(state)
        )
    }

    private fun isReadyToPublish(
        state: Map<String, String?>,
        missingFields: List<InventoryField> = missingFieldsForState(state)
    ): Boolean {
        return state["data_found"] == "true" && missingFields.isEmpty()
    }

    fun isImageCountCommand(text: String): Boolean {
        return parseImageCountCommand(text) != null
    }

    private fun parseImageCountCommand(text: String): Int? {
        val match = Regex("""^\s*(\d{1,2})\s*(?:תמונה|תמונות|photos?|images?)?\s*$""", RegexOption.IGNORE_CASE)
            .find(text)
            ?: return null
        return match.groupValues[1].toIntOrNull()?.takeIf { it in 0..30 }
    }

    private fun isCancelCommand(text: String): Boolean {
        val normalized = text.trim().lowercase()
        return normalized == "ביטול" ||
            normalized == "בטל" ||
            normalized == "cancel" ||
            normalized == "stop"
    }

    private fun isPublishCommand(text: String): Boolean {
        val normalized = text.trim().lowercase()
        return normalized == "פרסום" ||
            normalized == "פרסם" ||
            normalized == "publish"
    }

    private fun normalizeFieldValue(key: String, value: String?): String? {
        val trimmed = value?.trim()?.takeIf { it.isNotBlank() && it != "null" } ?: return null
        return when (key) {
            "license_plate" -> trimmed.digitsOnly().takeIf { it.length in 5..8 }
            "test_month", "month" -> normalizeMonth(trimmed)
            "test_year", "year" -> normalizeYear(trimmed) ?: trimmed.digitsOnly().takeIf { it.isNotBlank() }
            "km", "price" -> trimmed.digitsOnly().takeIf { it.isNotBlank() }
            "current_ownership", "previous_ownership" -> canonicalOwnership(trimmed) ?: trimmed
            "vehicle_condition" -> canonicalVehicleCondition(trimmed)
            "gear_type" -> normalizeGear(trimmed)
            "data_found" -> trimmed
            else -> trimmed
        }
    }

    private fun clearRegistryFields(state: MutableMap<String, String?>) {
        listOf(
            "maker",
            "model",
            "year",
            "fuel_type",
            "color",
            "month",
            "test_month",
            "test_year",
            "current_ownership",
            "gear_type",
            "data_found"
        ).forEach { state[it] = null }
    }

    private fun clearImagePlanFields(state: MutableMap<String, String?>) {
        state[KEY_IMAGE_EXPECTED_COUNT] = null
        state[KEY_IMAGE_RECEIVED_COUNT] = null
        state[KEY_IMAGE_PATHS] = null
        state[KEY_AUTO_PUBLISH_STARTED] = null
    }

    private fun enrichFromVehicleRegistry(
        state: MutableMap<String, String?>,
        force: Boolean
    ): List<String> {
        val license = state["license_plate"].orEmpty()
        if (license.isBlank()) return emptyList()
        if (!force && state["data_found"] == "true") return emptyList()

        val updated = mutableListOf<String>()
        val lookup = fetchVehicleRegistryData(license)
        if (lookup == null) {
            if (state["data_found"] != "error") {
                state["data_found"] = "error"
                updated.add("data_found")
            }
            return updated
        }

        if (!lookup.found) {
            if (state["data_found"] != "false") {
                state["data_found"] = "false"
                updated.add("data_found")
            }
            return updated
        }

        lookup.fields.forEach { (key, value) ->
            val normalized = normalizeFieldValue(key, value)
            val currentValue = state[key]
            if (!normalized.isNullOrBlank() && (force || currentValue.isNullOrBlank())) {
                if (currentValue != normalized) {
                    state[key] = normalized
                    updated.add(key)
                }
            }
        }

        if (state["data_found"] != "true") {
            state["data_found"] = "true"
            updated.add("data_found")
        }

        return updated
    }

    private fun fetchVehicleRegistryData(license: String): RegistryLookup? {
        return try {
            val filters = JSONObject().put("mispar_rechev", JSONArray().put(license))
            val url = "$DATA_GOV_SEARCH_URL?resource_id=$VEHICLE_RESOURCE_ID&filters=${Uri.encode(filters.toString())}"
            val json = requestJson(url) ?: return null
            val records = json.optJSONObject("result")?.optJSONArray("records") ?: return RegistryLookup(false)
            if (records.length() == 0) return RegistryLookup(false)

            val record = records.optJSONObject(0) ?: return RegistryLookup(false)
            val result = linkedMapOf<String, String>()
            putIfNotBlank(result, "maker", record.optCleanString("tozeret_nm"))
            putIfNotBlank(result, "model", firstRecordValue(record, "kinuy_mishari", "degem_nm"))
            putIfNotBlank(result, "year", record.optCleanString("shnat_yitzur"))
            putIfNotBlank(result, "fuel_type", record.optCleanString("sug_delek_nm"))

            val fullColor = record.optCleanString("tzeva_rechev")
            putIfNotBlank(result, "color", fullColor?.split(Regex("\\s+"))?.firstOrNull())

            val roadDate = record.optCleanString("moed_aliya_lakvish")
            putIfNotBlank(result, "month", extractMonthFromRegistryDate(roadDate))

            val testDate = record.optCleanString("tokef_dt")
            val testParts = testDate?.split("-")
            if (testParts != null && testParts.size >= 2) {
                putIfNotBlank(result, "test_year", testParts[0])
                putIfNotBlank(result, "test_month", testParts[1])
            }

            val ownership = record.optCleanString("baalut")?.let { if (it == "פרטי") "פרטית" else it }
            putIfNotBlank(result, "current_ownership", ownership)

            putIfNotBlank(result, "gear_type", fetchGearType(record))

            RegistryLookup(found = true, fields = result)
        } catch (e: Exception) {
            Log.e("WA-Validator", "Failed to fetch vehicle registry data", e)
            null
        }
    }

    private fun fetchGearType(vehicleRecord: JSONObject): String? {
        val filters = JSONObject()
        putFilterIfPresent(filters, "degem_nm", vehicleRecord.optCleanString("degem_nm"))
        putFilterIfPresent(filters, "tozeret_cd", vehicleRecord.optCleanString("tozeret_cd"))
        putFilterIfPresent(filters, "degem_cd", vehicleRecord.optCleanString("degem_cd"))
        putFilterIfPresent(filters, "sug_degem", vehicleRecord.optCleanString("sug_degem"))

        val year = vehicleRecord.optCleanString("shnat_yitzur")
        if (!year.isNullOrBlank()) {
            filters.put("shnat_yitzur", year.toIntOrNull() ?: year)
        }
        if (filters.length() == 0) return null

        val url = "$DATA_GOV_SEARCH_URL?resource_id=$GEAR_RESOURCE_ID&filters=${Uri.encode(filters.toString())}"
        val json = requestJson(url) ?: return null
        val records = json.optJSONObject("result")?.optJSONArray("records") ?: return null
        if (records.length() == 0) return null

        val automatic = records.optJSONObject(0)?.opt("automatic_ind")?.toString()
        return if (automatic == "0") "שידור ידני" else "הילוכים אוטומטיים"
    }

    private fun requestJson(url: String): JSONObject? {
        val connection = (URL(url).openConnection() as HttpURLConnection).apply {
            requestMethod = "GET"
            connectTimeout = 15000
            readTimeout = 30000
            setRequestProperty("Accept", "application/json")
        }

        return try {
            val code = connection.responseCode
            val responseText = readHttpResponse(connection, code)
            if (code !in 200..299) {
                Log.e("WA-Validator", "data.gov.il request failed: $code $responseText")
                return null
            }
            JSONObject(responseText)
        } finally {
            connection.disconnect()
        }
    }

    private fun readHttpResponse(connection: HttpURLConnection, responseCode: Int): String {
        val stream = if (responseCode in 200..299) connection.inputStream else connection.errorStream
        return stream?.bufferedReader()?.use { it.readText() }.orEmpty()
    }

    private fun putFilterIfPresent(filters: JSONObject, key: String, value: String?) {
        if (!value.isNullOrBlank()) {
            filters.put(key, value.toIntOrNull() ?: value)
        }
    }

    private fun firstRecordValue(record: JSONObject, vararg keys: String): String? {
        keys.forEach { key ->
            val value = record.optCleanString(key)
            if (!value.isNullOrBlank()) return value
        }
        return null
    }

    private fun extractMonthFromRegistryDate(value: String?): String? {
        if (value.isNullOrBlank()) return null
        if (!value.contains("-")) return normalizeMonth(value)
        val parts = value.split("-")
        val month = when {
            parts.size >= 3 -> parts[1]
            parts.size >= 2 -> parts.last()
            else -> value
        }
        return normalizeMonth(month)
    }

    private fun missingFieldsForState(state: Map<String, String?>): List<InventoryField> {
        val licenseField = fields.first { it.key == "license_plate" }
        if (state["license_plate"].isNullOrBlank()) return listOf(licenseField)
        val kmVal = state["km"]?.toIntOrNull()
        val kmTestVal = state["kilometer_test_aharon"]?.toIntOrNull()
        val isKmInvalid = kmVal != null && kmTestVal != null && kmVal <= kmTestVal

        return missingDetailKeys
            .mapNotNull { key -> fields.firstOrNull { it.key == key } }
            .filter { field -> state[field.key].isNullOrBlank() || (field.key == "km" && isKmInvalid) }
    }

    private fun vehicleData(state: Map<String, String?>): Map<String, String> {
        val data = linkedMapOf<String, String>()
        fields.forEach { field ->
            val value = state[field.key]
            if (!value.isNullOrBlank()) data[field.key] = value
        }
        return data
    }

    private fun parseImagePaths(rawValue: String?): MutableList<String> {
        if (rawValue.isNullOrBlank()) return mutableListOf()
        return try {
            val json = JSONArray(rawValue)
            MutableList(json.length()) { index ->
                json.optString(index).trim()
            }.filter { it.isNotBlank() }.toMutableList()
        } catch (e: Exception) {
            rawValue.split("|")
                .map { it.trim() }
                .filter { it.isNotBlank() }
                .toMutableList()
        }
    }

    private fun encodeImagePaths(paths: List<String>): String {
        val json = JSONArray()
        paths.distinct().forEach { path -> json.put(path) }
        return json.toString()
    }

    private fun extractFields(text: String): Map<String, String> {
        if (text.isBlank()) return emptyMap()

        val result = linkedMapOf<String, String>()

        putIfNotBlank(result, "license_plate", extractLicensePlate(text))

        val testDate = Regex("""(?:טסט|test)[^\d]{0,20}(\d{1,2})\s*[./\-]\s*(\d{2,4})""", RegexOption.IGNORE_CASE)
            .find(text)
        if (testDate != null) {
            putIfNotBlank(result, "test_month", normalizeMonth(testDate.groupValues[1]))
            putIfNotBlank(result, "test_year", normalizeYear(testDate.groupValues[2]))
        }
        putIfNotBlank(result, "test_month", findMonthAfterLabel(text, """(?:חודש\s*טסט|חודש)"""))
        putIfNotBlank(result, "test_year", findYearAfterLabel(text, """(?:שנת\s*טסט|שנה\s*טסט|שנתון\s*טסט)"""))

        putIfNotBlank(result, "hand", extractHand(text))
        putIfNotBlank(result, "current_ownership", extractOwnership(text, """(?:בעלות\s*נוכחית|בעלים\s*נוכחי)"""))
        putIfNotBlank(result, "previous_ownership", extractOwnership(text, """(?:בעלות\s*קודמת|בעלים\s*קודמים|בעלים\s*קודם)"""))
        putIfNotBlank(result, "km", extractKm(text))
        putIfNotBlank(result, "price", extractPrice(text))
        putIfNotBlank(result, "vehicle_condition", extractVehicleCondition(text))
        putIfNotBlank(result, "description", extractDescription(text))
        putIfNotBlank(result, "gear_type", extractGear(text))

        return result
    }

    private fun extractLicensePlate(text: String): String? {
        val explicit = Regex(
            """(?:מספר\s*(?:רכב|רישוי)?|לוחית(?:\s*רישוי)?|רישוי|license)[^\d]{0,16}(\d[\d\s\-]{5,10}\d)""",
            RegexOption.IGNORE_CASE
        ).find(text)
        val explicitDigits = explicit?.groupValues?.getOrNull(1)?.digitsOnly()
        if (explicitDigits != null && explicitDigits.length in 7..8) return explicitDigits

        Regex("""(?<!\d)(\d[\d\s\-]{5,10}\d)(?!\d)""").findAll(text).forEach { match ->
            val candidate = match.groupValues[1].digitsOnly()
            if (candidate.length in 7..8) return candidate
        }

        return null
    }

    private fun findMonthAfterLabel(text: String, labelPattern: String): String? {
        val value = Regex("""$labelPattern\s*[:=\-]?\s*(\d{1,2})""", RegexOption.IGNORE_CASE)
            .find(text)
            ?.groupValues
            ?.getOrNull(1)
        return normalizeMonth(value)
    }

    private fun findYearAfterLabel(text: String, labelPattern: String): String? {
        val value = Regex("""$labelPattern\s*[:=\-]?\s*(\d{2,4})""", RegexOption.IGNORE_CASE)
            .find(text)
            ?.groupValues
            ?.getOrNull(1)
        return normalizeYear(value)
    }

    private fun extractHand(text: String): String? {
        val raw = Regex(
            """(?:יד|hand)\s*[:=\-]?\s*(ראשונה|שניה|שנייה|שלישית|רביעית|חמישית|\d{1,2})""",
            RegexOption.IGNORE_CASE
        ).find(text)?.groupValues?.getOrNull(1)?.trim() ?: return null

        return when {
            raw.contains("ראש") -> "1"
            raw.contains("שני") || raw.contains("שניי") -> "2"
            raw.contains("שליש") -> "3"
            raw.contains("רביע") -> "4"
            raw.contains("חמיש") -> "5"
            else -> raw.digitsOnly().takeIf { it.isNotBlank() }
        }
    }

    private fun extractOwnership(text: String, labelPattern: String): String? {
        val segment = Regex("""$labelPattern\s*[:=\-]?\s*([^,.;\n]+)""", RegexOption.IGNORE_CASE)
            .find(text)
            ?.groupValues
            ?.getOrNull(1)
            ?: return null
        return canonicalOwnership(segment)
    }

    private fun canonicalOwnership(value: String): String? {
        val normalized = value.trim()
        return when {
            normalized.contains("פרטי") || normalized.contains("פרטית") -> "פרטית"
            normalized.contains("חברה") -> "חברה"
            normalized.contains("ליסינג") -> "ליסינג"
            normalized.contains("השכרה") -> "השכרה"
            normalized.contains("מונית") -> "מונית"
            normalized.contains("לימוד") -> "לימוד נהיגה"
            normalized.contains("ייבוא אישי") || normalized.contains("יבוא אישי") -> "ייבוא אישי"
            normalized.contains("ייבוא מקביל") || normalized.contains("יבוא מקביל") -> "ייבוא מקביל"
            normalized.contains("ממשל") -> "ממשלתי"
            else -> null
        }
    }

    private fun extractKm(text: String): String? {
        val labelFirst = Regex(
            """(?:קילומטראז'?|קילומטרים|ק"מ|קמ|km)\s*[:=\-]?\s*([\d,.\s]{2,})(?:\s*אלף)?""",
            RegexOption.IGNORE_CASE
        ).find(text)
        val valueFirst = Regex(
            """([\d,.\s]{2,})(?:\s*אלף)?\s*(?:קילומטראז'?|קילומטרים|ק"מ|קמ|km)""",
            RegexOption.IGNORE_CASE
        ).find(text)
        val match = labelFirst ?: valueFirst ?: return null

        val segment = match.value
        val digits = match.groupValues[1].digitsOnly()
        if (digits.isBlank()) return null

        return if (segment.contains("אלף") && digits.length <= 3) {
            (digits.toIntOrNull()?.times(1000))?.toString()
        } else {
            digits
        }
    }

    private fun extractPrice(text: String): String? {
        val labeledMatch = Regex(
            """(?:מחיר|price)\s*[:=\-]?\s*([\d,.\s]{2,})(?:\s*אלף)?""",
            RegexOption.IGNORE_CASE
        ).find(text)
        val labeledDigits = labeledMatch?.groupValues?.getOrNull(1)?.digitsOnly()
        if (!labeledDigits.isNullOrBlank()) {
            return if (labeledMatch.value.contains("אלף") && labeledDigits.length <= 3) {
                (labeledDigits.toIntOrNull()?.times(1000))?.toString()
            } else {
                labeledDigits
            }
        }

        val currencyMatch = Regex(
            """([\d,.\s]{2,})(?:\s*אלף)?\s*(?:₪|ש"ח|שח|nis)""",
            RegexOption.IGNORE_CASE
        ).find(text) ?: return null
        val digits = currencyMatch.groupValues[1].digitsOnly()
        if (digits.isBlank()) return null
        return if (currencyMatch.value.contains("אלף") && digits.length <= 3) {
            (digits.toIntOrNull()?.times(1000))?.toString()
        } else {
            digits
        }
    }

    private fun extractVehicleCondition(text: String): String? {
        val labeled = Regex(
            """(?:מצב(?:\s*(?:כללי|הרכב)?)?|condition)\s*[:=\-]?\s*([^,.;\n]+)""",
            RegexOption.IGNORE_CASE
        ).find(text)?.groupValues?.getOrNull(1)
        val labeledCondition = canonicalVehicleCondition(labeled)
        if (!labeledCondition.isNullOrBlank()) return labeledCondition

        return canonicalVehicleCondition(text)
    }

    private fun canonicalVehicleCondition(value: String?): String? {
        val normalized = value?.trim()?.lowercase()?.takeIf { it.isNotBlank() } ?: return null
        return when {
            normalized.contains("לא טוב") ||
                normalized.contains("גרוע") ||
                normalized.contains("בעיית") -> "גרוע"
            normalized.contains("טוב מאוד") ||
                normalized.contains("טובה מאוד") -> "טוב מאוד"
            normalized.contains("מצוין") ||
                normalized.contains("מצויין") ||
                normalized.contains("מעולה") -> "מצוין"
            normalized.contains("כמו חדש") -> "כמו חדש"
            normalized.contains("חדש") -> "חדש"
            normalized.contains("סביר") -> "סביר"
            normalized.contains("טוב") ||
                normalized.contains("טובה") ||
                normalized == "good" ||
                normalized == "ok" ||
                normalized == "great" -> "טוב"
            else -> null
        }
    }

    private fun extractPositionalFields(
        text: String,
        missingKeys: List<String>,
        explicitExtracted: Map<String, String>
    ): Map<String, String> {
        if (text.isBlank() || missingKeys.isEmpty()) return emptyMap()

        val remainingMissing = missingKeys.filter { key ->
            !explicitExtracted.containsKey(key) && explicitExtracted[key].isNullOrBlank()
        }
        if (remainingMissing.isEmpty()) return emptyMap()

        var rawTokens = text.split(Regex("""[\r\n]+"""))
            .map { it.trim() }
            .filter { it.isNotBlank() }

        if (rawTokens.size == 1 && rawTokens.first().contains(Regex("""[,;/]"""))) {
            rawTokens = rawTokens.first().split(Regex("""[,;/]+"""))
                .map { it.trim() }
                .filter { it.isNotBlank() }
        } else if (rawTokens.size == 1 && rawTokens.first().contains(Regex("""\s+"""))) {
            rawTokens = rawTokens.first().split(Regex("""\s+"""))
                .map { it.trim() }
                .filter { it.isNotBlank() }
        }

        val unconsumed = rawTokens.filter { token ->
            val extracted = extractFields(token)
            extracted.isEmpty()
        }
        if (unconsumed.isEmpty()) return emptyMap()

        val result = linkedMapOf<String, String>()

        if (unconsumed.size == 1) {
            val token = unconsumed.first()
            val digits = token.digitsOnly()
            val num = digits.toLongOrNull()
            if (num != null && num > 0L) {
                if (num <= 15L && remainingMissing.contains("hand")) {
                    result["hand"] = "$num"
                    return result
                }
                if (num >= 70000L && remainingMissing.contains("km")) {
                    result["km"] = digits
                    return result
                }
                if (remainingMissing.contains("km") && !remainingMissing.contains("price")) {
                    result["km"] = digits
                    return result
                }
                if (remainingMissing.contains("price")) {
                    result["price"] = digits
                    return result
                }
            }
        }

        if (unconsumed.size == remainingMissing.size) {
            for (i in remainingMissing.indices) {
                val key = remainingMissing[i]
                val token = unconsumed[i]
                val matched = tryMatchTokenToKey(token, key)
                if (matched != null) {
                    result[key] = matched
                }
            }
        } else {
            var tokenIdx = 0
            for (key in remainingMissing) {
                if (tokenIdx >= unconsumed.size) break
                val token = unconsumed[tokenIdx]
                val matched = tryMatchTokenToKey(token, key)
                if (matched != null) {
                    result[key] = matched
                    tokenIdx++
                }
            }
        }

        return result
    }

    private fun tryMatchTokenToKey(token: String, key: String): String? {
        val clean = token.trim()
        if (clean.isBlank()) return null
        val digits = clean.digitsOnly()

        return when (key) {
            "price", "km" -> {
                if (digits.isNotBlank()) {
                    val num = digits.toLongOrNull()
                    if (num != null && num > 0) digits else null
                } else null
            }
            "hand" -> {
                extractHand(clean)
            }
            "vehicle_condition" -> {
                canonicalVehicleCondition(clean)
            }
            "month", "test_month" -> {
                normalizeMonth(digits)
            }
            "year", "test_year" -> {
                normalizeYear(digits)
            }
            "current_ownership", "previous_ownership" -> {
                canonicalOwnership(clean)
            }
            "gear_type" -> {
                normalizeGear(clean)
            }
            else -> null
        }
    }

    private fun extractDescription(text: String): String? {
        return Regex("""(?:תיאור|הערות|פירוט)\s*[:=\-]\s*(.+)""", RegexOption.IGNORE_CASE)
            .find(text)
            ?.groupValues
            ?.getOrNull(1)
            ?.substringBefore("\n")
            ?.trim()
            ?.take(240)
            ?.takeIf { it.isNotBlank() }
    }

    private fun extractGear(text: String): String? {
        return normalizeGear(text)
    }

    private fun normalizeGear(value: String?): String? {
        val normalized = value?.lowercase() ?: return null
        return when {
            normalized.contains("ידני") || normalized.contains("manual") -> "שידור ידני"
            normalized.contains("אוטומט") || normalized.contains("auto") -> "הילוכים אוטומטיים"
            else -> null
        }
    }

    private fun normalizeMonth(raw: String?): String? {
        val month = raw?.digitsOnly()?.toIntOrNull() ?: return null
        return month.takeIf { it in 1..12 }?.toString()
    }

    private fun normalizeYear(raw: String?): String? {
        val digits = raw?.digitsOnly().orEmpty()
        return when (digits.length) {
            2 -> "20$digits"
            4 -> digits
            else -> null
        }
    }

    private fun looksLikeExplicitCorrection(text: String): Boolean {
        return text.contains("עדכן") ||
            text.contains("עדכון") ||
            text.contains("שנה") ||
            text.contains("תיקון") ||
            text.contains("החלף") ||
            text.contains("update", ignoreCase = true) ||
            text.contains("replace", ignoreCase = true)
    }

    private fun composeReply(
        state: Map<String, String?>,
        missingFields: List<InventoryField>,
        audioNotice: String?,
        readyToPublish: Boolean,
        isFirstTurn: Boolean = false
    ): String {
        val builder = StringBuilder()
        if (!audioNotice.isNullOrBlank()) {
            builder.append(audioNotice).append("\n\n")
        }

        val license = state["license_plate"].orEmpty()
        val dataStatus = state["data_found"].orEmpty()

        when {
            license.isBlank() -> {
                builder.append("קיבלתי את ההודעה. חסר מספר רכב כדי לבדוק את הנתונים במאגר.")
            }

            dataStatus == "false" -> {
                builder.append("לא נמצאו פרטי רכב במאגר עבור מספר רישוי $license. נא לבדוק את המספר או להשלים את הפרטים בשיחה.")
            }

            dataStatus == "error" -> {
                builder.append("כרגע לא הצלחתי למשוך נתונים מ-data.gov.il עבור מספר רישוי $license. נא להשלים את הפרטים בשיחה.")
            }

            readyToPublish -> {
                builder.append("פרטי הרכב לאישור:\n")
                appendVehicleDetails(builder, state)
                builder.append("\nהנתונים מוכנים. כמה תמונות תרצה להעלות?")
                builder.append("\nהשב מספר תמונות מתוכנן להעלאה (1-8), או 0 כדי להתחיל פרסום בלי תמונות.")
            }

            else -> {
                val title = vehicleTitle(state)
                if (isFirstTurn && title.isNotBlank()) {
                    builder.append("מצאתי את הרכב: ").append(title).append("\n\n")
                    builder.append("אנא השלם את הפרטים החסרים:\n")
                } else {
                    builder.append("חסרים עדיין הנתונים הבאים:\n")
                }
                missingFields.forEach { field ->
                    builder.append("- ").append(field.hebrewLabel).append("\n")
                }
                builder.append("\nנא להשלים רק את הפרטים החסרים.")
            }
        }

        builder.append(ADMIN_LINE)
        return builder.toString()
    }

    private fun vehicleTitle(state: Map<String, String?>): String {
        return listOf(state["maker"], state["model"], state["year"])
            .filter { !it.isNullOrBlank() }
            .joinToString(" ")
    }

    private fun appendVehicleDetails(builder: StringBuilder, state: Map<String, String?>) {
        val detailKeys = listOf(
            "license_plate",
            "maker",
            "model",
            "year",
            "fuel_type",
            "gear_type",
            "color",
            "month",
            "test_month",
            "test_year",
            "current_ownership",
            "previous_ownership",
            "hand",
            "km",
            "price",
            "vehicle_condition",
            "description"
        )

        detailKeys.forEach { key ->
            val field = fields.firstOrNull { it.key == key } ?: return@forEach
            val value = displayValue(key, state[key])
            if (!value.isNullOrBlank()) {
                builder.append(field.hebrewLabel)
                    .append(": ")
                    .append(value)
                    .append("\n")
            }
        }
    }

    private fun displayValue(key: String, rawValue: String?): String? {
        val value = rawValue?.takeIf { it.isNotBlank() }
        return when (key) {
            "price" -> value?.let { "$it ש\"ח" }
            "hand" -> value?.let { handToHebrew(it) }
            "previous_ownership" -> value ?: "פרטית"
            else -> value
        }
    }

    private fun handToHebrew(value: String): String {
        if (value.startsWith("יד")) return value
        return when (value.trim()) {
            "1" -> "יד ראשונה"
            "2" -> "יד שנייה"
            "3" -> "יד שלישית"
            "4" -> "יד רביעית"
            "5" -> "יד חמישית"
            else -> "יד $value"
        }
    }

    fun getExpectedImageCount(context: Context, senderKey: String): Int {
        return loadState(context, senderKey)[KEY_IMAGE_EXPECTED_COUNT]?.toIntOrNull() ?: 0
    }

    private fun loadState(context: Context, senderKey: String): MutableMap<String, String?> {
        synchronized(prefsLock) {
            val state = emptyState()
            val rawJson = prefs(context).getString(statePrefsKey(senderKey), null) ?: return state
            return try {
                val json = JSONObject(rawJson)
                fields.forEach { field ->
                    if (json.has(field.key) && !json.isNull(field.key)) {
                        state[field.key] = json.optString(field.key).takeIf { it.isNotBlank() }
                    }
                }
                state
            } catch (e: Exception) {
                state
            }
        }
    }

    private fun saveState(context: Context, senderKey: String, state: Map<String, String?>) {
        synchronized(prefsLock) {
            val json = JSONObject()
            fields.forEach { field ->
                val value = state[field.key]
                if (value.isNullOrBlank()) {
                    json.put(field.key, JSONObject.NULL)
                } else {
                    json.put(field.key, value)
                }
            }
            prefs(context).edit().putString(statePrefsKey(senderKey), json.toString()).apply()
        }
    }

    private fun clearState(context: Context, senderKey: String) {
        synchronized(prefsLock) {
            prefs(context).edit().remove(statePrefsKey(senderKey)).apply()
        }
    }

    private fun emptyState(): MutableMap<String, String?> {
        return fields.associate { it.key to null }.toMutableMap()
    }

    private fun prefs(context: Context): SharedPreferences {
        return context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
    }

    private fun statePrefsKey(senderKey: String): String {
        return "state_${senderKey.hashCode()}"
    }

    private fun putIfNotBlank(target: MutableMap<String, String>, key: String, value: String?) {
        if (!value.isNullOrBlank()) target[key] = value
    }

    private fun JSONObject.optCleanString(key: String): String? {
        if (!has(key) || isNull(key)) return null
        return opt(key)?.toString()?.trim()?.takeIf { it.isNotBlank() && it != "null" }
    }

    private fun String?.digitsOnly(): String {
        return this?.replace(Regex("""[^0-9]"""), "").orEmpty()
    }
}

data class IncomingWhatsAppMessage(
    val id: String,
    val notificationKey: String,
    val packageName: String,
    val senderName: String?,
    val senderKey: String,
    val conversationTitle: String?,
    val text: String?,
    val type: String,
    val timestamp: Long
)

data class ReplyHandle(
    val action: Notification.Action,
    val receivedAt: Long
)

data class AudioFileCandidate(
    val path: String,
    val timestamp: Long
)

data class ImageFileCandidate(
    val path: String,
    val timestamp: Long
)
