package com.pirsumoto.app

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import android.util.Log
import android.view.WindowManager

class MainActivity : FlutterActivity() {
    // [WHATSAPP-DISABLED] WhatsApp bridge channels — disabled, app uses P2P chat instead.
    // private val WHATSAPP_CHANNEL = "com.pirsumoto/whatsapp_bridge"
    // private val WHATSAPP_EVENTS_CHANNEL = "com.pirsumoto/whatsapp_bridge/events"

    companion object {
        var isAppInForeground: Boolean = false
            private set
        var currentActivity: MainActivity? = null
            private set

        fun bringToForeground(context: Context): Boolean {
            Log.i("MainActivity", "bringToForeground called. Current isAppInForeground=$isAppInForeground")
            try {
                // 1. Wake up screen if interactive is false
                val pm = context.getSystemService(Context.POWER_SERVICE) as? PowerManager
                if (pm != null && !pm.isInteractive) {
                    @Suppress("DEPRECATION")
                    val wl = pm.newWakeLock(
                        PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
                        "pirsumoto:remote_control_wakeup"
                    )
                    wl.acquire(3000)
                }

                // 2. Determine target context (prefer active AccessibilityService or currentActivity, or fallback to context)
                val a11y = PirsumotoAccessibilityService.instance
                val targetContext = a11y ?: currentActivity ?: context

                val intent = Intent(targetContext, MainActivity::class.java).apply {
                    action = Intent.ACTION_MAIN
                    addCategory(Intent.CATEGORY_LAUNCHER)
                    flags = Intent.FLAG_ACTIVITY_NEW_TASK or
                            Intent.FLAG_ACTIVITY_REORDER_TO_FRONT or
                            Intent.FLAG_ACTIVITY_SINGLE_TOP
                }

                val flags = PendingIntent.FLAG_UPDATE_CURRENT or (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) PendingIntent.FLAG_IMMUTABLE else 0)
                val pi = PendingIntent.getActivity(targetContext, 9912, intent, flags)
                try {
                    pi.send()
                } catch (_: Exception) {
                    targetContext.startActivity(intent)
                }
                return true
            } catch (e: Exception) {
                Log.e("MainActivity", "Failed to bring app to foreground", e)
                return false
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        // [WHATSAPP-DISABLED] prepareForAutoPublishIntent is part of WhatsApp auto-publish flow.
        // prepareForAutoPublishIntent(intent)
        super.onCreate(savedInstanceState)
        currentActivity = this
        // Independent of Flutter/Firebase initialization and network availability.
        PirsumotoBackgroundService.start(applicationContext)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        hideSystemUI()
    }

    override fun onResume() {
        super.onResume()
        isAppInForeground = true
        currentActivity = this
        // Reassert foreground state (and its notification) on every app return.
        PirsumotoBackgroundService.start(applicationContext)
    }

    override fun onPause() {
        super.onPause()
        isAppInForeground = false
    }

    override fun onDestroy() {
        if (currentActivity == this) {
            currentActivity = null
            isAppInForeground = false
        }
        super.onDestroy()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        // [WHATSAPP-DISABLED] prepareForAutoPublishIntent is part of WhatsApp auto-publish flow.
        // prepareForAutoPublishIntent(intent)
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) {
            hideSystemUI()
        }
    }

    private fun hideSystemUI() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            window.setDecorFitsSystemWindows(false)
            window.insetsController?.let { controller ->
                controller.hide(android.view.WindowInsets.Type.statusBars() or android.view.WindowInsets.Type.navigationBars())
                controller.systemBarsBehavior = android.view.WindowInsetsController.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
            }
        } else {
            @Suppress("DEPRECATION")
            window.decorView.systemUiVisibility = (
                android.view.View.SYSTEM_UI_FLAG_IMMERSIVE_STICKY
                or android.view.View.SYSTEM_UI_FLAG_LAYOUT_STABLE
                or android.view.View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
                or android.view.View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN
                or android.view.View.SYSTEM_UI_FLAG_HIDE_NAVIGATION
                or android.view.View.SYSTEM_UI_FLAG_FULLSCREEN
            )
        }
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine =
        FlutterEngineManager.getOrCreateSharedEngine(context)

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // Plugins and channels are registered before Dart starts by the engine owner.
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // [WHATSAPP-DISABLED] WhatsAppBridgeEvents.detach() disabled.
        // WhatsAppBridgeEvents.detach()
        super.cleanUpFlutterEngine(flutterEngine)
    }

    // [WHATSAPP-DISABLED] prepareForAutoPublishIntent handled WhatsApp auto-publish wake-up.
    // Disabled: app no longer receives auto-publish triggers from WhatsApp.
    // private fun prepareForAutoPublishIntent(intent: Intent?) {
    //     if (!WhatsAppAutoPublishStore.captureIntent(intent)) return
    //     if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
    //         setShowWhenLocked(true)
    //         setTurnScreenOn(true)
    //         try {
    //             val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as android.app.KeyguardManager
    //             keyguardManager.requestDismissKeyguard(this, null)
    //         } catch (e: Exception) {
    //             Log.w("WA-AutoPublish", "Could not request keyguard dismiss", e)
    //         }
    //     } else {
    //         @Suppress("DEPRECATION")
    //         window.addFlags(
    //             WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
    //                 WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
    //                 WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
    //                 WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD
    //         )
    //     }
    // }

}
