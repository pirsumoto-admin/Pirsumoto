package com.pirsumoto.app

import android.app.Notification
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.util.Log

/**
 * Android 14+ allows swiping ongoing notifications. Restore the same notification
 * while its foreground service is alive, without starting any service. Entries
 * are process-local and removed before service shutdown, so a delayed dismissal
 * cannot revive a stopped service or a previous screen-capture session.
 * All callers (service lifecycle and BroadcastReceiver) run on the main thread.
 */
internal object ForegroundServiceNotifications {
    private const val ACTION_RESTORE = "com.pirsumoto.app.RESTORE_FOREGROUND_NOTIFICATION"
    private const val EXTRA_NOTIFICATION_ID = "notification_id"
    private val activeNotifications = mutableMapOf<Int, Notification>()

    fun dismissalIntent(context: Context, notificationId: Int): PendingIntent {
        val intent = Intent(context, ForegroundNotificationDismissedReceiver::class.java).apply {
            action = ACTION_RESTORE
            putExtra(EXTRA_NOTIFICATION_ID, notificationId)
        }
        return PendingIntent.getBroadcast(
            context,
            notificationId,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    fun track(notificationId: Int, notification: Notification) {
        activeNotifications[notificationId] = notification
    }

    fun forget(notificationId: Int) {
        activeNotifications.remove(notificationId)
    }

    fun restoreAfterDismissal(context: Context, intent: Intent) {
        if (intent.action != ACTION_RESTORE) return
        val id = intent.getIntExtra(EXTRA_NOTIFICATION_ID, -1)
        val notification = activeNotifications[id] ?: return
        try {
            context.getSystemService(NotificationManager::class.java)?.notify(id, notification)
        } catch (e: SecurityException) {
            // Notification permissions/settings remain under Android's control.
            Log.w("PirsumotoNotification", "Unable to restore foreground notification", e)
        }
    }
}

class ForegroundNotificationDismissedReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        ForegroundServiceNotifications.restoreAfterDismissal(context, intent)
    }
}
