package com.pirsumoto.app

import android.os.Handler
import android.os.Looper
import android.text.InputType
import android.util.Log
import android.view.inputmethod.EditorInfo
import android.webkit.WebView

/** Native keyboard input for the owned, already-focused WebView. No DOM or clipboard access. */
object NativeWebViewTextInput {
    fun replace(view: WebView, value: String, completion: (Boolean) -> Unit) {
        if (!view.isAttachedToWindow || !view.isShown || !view.hasWindowFocus() || !view.hasFocus()) {
            completion(false)
            return
        }
        val editor = EditorInfo()
        val connection = view.onCreateInputConnection(editor)
        if (connection == null || editor.inputType == InputType.TYPE_NULL) {
            Log.w("A11Y", "WebView has no active native text editor")
            completion(false)
            return
        }

        val main = Handler(Looper.getMainLooper())
        // Chromium may supply a dedicated IME thread. Respect that handler instead
        // of making InputConnection calls on the activity's UI thread unconditionally.
        val inputHandler = connection.handler ?: main
        val posted = inputHandler.post {
            val accepted = try {
                if (!MainActivity.isAppInForeground) {
                    false
                } else {
                    connection.finishComposingText()
                    // Replace the whole field on every retry; never append a second plate.
                    connection.performContextMenuAction(android.R.id.selectAll) &&
                        connection.commitText(value, 1)
                }
            } catch (error: Exception) {
                Log.w("A11Y", "Native WebView text replacement failed", error)
                false
            }
            main.post {
                if (accepted) {
                    view.clearFocus()
                    val imm = view.context.getSystemService(android.content.Context.INPUT_METHOD_SERVICE) as? android.view.inputmethod.InputMethodManager
                    imm?.hideSoftInputFromWindow(view.windowToken, 0)
                }
                Log.d("A11Y", "Native WebView text replacement accepted=$accepted; readback still required")
                completion(accepted)
            }
        }
        if (!posted) completion(false)
        // This connection belongs to WebView/the keyboard; do not close it here.
    }
}
