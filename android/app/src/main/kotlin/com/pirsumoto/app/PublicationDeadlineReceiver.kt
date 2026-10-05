package com.pirsumoto.app

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/** Alarm and foreground timer share an attempt token; stale deliveries are ignored. */
class PublicationDeadlineReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        intent.getStringExtra("token")?.let { expire(context, it) }
    }

    companion object {
        private var channel: MethodChannel? = null
        private val handler = Handler(Looper.getMainLooper())
        private var foregroundExpiry: Runnable? = null
        private fun prefs(context: Context) = context.getSharedPreferences("publication_deadline", Context.MODE_PRIVATE)
        private fun alarm(context: Context, token: String): PendingIntent = PendingIntent.getBroadcast(
            context, 0, Intent(context, PublicationDeadlineReceiver::class.java)
                .setData(Uri.parse("pirsumoto://publication-expiry/${Uri.encode(token)}"))
                .putExtra("token", token), PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE)

        fun register(context: Context, engine: FlutterEngine) {
            val app = context.applicationContext
            channel = MethodChannel(engine.dartExecutor.binaryMessenger, "com.pirsumoto/publication_deadline")
            channel!!.setMethodCallHandler { call, result ->
                val token = call.argument<String>("token")
                if (token == null) { result.error("missing_token", "Publication token required", null); return@setMethodCallHandler }
                val manager = app.getSystemService(Context.ALARM_SERVICE) as AlarmManager
                when (call.method) {
                    "arm" -> {
                        val saved = prefs(app)
                        val oldToken = saved.getString("token", null)
                        if (oldToken != null && oldToken != token) manager.cancel(alarm(app, oldToken))
                        foregroundExpiry?.let { handler.removeCallbacks(it) }
                        val requested = (call.argument<Number>("milliseconds")?.toLong() ?: 900000L).coerceIn(0, 900000L)
                        // Re-arming after a restart does not grant a fresh 15 minutes.
                        val end = if (oldToken == token) saved.getLong("end", System.currentTimeMillis() + requested)
                                  else System.currentTimeMillis() + requested
                        val remaining = (end - System.currentTimeMillis()).coerceAtLeast(0)
                        saved.edit().putString("token", token).putLong("end", end).commit()
                        foregroundExpiry = Runnable { expire(app, token) }.also { handler.postDelayed(it, remaining) }
                        val at = SystemClock.elapsedRealtime() + remaining
                        if (Build.VERSION.SDK_INT < 31 || manager.canScheduleExactAlarms()) {
                            manager.setExactAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, alarm(app, token))
                        } else {
                            // The foreground timer remains exact; Android may defer the backup alarm in Doze.
                            manager.setAndAllowWhileIdle(AlarmManager.ELAPSED_REALTIME_WAKEUP, at, alarm(app, token))
                        }
                        result.success(null)
                    }
                    "cancel" -> {
                        manager.cancel(alarm(app, token))
                        if (prefs(app).getString("token", null) == token) {
                            foregroundExpiry?.let { handler.removeCallbacks(it) }
                            foregroundExpiry = null
                            prefs(app).edit().clear().commit()
                        }
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
        }

        private fun expire(context: Context, token: String) {
            if (prefs(context).getString("token", null) != token) return
            // Stop page activity immediately. Dart drains automation, detaches the
            // matching platform view, destroys it and returns to the home route.
            AutomationWebViewLifecycle.deactivate(token)
            channel?.invokeMethod("expired", token)
        }
    }
}
