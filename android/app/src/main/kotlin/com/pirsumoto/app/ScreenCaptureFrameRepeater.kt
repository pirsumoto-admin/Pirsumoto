package com.pirsumoto.app

import android.os.Handler
import android.os.Looper
import android.util.Log
import com.cloudwebrtc.webrtc.FlutterWebRTCPlugin
import com.cloudwebrtc.webrtc.video.LocalVideoTrack
import org.webrtc.VideoFrame

/** Keeps static screen shares producing frames without drawing an overlay on the device. */
object ScreenCaptureFrameRepeater {
    private val handler = Handler(Looper.getMainLooper())
    private var active: Repeater? = null

    // Called on the platform channel's main thread, before SDP negotiation.
    fun start(trackId: String) {
        stop()
        val track = FlutterWebRTCPlugin.sharedSingleton?.getLocalTrack(trackId) as? LocalVideoTrack
            ?: throw IllegalStateException("Screen capture track is unavailable")
        active = Repeater(
            track,
            schedule = { handler.postDelayed(it, 500) },
            cancel = { handler.removeCallbacks(it) }
        ).also { it.start() }
    }

    fun stop() {
        active?.stop()
        active = null
    }

    internal class Repeater(
        private val track: LocalVideoTrack,
        private val schedule: (Runnable) -> Unit,
        private val cancel: (Runnable) -> Unit,
        private val nowNs: () -> Long = System::nanoTime
    ) :
        LocalVideoTrack.ExternalVideoFrameProcessing, Runnable {
        private val lock = Any()
        private val frameCache = ScreenFrameTextureCache()
        private var cached: VideoFrame? = null
        private var replay: VideoFrame? = null
        private var capturedAtNs = 0L
        private var stopped = false
        private var cacheFailed = false

        fun start() {
            track.addProcessor(this)
            schedule(this)
        }

        override fun onFrame(frame: VideoFrame): VideoFrame {
            synchronized(lock) {
                if (stopped || cacheFailed || frame === replay) return frame
                // Release before copying so an unused GPU texture can be reused.
                // Never retain the capture texture or read it back to the CPU.
                cached?.release()
                cached = null
                try {
                    cached = frameCache.copy(frame)
                } catch (error: RuntimeException) {
                    // A device-specific GL failure must not stop live video.
                    cacheFailed = true
                    Log.w("ScreenFrameRepeater", "Disabling static-frame cache", error)
                }
                capturedAtNs = nowNs()
            }
            return frame
        }

        override fun run() = frameCache.onCaptureThread { repeatFrame() }

        private fun repeatFrame() {
            val frame = synchronized(lock) {
                if (stopped) return
                val last = cached
                val elapsed = nowNs() - capturedAtNs
                if (last == null || elapsed < 500_000_000L) null else {
                    last.buffer.retain()
                    VideoFrame(last.buffer, last.rotation, last.timestampNs + elapsed)
                        .also { replay = it }
                }
            }
            if (frame != null) {
                try {
                    // Uses the same source/encoder as real frames; no extra capture or UI.
                    // Do not hold lock here: the plugin takes its processor lock first.
                    frameCache.prepareReplay()
                    track.onFrameCaptured(frame)
                } finally {
                    synchronized(lock) { replay = null }
                    frame.release()
                }
            }
            schedule(this)
        }

        fun stop() {
            cancel(this)
            track.removeProcessor(this)
            synchronized(lock) {
                stopped = true
                cached?.release()
                cached = null
            }
            frameCache.close()
        }
    }
}
