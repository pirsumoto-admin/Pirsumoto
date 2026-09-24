package com.pirsumoto.app

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.os.PowerManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import android.util.DisplayMetrics
import android.util.Log
import android.view.WindowManager

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.pirsumoto/accessibility"
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

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        AutomationWebViewLifecycle.register(flutterEngine)
        // [WHATSAPP-DISABLED] WhatsApp auto-publish intent capture disabled.
        // WhatsAppAutoPublishStore.captureIntent(intent)
        // [WHATSAPP-DISABLED] WhatsApp MethodChannel and EventChannel registration disabled.
        // val whatsappBridgeController = WhatsAppBridgeController(this)
        // MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WHATSAPP_CHANNEL).setMethodCallHandler { call, result ->
        //     whatsappBridgeController.handle(call, result)
        // }
        // EventChannel(flutterEngine.dartExecutor.binaryMessenger, WHATSAPP_EVENTS_CHANNEL).setStreamHandler(
        //     object : EventChannel.StreamHandler {
        //         override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        //             WhatsAppBridgeEvents.attach(events)
        //         }
        //         override fun onCancel(arguments: Any?) {
        //             WhatsAppBridgeEvents.detach()
        //         }
        //     }
        // )

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            
            if (call.method == "checkPermission") {
                if (PirsumotoAccessibilityService.instance != null) {
                    result.success(true)
                    return@setMethodCallHandler
                }

                val isEnabledInSettings = isAccessibilityServiceEnabled(context, PirsumotoAccessibilityService::class.java)
                if (isEnabledInSettings) {
                    // Give Android up to 500ms to bind the service instance if it just connected
                    var attempts = 0
                    while (PirsumotoAccessibilityService.instance == null && attempts < 10) {
                        try { Thread.sleep(50) } catch (_: Exception) {}
                        attempts++
                    }
                    Log.d("A11Y", "Accessibility enabled in settings. Instance connected: ${PirsumotoAccessibilityService.instance != null}")
                    result.success(true)
                    return@setMethodCallHandler
                }

                result.success(false)
                return@setMethodCallHandler
            }
            if (call.method == "openSettings") {
                val componentName = android.content.ComponentName(
                    context,
                    PirsumotoAccessibilityService::class.java
                )
                val componentNameStr = componentName.flattenToString()
                val bundle = android.os.Bundle()
                bundle.putString(":settings:fragment_args_key", componentNameStr)

                // Attempt 1: "Installed Apps/Services" submenu directly (Samsung, Pixel Android 13+)
                try {
                    val intent = android.content.Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS)
                    intent.setClassName("com.android.settings", "com.android.settings.Settings\$AccessibilityInstalledServiceActivity")
                    intent.flags = android.content.Intent.FLAG_ACTIVITY_NEW_TASK
                    intent.putExtra(":settings:fragment_args_key", componentNameStr)
                    intent.putExtra(":settings:show_fragment_args", bundle)
                    startActivity(intent)
                    result.success(true)
                    return@setMethodCallHandler
                } catch (e: Exception) {
                    Log.d("A11Y", "Direct Installed Apps routing failed", e)
                }

                // Attempt 2: Generic Accessibility Settings with Fragment arguments
                try {
                    val intent = android.content.Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS)
                    intent.flags = android.content.Intent.FLAG_ACTIVITY_NEW_TASK
                    intent.putExtra(":settings:fragment_args_key", componentNameStr)
                    intent.putExtra(":settings:show_fragment_args", bundle)
                    startActivity(intent)
                    result.success(true)
                    return@setMethodCallHandler
                } catch (e: Exception) {
                    Log.e("A11Y", "Fragment arg routing failed", e)
                }
                
                // Attempt 3: Pure generic fallback
                try {
                    val fallbackIntent = android.content.Intent(android.provider.Settings.ACTION_ACCESSIBILITY_SETTINGS)
                    fallbackIntent.flags = android.content.Intent.FLAG_ACTIVITY_NEW_TASK
                    startActivity(fallbackIntent)
                    result.success(true)
                } catch (e2: Exception) {
                    Log.e("A11Y", "Total failure to open accessibility settings", e2)
                    result.success(false)
                }
                return@setMethodCallHandler
            }

            if (call.method == "bringAppToForeground") {
                // [WHATSAPP-DISABLED] WhatsAppDaemonService.bringAppToForeground removed.
                // WhatsAppDaemonService.bringAppToForeground(context)
                MainActivity.bringToForeground(context)
                result.success(true)
                return@setMethodCallHandler
            }
            if (call.method == "isAppInForeground") {
                result.success(isAppInForeground)
                return@setMethodCallHandler
            }
            if (call.method == "startDaemonService") {
                result.success(PirsumotoBackgroundService.start(context))
                return@setMethodCallHandler
            }
            if (call.method == "stopDaemonService") {
                PirsumotoBackgroundService.stop(context)
                result.success(true)
                return@setMethodCallHandler
            }
            if (call.method == "isDaemonRunning") {
                result.success(PirsumotoBackgroundService.isRunning)
                return@setMethodCallHandler
            }

            if (call.method == "showToast") {
                val message = call.argument<String>("message") ?: ""
                android.os.Handler(android.os.Looper.getMainLooper()).post {
                    android.widget.Toast.makeText(context, message, android.widget.Toast.LENGTH_LONG).show()
                }
                result.success(true)
                return@setMethodCallHandler
            }

            if (call.method == "startCaptureAutoApproval") {
                val service = PirsumotoAccessibilityService.instance
                service?.startAutoApprovingCapture()
                result.success(service != null)
                return@setMethodCallHandler
            }
            if (call.method == "startRemoteCaptureService") {
                RemoteControlCaptureService.start(context)
                result.success(true)
                return@setMethodCallHandler
            }
            if (call.method == "isRemoteCaptureRunning") {
                result.success(RemoteControlCaptureService.isRunning)
                return@setMethodCallHandler
            }
            if (call.method == "startScreenFrameRepeater") {
                try {
                    ScreenCaptureFrameRepeater.start(requireNotNull(call.argument<String>("trackId")))
                    result.success(true)
                } catch (e: Exception) {
                    result.error("FRAME_REPEATER_FAILED", e.message, null)
                }
                return@setMethodCallHandler
            }
            if (call.method == "stopScreenFrameRepeater") {
                ScreenCaptureFrameRepeater.stop()
                result.success(true)
                return@setMethodCallHandler
            }
            if (call.method == "stopRemoteCaptureService") {
                RemoteControlCaptureService.stop(context)
                result.success(true)
                return@setMethodCallHandler
            }
            if (call.method == "getScreenDimensions") {
                val wm = context.getSystemService(Context.WINDOW_SERVICE) as WindowManager
                val (width, height, density) = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    val bounds = wm.currentWindowMetrics.bounds
                    Triple(bounds.width(), bounds.height(), context.resources.displayMetrics.density.toDouble())
                } else {
                    val dm = DisplayMetrics()
                    @Suppress("DEPRECATION")
                    wm.defaultDisplay.getRealMetrics(dm)
                    Triple(dm.widthPixels, dm.heightPixels, dm.density.toDouble())
                }
                result.success(mapOf(
                    "width" to width,
                    "height" to height,
                    "density" to density
                ))
                return@setMethodCallHandler
            }
            if (call.method == "getDeviceInfo") {
                val androidId = android.provider.Settings.Secure.getString(contentResolver, android.provider.Settings.Secure.ANDROID_ID) ?: ""
                result.success(mapOf(
                    "model" to Build.MODEL,
                    "manufacturer" to Build.MANUFACTURER,
                    "brand" to Build.BRAND,
                    "device" to Build.DEVICE,
                    "product" to Build.PRODUCT,
                    "sdkInt" to Build.VERSION.SDK_INT,
                    "androidId" to androidId
                ))
                return@setMethodCallHandler
            }

            val service = PirsumotoAccessibilityService.instance
            if (service == null) {
                result.error("UNAVAILABLE", "Accessibility Service not connected. Please enable it in Settings.", null)
                return@setMethodCallHandler
            }

            var rootNode = service.rootInActiveWindow
            if (call.argument<Boolean>("requireAppWindow") == true) {
                val power = getSystemService(Context.POWER_SERVICE) as PowerManager
                if (!power.isInteractive) {
                    try {
                        @Suppress("DEPRECATION")
                        val wl = power.newWakeLock(
                            PowerManager.SCREEN_BRIGHT_WAKE_LOCK or PowerManager.ACQUIRE_CAUSES_WAKEUP,
                            "pirsumoto:automation_wakeup"
                        )
                        wl.acquire(3000)
                    } catch (e: Exception) {
                        Log.w("A11Y", "Failed to acquire wakeup lock: $e")
                    }
                }

                val currentPkg = rootNode?.packageName?.toString()
                if (!isAppInForeground || (currentPkg != null && currentPkg != packageName)) {
                    result.error("AUTOMATION_INTERRUPTED", "Publication window is not active", null)
                    return@setMethodCallHandler
                }
                if (call.method == "checkAutomationWindow") {
                    result.success(true)
                    return@setMethodCallHandler
                }
            }
            if (rootNode == null && call.method != "injectTextNative" && call.method != "pressBack" && call.method != "pressHome" && call.method != "pressRecents" && call.method != "tapScreen" && call.method != "pasteText" && !call.method.startsWith("remote")) {
                result.error("UNAVAILABLE", "Cannot get root window node", null)
                return@setMethodCallHandler
            }
            rootNode?.refresh()

            when (call.method) {
                "findAndTap" -> {
                    val target = call.argument<String>("target") ?: ""
                    val targetInstance = call.argument<Int>("targetInstance") ?: 1
                    val threshold = call.argument<Double>("threshold") ?: 0.82
                    val deltaY = call.argument<Double>("deltaY") ?: 0.0

                    val matches = service.findBestHebrewMatches(rootNode!!, target, threshold)
                    if (matches.size >= targetInstance) {
                        val match = matches[targetInstance - 1]
                        
                        // First try semantic click
                        var clicked = service.clickNode(match.node)
                        if (!clicked) {
                            // Fallback to gesture tap
                            val bounds = match.bounds
                            bounds.offset(0, deltaY.toInt())
                            service.tapBounds(bounds)
                        }
                        result.success(true)
                    } else {
                        Log.d("A11Y", "Target '$target' not found (instance $targetInstance). Total matches: ${matches.size}")
                        result.success(false)
                    }
                }
                "enterText" -> {
                    val target = call.argument<String>("target") ?: ""
                    val targetInstance = call.argument<Int>("targetInstance") ?: 1
                    val value = call.argument<String>("value") ?: ""
                    val threshold = call.argument<Double>("threshold") ?: 0.82

                    val matches = service.findBestHebrewMatches(rootNode!!, target, threshold)
                    if (matches.size >= targetInstance) {
                        val match = matches[targetInstance - 1]
                        // We first focus and try semantic action
                        service.clickNode(match.node)
                        Thread.sleep(300) // Small wait for focus
                        
                        // Let's attempt to find the nearest editable child/sibling or tap and let Android keyboard handle it.
                        // Or we can just try setting text directly:
                        var entered = service.enterTextIntoNode(match.node, value)
                        if (!entered) {
                           // Try gesture tap first, then wait, but since we cannot inject characters directly without a keyboard service, 
                           // we rely on the AccessibilityNodeInfo ACTION_SET_TEXT which works on EditText nodes.
                           // If the node we matched is a layout wrapper, we search down for editable
                           var editableNode = findEditableChild(match.node)
                           if (editableNode != null) {
                               entered = service.enterTextIntoNode(editableNode, value)
                           }
                        }
                        
                        if (!entered) {
                             // Last resort, just tap it so focus works
                             service.tapBounds(match.bounds)
                        }
                        result.success(true) // We report true if we found the node at least
                    } else {
                        result.success(false)
                    }
                }
                "enterTextAtFocused" -> {
                    val value = call.argument<String>("value") ?: ""
                    // Try to find the focused node
                    fun findFocused(node: android.view.accessibility.AccessibilityNodeInfo?): android.view.accessibility.AccessibilityNodeInfo? {
                        if (node == null) return null
                        if (node.isFocused) return node
                        for (i in 0 until node.childCount) {
                            val f = findFocused(node.getChild(i))
                            if (f != null) return f
                        }
                        return null
                    }
                    val focused = rootNode?.findFocus(android.view.accessibility.AccessibilityNodeInfo.FOCUS_INPUT) ?: findFocused(rootNode)
                    
                    android.util.Log.d("A11Y", "Focused node: " + focused?.className + ", isEditable: " + focused?.isEditable)
                    
                    if (focused != null) {
                        var entered = service.enterTextIntoNode(focused, value)
                        if (!entered && focused.parent != null) {
                            entered = service.enterTextIntoNode(focused.parent, value)
                        }
                        result.success(entered)
                    } else {
                        // Fallback: Just find ANY node with className EditText or WebView and try to set text
                        result.success(false)
                    }
                }
                "injectTextNative" -> {
                    val value = call.argument<String>("value") ?: ""
                    Thread {
                        try {
                            val inst = android.app.Instrumentation()
                            inst.sendStringSync(value)
                            android.os.Handler(android.os.Looper.getMainLooper()).post {
                                result.success(true)
                            }
                        } catch (e: Exception) {
                            android.util.Log.e("A11Y", "Instrumentation failed", e)
                            // Fallback to Runtime input text
                            try {
                                Runtime.getRuntime().exec(arrayOf("input", "text", value))
                                android.os.Handler(android.os.Looper.getMainLooper()).post {
                                    result.success(true)
                                }
                            } catch (e2: Exception) {
                                android.os.Handler(android.os.Looper.getMainLooper()).post {
                                    result.success(false)
                                }
                            }
                        }
                    }.start()
                }
                "scrollNode" -> {
                    val percent = call.argument<Double>("percent") ?: 0.5
                    val displayMetrics = service.resources.displayMetrics
                    val width = displayMetrics.widthPixels.toFloat()
                    val height = displayMetrics.heightPixels.toFloat()
                    
                    val startX = width / 2f
                    val startY = height * 0.8f
                    val endY = startY - (height * percent).toFloat()
                    
                    if (call.argument<Boolean>("requireAppWindow") == true) {
                        service.performAutomationGesture(startX, startY, startX, endY, 400L) { completed ->
                            if (completed) result.success(true)
                            else result.error("AUTOMATION_INTERRUPTED", "Scroll gesture was canceled or rejected", null)
                        }
                    } else {
                        result.success(service.swipe(startX, startY, startX, endY, 400L))
                    }
                }
                "tapScreen" -> {
                    val x = call.argument<Double>("x") ?: 500.0
                    val y = call.argument<Double>("y") ?: 500.0
                    if (call.argument<Boolean>("requireAppWindow") == true) {
                        service.performAutomationGesture(x.toFloat(), y.toFloat(), x.toFloat()+1f, y.toFloat()+1f, 50L) { completed ->
                            if (completed) result.success(true)
                            else result.error("AUTOMATION_INTERRUPTED", "Tap gesture was canceled or rejected", null)
                        }
                    } else {
                        service.tapBounds(android.graphics.Rect(x.toInt(), y.toInt(), x.toInt(), y.toInt()))
                        result.success(true)
                    }
                }
                "remoteTap" -> {
                    val x = (call.argument<Double>("x") ?: 0.0).toFloat()
                    val y = (call.argument<Double>("y") ?: 0.0).toFloat()
                    val success = service.tapAt(x, y)
                    result.success(success)
                }
                "remoteLongPress" -> {
                    val x = (call.argument<Double>("x") ?: 0.0).toFloat()
                    val y = (call.argument<Double>("y") ?: 0.0).toFloat()
                    val duration = (call.argument<Int>("duration") ?: 700).toLong()
                    val success = service.longPressAt(x, y, duration)
                    result.success(success)
                }
                "remoteSwipe" -> {
                    val startX = (call.argument<Double>("startX") ?: 0.0).toFloat()
                    val startY = (call.argument<Double>("startY") ?: 0.0).toFloat()
                    val endX = (call.argument<Double>("endX") ?: 0.0).toFloat()
                    val endY = (call.argument<Double>("endY") ?: 0.0).toFloat()
                    val duration = (call.argument<Int>("duration") ?: 300).toLong()
                    val success = service.swipe(startX, startY, endX, endY, duration)
                    result.success(success)
                }
                "logTree" -> {
                    val treeStr = service.getTreeString(rootNode!!)
                    result.success(treeStr)
                }
                "findInputBeforeAndGetBounds" -> {
                    val target = call.argument<String>("target") ?: ""
                    val targetInstance = call.argument<Int>("targetInstance") ?: 1
                    val threshold = call.argument<Double>("threshold") ?: 0.82

                    val bounds = service.findInputBeforeTarget(rootNode!!, target, targetInstance, threshold)
                    if (bounds != null) {
                        result.success(mapOf("x" to bounds.centerX().toDouble(), "y" to bounds.centerY().toDouble()))
                    } else {
                        Log.d("A11Y", "Input before target '$target' not found.")
                        result.success(null)
                    }
                }
                "findNodeBeforeAndGetBounds" -> {
                    val target = call.argument<String>("target") ?: ""
                    val targetInstance = call.argument<Int>("targetInstance") ?: 1
                    val threshold = call.argument<Double>("threshold") ?: 0.82

                    val bounds = service.findNodeBeforeTarget(rootNode!!, target, targetInstance, threshold)
                    if (bounds != null) {
                        result.success(mapOf("x" to bounds.centerX().toDouble(), "y" to bounds.centerY().toDouble()))
                    } else {
                        Log.d("A11Y", "Node before target '$target' not found.")
                        result.success(null)
                    }
                }
                "findNodeAfterAndGetBounds" -> {
                    val target = call.argument<String>("target") ?: ""
                    val targetInstance = call.argument<Int>("targetInstance") ?: 1
                    val threshold = call.argument<Double>("threshold") ?: 0.82
                    val offset = call.argument<Int>("offset") ?: 1

                    val bounds = service.findNodeAfterTarget(rootNode!!, target, targetInstance, threshold, offset)
                    if (bounds != null) {
                        result.success(mapOf("x" to bounds.centerX().toDouble(), "y" to bounds.centerY().toDouble()))
                    } else {
                        Log.d("A11Y", "Node after target '$target' not found.")
                        result.success(null)
                    }
                }
                "findNodeTextAfterTarget" -> {
                    val target = call.argument<String>("target") ?: ""
                    val targetInstance = call.argument<Int>("targetInstance") ?: 1
                    val threshold = call.argument<Double>("threshold") ?: 0.82
                    val offset = call.argument<Int>("offset") ?: 1

                    val textVal = service.findNodeTextAfterTarget(rootNode!!, target, targetInstance, threshold, offset)
                    result.success(textVal)
                }
                "clearFocus" -> {
                    fun clearFocused(node: android.view.accessibility.AccessibilityNodeInfo?): Boolean {
                        if (node == null) return false
                        if (node.isFocused) {
                            node.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_CLEAR_FOCUS)
                            return true
                        }
                        for (i in 0 until node.childCount) {
                            if (clearFocused(node.getChild(i))) return true
                        }
                        return false
                    }
                    val focused = rootNode?.findFocus(android.view.accessibility.AccessibilityNodeInfo.FOCUS_INPUT)
                    var cleared = false
                    if (focused != null) {
                        cleared = focused.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_CLEAR_FOCUS)
                    } else {
                        cleared = clearFocused(rootNode)
                    }
                    result.success(cleared)
                }
                "pressBack" -> {
                    val pressed = service.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_BACK)
                    result.success(pressed)
                }
                "pressHome" -> {
                    val pressed = service.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_HOME)
                    result.success(pressed)
                }
                "pressRecents" -> {
                    val pressed = service.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_RECENTS)
                    result.success(pressed)
                }
                "findAndGetBounds" -> {
                    val target = call.argument<String>("target") ?: ""
                    val targetInstance = call.argument<Int>("targetInstance") ?: 1
                    val threshold = call.argument<Double>("threshold") ?: 0.82
                    val preferEditable = call.argument<Boolean>("preferEditable") ?: false

                    val matches = service.findBestHebrewMatches(rootNode!!, target, threshold)
                    val candidateMatches = if (preferEditable) {
                        val editables = matches.filter { it.node.isEditable || it.node.className?.toString()?.contains("EditText") == true }
                        if (editables.isNotEmpty()) editables else matches
                    } else {
                        matches
                    }
                    if (candidateMatches.size >= targetInstance) {
                        val match = candidateMatches[targetInstance - 1]
                        val bounds = match.bounds
                        result.success(mapOf("x" to bounds.centerX().toDouble(), "y" to bounds.centerY().toDouble()))
                    } else if (matches.size >= targetInstance) {
                        val match = matches[targetInstance - 1]
                        val bounds = match.bounds
                        result.success(mapOf("x" to bounds.centerX().toDouble(), "y" to bounds.centerY().toDouble()))
                    } else {
                        Log.d("A11Y", "Target '$target' not found (instance $targetInstance). Total matches: ${matches.size}")
                        result.success(null)
                    }
                }
                "tapByLabel" -> {
                    // Additive generic native tap: resolve the label, walk up to the
                    // nearest clickable ancestor, and try a semantic ACTION_CLICK
                    // first (most reliable — fires the element's real handler).
                    // Only when the semantic click is rejected do we fall back to a
                    // gesture tap on the (guarded) bounds. Returns the bounds tapped
                    // so Dart can keep the on-screen tap preview marker working.
                    val target = call.argument<String>("target") ?: ""
                    val targetInstance = call.argument<Int>("targetInstance") ?: 1
                    val threshold = call.argument<Double>("threshold") ?: 0.82
                    val deltaY = call.argument<Double>("deltaY") ?: 0.0

                    val matches = service.findBestHebrewMatches(rootNode!!, target, threshold)
                    if (matches.size >= targetInstance) {
                        val match = matches[targetInstance - 1]
                        val clickable = service.findClickableAncestor(match.node)

                        val dm = service.resources.displayMetrics
                        val bounds = if (clickable != null) {
                            val rect = android.graphics.Rect()
                            clickable.getBoundsInScreen(rect)
                            // Guard: a full-screen clickable wrapper would hijack the
                            // gesture tap, so prefer the precise label bounds then.
                            if (rect.width() > dm.widthPixels * 0.97 &&
                                rect.height() > dm.heightPixels * 0.6) {
                                match.bounds
                            } else {
                                rect
                            }
                        } else {
                            match.bounds
                        }
                        bounds.offset(0, deltaY.toInt())

                        var method = "gesture"
                        var clicked = false
                        if (clickable != null) {
                            clicked = service.clickNode(clickable)
                            if (clicked) method = "semantic"
                        }
                        if (!clicked) {
                            service.tapBounds(bounds)
                        }

                        result.success(
                            mapOf(
                                "x" to bounds.centerX().toDouble(),
                                "y" to bounds.centerY().toDouble(),
                                "method" to method
                            )
                        )
                    } else {
                        Log.d("A11Y", "tapByLabel: '$target' not found (instance $targetInstance). Total matches: ${matches.size}")
                        result.success(null)
                    }
                }
                "findClickableAndGetBounds" -> {
                    // Additive generic locator: resolve the label match, then walk
                    // up to the nearest clickable ancestor so taps land on the
                    // real interactive container instead of an inert text node.
                    val target = call.argument<String>("target") ?: ""
                    val targetInstance = call.argument<Int>("targetInstance") ?: 1
                    val threshold = call.argument<Double>("threshold") ?: 0.82

                    val matches = service.findBestHebrewMatches(rootNode!!, target, threshold)
                    if (matches.size >= targetInstance) {
                        val match = matches[targetInstance - 1]
                        val clickable = service.findClickableAncestor(match.node)
                        val bounds = if (clickable != null) {
                            val rect = android.graphics.Rect()
                            clickable.getBoundsInScreen(rect)
                            // Guard: a full-screen clickable wrapper would hijack the
                            // tap, so fall back to the precise label bounds then.
                            val dm = service.resources.displayMetrics
                            if (rect.width() > dm.widthPixels * 0.97 &&
                                rect.height() > dm.heightPixels * 0.6) {
                                match.bounds
                            } else {
                                rect
                            }
                        } else {
                            match.bounds
                        }
                        result.success(mapOf("x" to bounds.centerX().toDouble(), "y" to bounds.centerY().toDouble()))
                    } else {
                        Log.d("A11Y", "Clickable target '$target' not found (instance $targetInstance). Total matches: ${matches.size}")
                        result.success(null)
                    }
                }
                "pasteText" -> {
                    var pasted = false
                    val focusedNode = service.rootInActiveWindow?.findFocus(android.view.accessibility.AccessibilityNodeInfo.FOCUS_INPUT)
                    if (focusedNode != null) {
                        pasted = focusedNode.performAction(android.view.accessibility.AccessibilityNodeInfo.ACTION_PASTE)
                        if (!pasted) {
                            Log.d("A11Y", "Paste action failed on focused node")
                        }
                    } else {
                        Log.d("A11Y", "No focused input node found for paste")
                    }
                    result.success(pasted)
                }
                else -> result.notImplemented()
            }
        }
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

    private fun findEditableChild(node: android.view.accessibility.AccessibilityNodeInfo): android.view.accessibility.AccessibilityNodeInfo? {
        if (node.isEditable) return node
        for (i in 0 until node.childCount) {
            val child = node.getChild(i) ?: continue
            val found = findEditableChild(child)
            if (found != null) return found
        }
        return null
    }

    private fun isAccessibilityServiceEnabled(context: Context, serviceClass: Class<*>): Boolean {
        // Method 1: Query AccessibilityManager for enabled accessibility services
        try {
            val am = context.getSystemService(Context.ACCESSIBILITY_SERVICE) as? android.view.accessibility.AccessibilityManager
            if (am != null) {
                val enabledServices = am.getEnabledAccessibilityServiceList(android.accessibilityservice.AccessibilityServiceInfo.FEEDBACK_ALL_MASK)
                for (service in enabledServices) {
                    val sInfo = service.resolveInfo?.serviceInfo
                    if (sInfo != null && sInfo.packageName == context.packageName &&
                        (sInfo.name == serviceClass.name || sInfo.name.endsWith(serviceClass.simpleName))) {
                        return true
                    }
                }
            }
        } catch (e: Exception) {
            Log.e("A11Y", "Error checking AccessibilityManager: $e")
        }

        // Method 2: Check Secure Settings enabled services string
        val expected = android.content.ComponentName(context, serviceClass)
        val enabledServices = android.provider.Settings.Secure.getString(
            context.contentResolver,
            android.provider.Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false

        return enabledServices.split(":").any { flattened ->
            val component = android.content.ComponentName.unflattenFromString(flattened.trim())
            component != null && component.packageName == expected.packageName &&
                (component.className == expected.className || 
                 component.className == serviceClass.simpleName ||
                 component.className == ".${serviceClass.simpleName}" ||
                 component.shortClassName == ".${serviceClass.simpleName}")
        }
    }
}
