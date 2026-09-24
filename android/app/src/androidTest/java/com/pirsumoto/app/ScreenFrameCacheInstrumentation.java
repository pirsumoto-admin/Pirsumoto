package com.pirsumoto.app;

import android.app.Instrumentation;
import android.graphics.Matrix;
import android.opengl.GLES20;
import android.os.Bundle;
import android.os.Handler;
import android.os.HandlerThread;
import org.webrtc.*;
import java.nio.ByteBuffer;

/**
 * Device-side regression check; runs with a real EGL context, without Firebase.
 * Build from android/: ./gradlew :app:assembleDebug :app:assembleDebugAndroidTest -I gpu-cache-test.gradle
 * Install both debug APKs, then run:
 * adb shell am instrument -w com.pirsumotoapp.test/com.pirsumoto.app.ScreenFrameCacheInstrumentation
 */
public class ScreenFrameCacheInstrumentation extends Instrumentation {
    @Override public void onCreate(Bundle arguments) { super.onCreate(arguments); start(); }

    @Override public void onStart() {
        Bundle result = new Bundle();
        HandlerThread thread = new HandlerThread("screen-cache-test");
        thread.start();
        Handler handler = new Handler(thread.getLooper());
        try {
            ThreadUtils.invokeAtFrontUninterruptibly(handler, () -> {
                EglBase egl = EglBase.create(null, EglBase.CONFIG_PIXEL_BUFFER);
                egl.createPbufferSurface(2, 2);
                egl.makeCurrent();
                try { verifyCache(handler); } finally { egl.release(); }
            });
            result.putString("stream", "GPU cache checks passed: exact pixels, rotation, zero source readbacks, bounded pool, reuse, teardown.\n");
            finish(-1, result);
        } catch (Throwable error) {
            result.putString("stream", "GPU cache failed: " + android.util.Log.getStackTraceString(error));
            finish(1, result);
        } finally {
            thread.quitSafely();
        }
    }

    private void verifyCache(Handler handler) {
        ScreenFrameTextureCache cache = new ScreenFrameTextureCache();
        YuvConverter converter = new YuvConverter();
        int sourceTexture = GlUtil.generateTexture(GLES20.GL_TEXTURE_2D);
        // Four distinct corners catch mirrored/flipped copies, as well as corruption.
        byte[] pixels = new byte[] {
            (byte)255, 0, 0, (byte)255, 0, (byte)255, 0, (byte)255,
            0, 0, (byte)255, (byte)255, (byte)255, (byte)255, (byte)255, (byte)255
        };
        ByteBuffer input = ByteBuffer.allocateDirect(pixels.length);
        input.put(pixels).rewind();
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, sourceTexture);
        GLES20.glTexImage2D(GLES20.GL_TEXTURE_2D, 0, GLES20.GL_RGBA, 2, 2, 0,
            GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, input);
        int[] released = {0};
        TextureBufferImpl source = new TextureBufferImpl(
            2, 2, VideoFrame.TextureBuffer.Type.RGB, sourceTexture,
            new Matrix(), handler, converter, () -> released[0]++
        ) {
            @Override public VideoFrame.I420Buffer toI420() {
                throw new AssertionError("Capture path performed a CPU readback");
            }
        };
        VideoFrame original = new VideoFrame(source, 90, 123L);
        VideoFrame first = cache.copy(original);
        require(first != null && first.getRotation() == 90 && first.getTimestampNs() == 123L,
            "Frame metadata changed");
        assertPixels(first, pixels);
        VideoFrame second = cache.copy(original);
        VideoFrame third = cache.copy(original);
        require(second != null && third != null, "Pool did not allocate in-flight slots");
        require(cache.copy(original) == null, "Pool exceeded three textures");
        int recycledId = ((VideoFrame.TextureBuffer) second.getBuffer()).getTextureId();
        second.release();
        VideoFrame recycled = cache.copy(original);
        require(((VideoFrame.TextureBuffer) recycled.getBuffer()).getTextureId() == recycledId,
            "Released texture was not reused");
        recycled.release();
        third.release();
        // Change the live capture to prove an in-flight cached frame is immutable.
        byte[] changed = pixels.clone();
        changed[0] = 0;
        changed[1] = (byte)255;
        ByteBuffer update = ByteBuffer.allocateDirect(changed.length);
        update.put(changed).rewind();
        GLES20.glBindTexture(GLES20.GL_TEXTURE_2D, sourceTexture);
        GLES20.glTexSubImage2D(GLES20.GL_TEXTURE_2D, 0, 0, 0, 2, 2,
            GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, update);
        // Repeated captures must neither read pixels to the CPU nor overwrite first.
        for (int i = 0; i < 120; i++) {
            VideoFrame next = cache.copy(original);
            require(next != null, "Pool leaked during scrolling");
            assertPixels(next, changed);
            next.release();
        }
        assertPixels(first, pixels);
        original.release();
        require(released[0] == 1, "Cache retained the capture buffer");
        // Teardown must allow a downstream consumer to release its frame later.
        cache.close();
        assertPixels(first, pixels);
        first.release();
        converter.release();
        GLES20.glDeleteTextures(1, new int[] {sourceTexture}, 0);
        GlUtil.checkNoGLES2Error("cache teardown");
    }

    private void assertPixels(VideoFrame frame, byte[] expected) {
        int[] framebuffer = new int[1];
        GLES20.glGenFramebuffers(1, framebuffer, 0);
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, framebuffer[0]);
        GLES20.glFramebufferTexture2D(GLES20.GL_FRAMEBUFFER, GLES20.GL_COLOR_ATTACHMENT0,
            GLES20.GL_TEXTURE_2D, ((VideoFrame.TextureBuffer) frame.getBuffer()).getTextureId(), 0);
        ByteBuffer actual = ByteBuffer.allocateDirect(expected.length);
        GLES20.glReadPixels(0, 0, 2, 2, GLES20.GL_RGBA, GLES20.GL_UNSIGNED_BYTE, actual);
        for (int i = 0; i < expected.length; i++) {
            require(expected[i] == actual.get(i), "Wrong pixel at byte " + i);
        }
        GLES20.glBindFramebuffer(GLES20.GL_FRAMEBUFFER, 0);
        GLES20.glDeleteFramebuffers(1, framebuffer, 0);
    }

    private void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }
}
