package com.pirsumoto.app

import com.cloudwebrtc.webrtc.video.LocalVideoTrack
import org.junit.Assert.*
import org.junit.Test
import org.webrtc.JavaI420Buffer
import org.webrtc.VideoFrame
import java.nio.ByteBuffer

class ScreenCaptureFrameRepeaterTest {
    private class Track : LocalVideoTrack(null) {
        val hooks = mutableListOf<ExternalVideoFrameProcessing>()
        val timestamps = mutableListOf<Long>()
        override fun addProcessor(processor: ExternalVideoFrameProcessing) { hooks.add(processor) }
        override fun removeProcessor(processor: ExternalVideoFrameProcessing) { hooks.remove(processor) }
        override fun onFrameCaptured(frame: VideoFrame) {
            hooks.forEach { it.onFrame(frame) }
            timestamps.add(frame.timestampNs)
        }
    }

    @Test
    fun repeatsStaticFramesWithFreshTimestampsAndReleasesCacheOnStop() {
        val track = Track()
        var now = 0L
        var released = 0
        var scheduled = 0
        var cancelled = 0
        val repeater = ScreenCaptureFrameRepeater.Repeater(
            track, { scheduled++ }, { cancelled++ }, { now }
        )
        val buffer = JavaI420Buffer.wrap(
            2, 2, ByteBuffer.allocateDirect(4), 2,
            ByteBuffer.allocateDirect(1), 1, ByteBuffer.allocateDirect(1), 1
        ) { released++ }
        val frame = VideoFrame(buffer, 0, 100L)
        repeater.start()
        track.onFrameCaptured(frame)
        frame.release()
        assertEquals(0, released) // Cache owns a reference independently.

        now = 100_000_000L
        repeater.run()
        assertEquals(listOf(100L), track.timestamps)
        now = 600_000_000L
        repeater.run()
        now = 1_100_000_000L
        repeater.run()
        assertEquals(listOf(100L, 600_000_100L, 1_100_000_100L), track.timestamps)

        repeater.stop()
        assertTrue(track.hooks.isEmpty())
        assertEquals(1, released)
        assertEquals(1, cancelled)
        repeater.run()
        assertEquals(3, track.timestamps.size)
        assertEquals(4, scheduled)
    }

    @Test
    fun newCaptureReplacesCachedFrameAndDelaysRepetition() {
        val track = Track()
        var now = 0L
        val repeater = ScreenCaptureFrameRepeater.Repeater(track, {}, {}, { now })
        fun capture(timestamp: Long) {
            val frame = VideoFrame(JavaI420Buffer.wrap(
                2, 2, ByteBuffer.allocateDirect(4), 2,
                ByteBuffer.allocateDirect(1), 1, ByteBuffer.allocateDirect(1), 1, null
            ), 90, timestamp)
            track.onFrameCaptured(frame)
            frame.release()
        }
        repeater.start()
        capture(100L)
        now = 400_000_000L
        capture(400_000_100L)
        now = 600_000_000L
        repeater.run()
        assertEquals(2, track.timestamps.size)
        now = 1_000_000_000L
        repeater.run()
        assertEquals(1_000_000_100L, track.timestamps.last())
        repeater.stop()
    }
}
