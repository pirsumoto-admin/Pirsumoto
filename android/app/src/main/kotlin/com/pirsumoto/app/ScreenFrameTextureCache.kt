package com.pirsumoto.app

import android.graphics.Matrix
import android.opengl.GLES20
import android.os.Handler
import android.os.Looper
import org.webrtc.GlRectDrawer
import org.webrtc.GlTextureFrameBuffer
import org.webrtc.TextureBufferImpl
import org.webrtc.VideoFrame
import org.webrtc.VideoFrameDrawer
import org.webrtc.YuvConverter

/** Copies the capture texture on the GPU so caching never pins its SurfaceTexture. */
internal class ScreenFrameTextureCache {
    @Volatile private var handler: Handler? = null
    private var drawer: GlRectDrawer? = null
    private var converter: YuvConverter? = null
    private val available = ArrayDeque<GlTextureFrameBuffer>()
    private var allocated = 0
    private var closed = false

    fun copy(frame: VideoFrame): VideoFrame? {
        val source = frame.buffer
        if (source !is TextureBufferImpl) {
            // CPU frames already own independent storage; toI420 retains it.
            val buffer = source.toI420() ?: return null
            return VideoFrame(buffer, frame.rotation, frame.timestampNs)
        }
        val captureHandler = source.toI420Handler
        check(Looper.myLooper() == captureHandler.looper)
        check(handler == null || handler === captureHandler)
        handler = captureHandler
        if (closed) return null
        // Bound memory even if an encoder temporarily holds on to old frames.
        val target = if (available.isNotEmpty()) available.removeFirst() else {
            if (allocated >= 3) return null
            allocated++
            GlTextureFrameBuffer(GLES20.GL_RGBA)
        }
        try {
            val glDrawer = drawer ?: GlRectDrawer().also { drawer = it }
            val yuvConverter = converter ?: YuvConverter().also { converter = it }
            target.setSize(source.width, source.height)
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, target.frameBufferId)
            // Bake only the source texture transform; retain the frame's rotation.
            VideoFrameDrawer.drawTexture(
                glDrawer, source, Matrix(), source.width, source.height,
                0, 0, source.width, source.height
            )
            // Submit GPU work without a CPU readback or per-frame GPU wait.
            GLES20.glFlush()
            val buffer = TextureBufferImpl(
                source.width, source.height, VideoFrame.TextureBuffer.Type.RGB,
                target.textureId, Matrix(), captureHandler, yuvConverter,
                Runnable { onCaptureThread { recycle(target) } }
            )
            return VideoFrame(buffer, frame.rotation, frame.timestampNs)
        } catch (error: RuntimeException) {
            target.release()
            allocated--
            throw error
        } finally {
            GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0)
        }
    }

    private fun recycle(target: GlTextureFrameBuffer) {
        if (closed) {
            target.release()
            allocated--
            releaseConverterIfUnused()
        } else {
            available.addLast(target)
        }
    }

    fun close() = onCaptureThread {
        closed = true
        while (available.isNotEmpty()) {
            available.removeFirst().release()
            allocated--
        }
        drawer?.release()
        drawer = null
        releaseConverterIfUnused()
    }

    private fun releaseConverterIfUnused() {
        if (closed && allocated == 0) {
            converter?.release()
            converter = null
        }
    }

    // Only static-screen replays need a fence before another EGL context reads
    // the cached texture. Live frames go straight through the original source.
    fun prepareReplay() {
        if (handler != null) GLES20.glFinish()
    }

    fun onCaptureThread(action: () -> Unit) {
        val captureHandler = handler
        if (captureHandler == null || Looper.myLooper() == captureHandler.looper) {
            action()
        } else {
            captureHandler.post { action() }
        }
    }
}
