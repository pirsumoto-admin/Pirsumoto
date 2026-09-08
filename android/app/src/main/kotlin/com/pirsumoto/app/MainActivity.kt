package com.pirsumoto.app

import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import android.util.Log
import android.view.WindowManager

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.pirsumoto/accessibility"
    private val WHATSAPP_CHANNEL = "com.pirsumoto/whatsapp_bridge"
    private val WHATSAPP_EVENTS_CHANNEL = "com.pirsumoto/whatsapp_bridge/events"

    override fun onCreate(savedInstanceState: Bundle?) {
        prepareForAutoPublishIntent(intent)
        super.onCreate(savedInstanceState)
        hideSystemUI()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        prepareForAutoPublishIntent(intent)
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
        WhatsAppAutoPublishStore.captureIntent(intent)
        val whatsappBridgeController = WhatsAppBridgeController(this)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, WHATSAPP_CHANNEL).setMethodCallHandler { call, result ->
            whatsappBridgeController.handle(call, result)
        }
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, WHATSAPP_EVENTS_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    WhatsAppBridgeEvents.attach(events)
                }

                override fun onCancel(arguments: Any?) {
                    WhatsAppBridgeEvents.detach()
                }
            }
        )

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            
            if (call.method == "checkPermission") {
                var isConnected = PirsumotoAccessibilityService.instance != null
                if (!isConnected) {
                    val isEnabledInSettings = isAccessibilityServiceEnabled(context, PirsumotoAccessibilityService::class.java)
                    if (isEnabledInSettings) {
                        try {
                            val component = android.content.ComponentName(context, PirsumotoAccessibilityService::class.java)
                            val pm = context.packageManager
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
                            Log.d("A11Y", "Toggled AccessibilityService component to revive zombie service")
                        } catch (e: Exception) {
                            Log.e("A11Y", "Failed to toggle AccessibilityService component", e)
                        }
                        try { Thread.sleep(100) } catch (_: Exception) {}
                        isConnected = PirsumotoAccessibilityService.instance != null
                    }
                }
                result.success(isConnected)
                return@setMethodCallHandler
            }
            if (call.method == "openSettings") {
                val componentName = android.content.ComponentName(
                    context.packageName,
                    context.packageName + ".PirsumotoAccessibilityService"
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

            val service = PirsumotoAccessibilityService.instance
            if (service == null) {
                result.error("UNAVAILABLE", "Accessibility Service not connected. Please enable it in Settings.", null)
                return@setMethodCallHandler
            }

            val rootNode = service.rootInActiveWindow
            if (rootNode == null && call.method != "injectTextNative" && call.method != "pressBack" && call.method != "tapScreen" && call.method != "pasteText") {
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
                    
                    val scrolled = service.swipe(startX, startY, startX, endY, 400L)
                    result.success(scrolled)
                }
                "tapScreen" -> {
                    val x = call.argument<Double>("x") ?: 500.0
                    val y = call.argument<Double>("y") ?: 500.0
                    service.tapBounds(android.graphics.Rect(x.toInt(), y.toInt(), x.toInt(), y.toInt()))
                    result.success(true)
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
                "pressBack" -> {
                    val pressed = service.performGlobalAction(android.accessibilityservice.AccessibilityService.GLOBAL_ACTION_BACK)
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
        WhatsAppBridgeEvents.detach()
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun prepareForAutoPublishIntent(intent: Intent?) {
        if (!WhatsAppAutoPublishStore.captureIntent(intent)) return

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
            try {
                val keyguardManager = getSystemService(Context.KEYGUARD_SERVICE) as android.app.KeyguardManager
                keyguardManager.requestDismissKeyguard(this, null)
            } catch (e: Exception) {
                Log.w("WA-AutoPublish", "Could not request keyguard dismiss", e)
            }
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_DISMISS_KEYGUARD
            )
        }
    }

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
        val expected = android.content.ComponentName(context, serviceClass)
        val enabledServices = android.provider.Settings.Secure.getString(
            context.contentResolver,
            android.provider.Settings.Secure.ENABLED_ACCESSIBILITY_SERVICES
        ) ?: return false

        return enabledServices.split(":").any { flattened ->
            val component = android.content.ComponentName.unflattenFromString(flattened)
            component?.packageName == expected.packageName && component.className == expected.className
        }
    }
}
