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
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * Persistent Foreground Service for Pirsumoto.
 * Keeps the application process alive 24/7 in the background so that
 * the Firebase chat receiver, remote control signaling, and automation listeners
 * remain continuously active and responsive even when the UI is closed.
 */
class PirsumotoBackgroundService : Service() {

    companion object {
        private const val TAG = "PirsumotoDaemon"
        const val CHANNEL_ID = "pirsumoto_background_service_channel"
        const val NOTIFICATION_ID = 20262
        const val ACTION_START = "com.pirsumoto.app.ACTION_START_DAEMON"
        const val ACTION_STOP = "com.pirsumoto.app.ACTION_STOP_DAEMON"

        @Volatile
        var isRunning = false
            private set

        fun start(context: Context) {
            val intent = Intent(context, PirsumotoBackgroundService::class.java).apply {
                action = ACTION_START
            }
            try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                Log.i(TAG, "PirsumotoBackgroundService start requested")
            } catch (e: Exception) {
                Log.e(TAG, "Failed to start PirsumotoBackgroundService: ${e.message}", e)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, PirsumotoBackgroundService::class.java).apply {
                action = ACTION_STOP
            }
            try {
                context.startService(intent)
            } catch (e: Exception) {
                Log.e(TAG, "Failed to stop PirsumotoBackgroundService: ${e.message}", e)
            }
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        if (action == ACTION_STOP) {
            stopDaemonForeground()
            stopSelf()
            return START_NOT_STICKY
        }

        startDaemonForeground()
        return START_STICKY
    }

    private fun startDaemonForeground() {
        try {
            val notification = buildNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            isRunning = true
            Log.i(TAG, "PirsumotoBackgroundService is now running in foreground (STICKY)")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to startDaemonForeground: ${e.message}", e)
        }
    }

    private fun stopDaemonForeground() {
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
        Log.w(TAG, "onTaskRemoved triggered (app swiped from recents). Restarting background service...")
        val restartIntent = Intent(applicationContext, PirsumotoBackgroundService::class.java).apply {
            action = ACTION_START
        }
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                applicationContext.startForegroundService(restartIntent)
            } else {
                applicationContext.startService(restartIntent)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to restart daemon onTaskRemoved: ${e.message}", e)
        }
    }

    override fun onDestroy() {
        isRunning = false
        super.onDestroy()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "Pirsumoto Background Service",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "Keeps Pirsumoto automation, chat and remote control active 24/7"
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
            .setContentText("ממתין לפקודות פרסום ושליטה מרחוק")
            .setSmallIcon(R.mipmap.launcher_icon)
            .setOngoing(true)
            .setContentIntent(pendingIntent)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .build()
    }
}
