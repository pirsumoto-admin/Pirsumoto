package com.pirsumoto.app

import android.view.ViewGroup
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.webviewflutter.WebViewFlutterAndroidExternalApi

/** Explicit native teardown: the Flutter platform-view wrapper does not destroy WebViews. */
object AutomationWebViewLifecycle {
    fun register(engine: FlutterEngine) {
        MethodChannel(engine.dartExecutor.binaryMessenger, "com.pirsumoto/automation_webview")
            .setMethodCallHandler { call, result ->
                if (call.method != "prepare" && call.method != "destroy") {
                    result.notImplemented()
                    return@setMethodCallHandler
                }
                val identifier = call.argument<Number>("identifier")?.toLong()
                if (identifier == null) {
                    result.error("missing_identifier", "WebView identifier is required", null)
                    return@setMethodCallHandler
                }
                try {
                    @Suppress("DEPRECATION")
                    val view = WebViewFlutterAndroidExternalApi.getWebView(engine, identifier)
                    if (view == null) {
                        result.error("missing_webview", "WebView $identifier was not found", null)
                        return@setMethodCallHandler
                    }
                    if (call.method == "prepare") {
                        // Route target=_blank/window.open into the owned WebView.
                        // The plugin otherwise creates untracked temporary WebViews.
                        view.settings.setSupportMultipleWindows(false)
                    } else {
                        view.stopLoading()
                        view.settings.javaScriptEnabled = false
                        // Keep the plugin's clients installed. Its WebView subclass
                        // asserts that WebChromeClient is a SecureWebChromeClient;
                        // assigning null throws AssertionError and crashes the app.
                        (view.parent as? ViewGroup)?.removeView(view)
                        view.removeAllViews()
                        view.clearHistory()
                        view.destroy()
                    }
                    // Cookies and persistent site storage intentionally retain preset logins.
                    result.success(null)
                } catch (error: Exception) {
                    result.error("webview_lifecycle", error.message, null)
                }
            }
    }
}
