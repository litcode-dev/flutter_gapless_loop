package com.fluttergaplessloop

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertTrue

class LoopEngineErrorTest {

    @Test
    fun `FileNotFound message contains path`() {
        val err = LoopEngineError.FileNotFound("/sdcard/loop.mp3")
        assertTrue(err.toMessage().contains("/sdcard/loop.mp3"))
    }

    @Test
    fun `DecodeFailed message contains reason`() {
        val err = LoopEngineError.DecodeFailed("codec timeout")
        assertTrue(err.toMessage().contains("codec timeout"))
    }

    @Test
    fun `InvalidLoopRegion message contains start and end`() {
        val err = LoopEngineError.InvalidLoopRegion(2.0, 1.0)
        val msg = err.toMessage()
        assertTrue(msg.contains("2.0") && msg.contains("1.0"))
    }

    @Test
    fun `LoopAudioException wraps error message`() {
        val err = LoopEngineError.FileNotFound("/missing.mp3")
        val ex = LoopAudioException(err)
        assertEquals(err.toMessage(), ex.message)
    }

    @Test
    fun `EngineState idle rawValue is idle`() {
        assertEquals("idle", EngineState.Idle.rawValue)
    }

    @Test
    fun `EngineState error rawValue is error`() {
        val state = EngineState.Error(LoopEngineError.DecodeFailed("x"))
        assertEquals("error", state.rawValue)
    }

    @Test
    fun `all EngineState rawValues are non-empty`() {
        val states: List<EngineState> = listOf(
            EngineState.Idle, EngineState.Loading, EngineState.Ready,
            EngineState.Playing, EngineState.Paused, EngineState.Stopped,
            EngineState.Error(LoopEngineError.DecodeFailed("x"))
        )
        states.forEach { assertTrue(it.rawValue.isNotEmpty()) }
    }
}

class CrossfadeEngineTest {

    @Test
    fun `configure sets correct fadeFrames for 100ms at 44100Hz`() {
        val engine = CrossfadeEngine(44100, 2)
        engine.configure(0.1)
        assertEquals(4410, engine.fadeFrames)
    }

    @Test
    fun `configure sets correct fadeFrames for 50ms at 48000Hz`() {
        val engine = CrossfadeEngine(48000, 1)
        engine.configure(0.05)
        assertEquals(2400, engine.fadeFrames)
    }

    @Test
    fun `first frame of block is approximately pure tail (fadeOut=1, fadeIn=0)`() {
        val engine = CrossfadeEngine(44100, 1)
        engine.configure(0.1)
        val n = engine.fadeFrames
        val tail = FloatArray(n) { 1.0f }
        val head = FloatArray(n) { 0.5f }
        val block = engine.computeCrossfadeBlock(tail, head)
        // cos(0) = 1.0, sin(0) = 0.0 → first output ≈ 1.0
        assertTrue(abs(block[0] - 1.0f) < 0.01f, "Expected ~1.0 got ${block[0]}")
    }

    @Test
    fun `last frame of block is approximately pure head (fadeOut=0, fadeIn=1)`() {
        val engine = CrossfadeEngine(44100, 1)
        engine.configure(0.1)
        val n = engine.fadeFrames
        val tail = FloatArray(n) { 1.0f }
        val head = FloatArray(n) { 0.5f }
        val block = engine.computeCrossfadeBlock(tail, head)
        // cos(π/2) ≈ 0.0, sin(π/2) = 1.0 → last output ≈ 0.5
        assertTrue(abs(block[n - 1] - 0.5f) < 0.01f, "Expected ~0.5 got ${block[n - 1]}")
    }

    @Test
    fun `equal power property at midpoint`() {
        val engine = CrossfadeEngine(44100, 1)
        engine.configure(0.1)
        val n = engine.fadeFrames
        val tail = FloatArray(n) { 1.0f }
        val head = FloatArray(n) { 1.0f }
        val block = engine.computeCrossfadeBlock(tail, head)
        // At midpoint cos²+sin²=1 → blended amplitude ≈ 1.0
        val mid = n / 2
        assertTrue(abs(block[mid] - 1.0f) < 0.05f, "Power at midpoint: ${block[mid]}")
    }

    @Test
    fun `reset clears fadeFrames to zero`() {
        val engine = CrossfadeEngine(44100, 1)
        engine.configure(0.1)
        engine.reset()
        assertEquals(0, engine.fadeFrames)
    }

    @Test
    fun `stereo block has correct sample count`() {
        val engine = CrossfadeEngine(44100, 2)
        engine.configure(0.05)
        val n = engine.fadeFrames * 2 // stereo: 2 samples per frame
        val tail = FloatArray(n) { 0.8f }
        val head = FloatArray(n) { 0.2f }
        val block = engine.computeCrossfadeBlock(tail, head)
        assertEquals(n, block.size)
    }
}
