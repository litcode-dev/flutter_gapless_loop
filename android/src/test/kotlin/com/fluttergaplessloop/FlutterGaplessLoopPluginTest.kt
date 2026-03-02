package com.fluttergaplessloop

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
