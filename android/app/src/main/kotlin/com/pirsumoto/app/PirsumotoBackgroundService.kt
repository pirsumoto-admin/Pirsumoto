package com.pirsumoto.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * Persistent Foreground Service for Pirsumoto.
 * Gives the remote-control/automation host foreground process priority.
 * START_STICKY lets Android recreate it after process reclamation; it does not
 * override a user force-stop or guarantee that the OS will never kill it.
 */
class PirsumotoBackgroundService : Service() {

    companion object {
        private const val TAG = "PirsumotoDaemon"
        const val CHANNEL_ID = "pirsumoto_background_service_channel"
        const val NOTIFICATION_ID = 20262
        const val ACTION_START = "com.pirsumoto.app.ACTION_START_DAEMON"
        const val ACTION_STOP = "com.pirsumoto.app.ACTION_STOP_DAEMON"

        private var instance: PirsumotoBackgroundService? = null
        private var receiverState = "starting"
        private var lastReceiverReport = 0L

        fun reportReceiverHealth(state: String) {
            receiverState = state
            lastReceiverReport = SystemClock.elapsedRealtime()
            instance?.refreshNotification()
        }

        @Volatile
        var isRunning = false
            private set

        /** Returns whether Android accepted the start request. */
        fun start(context: Context): Boolean {
            val intent = Intent(context, PirsumotoBackgroundService::class.java).apply {
                action = ACTION_START
            }
            return try {
                val component = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                Log.i(TAG, "PirsumotoBackgroundService start requested")
                component != null
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start PirsumotoBackgroundService: ${e.message}", e)
                false
            }
        }

        fun stop(context: Context) {
            try {
                // Stopping must not create a new service or require a permitted
                // background-service launch on Android 8+.
                context.stopService(Intent(context, PirsumotoBackgroundService::class.java))
            } catch (e: Exception) {
                Log.e(TAG, "Failed to stop PirsumotoBackgroundService: ${e.message}", e)
            }
        }
    }

    private val healthHandler = Handler(Looper.getMainLooper())
    private val healthCheck = object : Runnable {
        override fun run() {
            if (!isRunning) return
            refreshNotification()
            healthHandler.postDelayed(this, 30000)
        }
    }

    private val engineRetry = Runnable { if (isRunning) ensureReceiverEngine() }

    private fun ensureReceiverEngine() {
        healthHandler.removeCallbacks(engineRetry)
        try {
            FlutterEngineManager.getOrCreateSharedEngine(applicationContext)
        } catch (error: Exception) {
            Log.e(TAG, "Receiver engine startup failed; retrying in 10 seconds", error)
            reportReceiverHealth("error")
            healthHandler.postDelayed(engineRetry, 10000)
        }
    }

    private fun refreshNotification() {
        if (!isRunning) return
        val notification = buildNotification()
        getSystemService(NotificationManager::class.java)?.notify(NOTIFICATION_ID, notification)
        ForegroundServiceNotifications.track(NOTIFICATION_ID, notification)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        instance = this
        if (lastReceiverReport == 0L) lastReceiverReport = SystemClock.elapsedRealtime()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        if (action == ACTION_STOP) {
            stopDaemonForeground()
            stopSelf()
            return START_NOT_STICKY
        }

        // A null intent is expected when Android recreates a sticky service.
        if (!startDaemonForeground()) return START_NOT_STICKY
        ensureReceiverEngine()
        healthHandler.removeCallbacks(healthCheck)
        healthHandler.postDelayed(healthCheck, 30000)
        return START_STICKY
    }

    private fun startDaemonForeground(): Boolean {
        return try {
            val notification = buildNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            ForegroundServiceNotifications.track(NOTIFICATION_ID, notification)
            isRunning = true
            Log.i(TAG, "PirsumotoBackgroundService is now running in foreground (STICKY)")
            true
        } catch (e: Exception) {
            ForegroundServiceNotifications.forget(NOTIFICATION_ID)
            isRunning = false
            Log.e(TAG, "Failed to startDaemonForeground: ${e.message}", e)
            // Do not leave a failed startForegroundService request alive until
            // Android's foreground-promotion deadline crashes the process.
            stopSelf()
            false
        }
    }

    private fun stopDaemonForeground() {
        ForegroundServiceNotifications.forget(NOTIFICATION_ID)
        isRunning = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        Log.i(TAG, "PirsumotoBackgroundService stopped")
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        super.onTaskRemoved(rootIntent)
        // stopWithTask=false keeps this service running. A redundant background
        // start here can be rejected on Android 12+; system restarts use STICKY.
        Log.i(TAG, "Task removed; foreground service remains active")
    }

    override fun onDestroy() {
        healthHandler.removeCallbacks(healthCheck)
        healthHandler.removeCallbacks(engineRetry)
        instance = null
        stopDaemonForeground()
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Pirsumoto Background Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Pirsumoto automation, chat and remote control host"
                setShowBadge(false)
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }
    }

    private fun buildNotification(): Notification {
        val launchIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            launchIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT
        )

        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("פרסומוטו - שירות פעיל ברקע")
            .setContentText(when {
                lastReceiverReport > 0 && SystemClock.elapsedRealtime() - lastReceiverReport > 150000 ->
                    "אין אישור עדכני מהמאזין — יש לבדוק חיבור"
                receiverState == "ready" -> "תהליך הקבלה פעיל — חיבור השרת אומת"
                receiverState == "signed_out" -> "יש להתחבר לחשבון לקבלת פקודות"
                receiverState == "error" -> "המאזין אינו זמין — מנסה להתחבר מחדש"
                else -> "מאתחל את המאזין לשליטה מרחוק"
            })
            .setSmallIcon(R.drawable.ic_pirsumoto_notification)
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setContentIntent(pendingIntent)
            .setDeleteIntent(ForegroundServiceNotifications.dismissalIntent(this, NOTIFICATION_ID))
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }
}
