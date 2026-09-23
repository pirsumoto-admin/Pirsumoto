package com.pirsumoto.app

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import android.util.Log
import androidx.core.app.NotificationCompat

/**
 * Dedicated Foreground Service for MediaProjection on Android 14+ (API 34+).
 * Must be active while WebRTC screen capture is streaming to prevent SecurityException.
 */
class RemoteControlCaptureService : Service() {

    companion object {
        private const val TAG = "RemoteCaptureService"
        const val CHANNEL_ID = "pirsumoto_remote_control_channel"
        const val NOTIFICATION_ID = 20261
        const val ACTION_START = "com.pirsumoto.app.ACTION_START_REMOTE_CAPTURE"
        const val ACTION_STOP = "com.pirsumoto.app.ACTION_STOP_REMOTE_CAPTURE"

        @Volatile
        var isRunning = false
            private set

        fun start(context: Context) {
            val intent = Intent(context, RemoteControlCaptureService::class.java).apply {
                action = ACTION_START
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stop(context: Context) {
            val intent = Intent(context, RemoteControlCaptureService::class.java).apply {
                action = ACTION_STOP
            }
            context.startService(intent)
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
            stopCaptureForeground()
            stopSelf()
            return START_NOT_STICKY
        }

        startCaptureForeground()
        return START_STICKY
    }

    private fun startCaptureForeground() {
        try {
            val notification = buildNotification()
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                startForeground(
                    NOTIFICATION_ID,
                    notification,
                    ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
                )
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
            ForegroundServiceNotifications.track(NOTIFICATION_ID, notification)
            isRunning = true
            Log.i(TAG, "RemoteControlCaptureService started in foreground")
        } catch (e: Exception) {
            ForegroundServiceNotifications.forget(NOTIFICATION_ID)
            isRunning = false
            Log.e(TAG, "Failed to startForeground: ${e.message}", e)
            stopSelf()
        }
    }

    private fun stopCaptureForeground() {
        ScreenCaptureFrameRepeater.stop()
        ForegroundServiceNotifications.forget(NOTIFICATION_ID)
        isRunning = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        Log.i(TAG, "RemoteControlCaptureService stopped")
    }

    override fun onDestroy() {
        ScreenCaptureFrameRepeater.stop()
        ForegroundServiceNotifications.forget(NOTIFICATION_ID)
        isRunning = false
        super.onDestroy()
    }

    private fun buildNotification(): Notification {
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("פרסומוטו - שליטה מרחוק פעילה")
            .setContentText("שיקוף מסך ושליטה פעילים מול הבקר")
            .setSmallIcon(R.drawable.ic_pirsumoto_notification)
            .setPriority(NotificationCompat.PRIORITY_LOW)
            .setOngoing(true)
            .setAutoCancel(false)
            .setOnlyAlertOnce(true)
            .setCategory(NotificationCompat.CATEGORY_SERVICE)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .setDeleteIntent(ForegroundServiceNotifications.dismissalIntent(this, NOTIFICATION_ID))
            .build()
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel(
                CHANNEL_ID,
                "שליטה מרחוק",
                NotificationManager.IMPORTANCE_LOW
            ).apply {
                description = "התראת שיקוף מסך ושליטה מרחוק"
            }
            val manager = getSystemService(NotificationManager::class.java)
            manager?.createNotificationChannel(channel)
        }
    }
}
