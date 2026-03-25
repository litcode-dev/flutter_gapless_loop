package com.fluttergaplessloop

import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
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

class BpmDetectorTest {

    /** Generates a mono float array with 10ms-wide amplitude pulses at every beat. */
    private fun pulseAt(bpm: Double, sampleRate: Int = 44100, durationSecs: Double = 10.0): FloatArray {
        val n = (sampleRate * durationSecs).toInt()
        val pcm = FloatArray(n)
        val periodSamples = (sampleRate * 60.0 / bpm).toInt()
        val pulseLen = (sampleRate * 0.01).toInt() // 10ms pulse
        var pos = 0
        while (pos < n) {
            val end = minOf(pos + pulseLen, n)
            for (i in pos until end) pcm[i] = 1.0f
            pos += periodSamples
        }
        return pcm
    }

    @Test
    fun `detect returns zero result for audio shorter than 2 seconds`() {
        val pcm = FloatArray(44100) { 0.5f }   // 1 second at 44100Hz
        val result = BpmDetector.detect(pcm, 44100, 1)
        assertEquals(0.0, result.bpm, 0.001)
        assertEquals(0.0, result.confidence, 0.001)
        assertTrue(result.beats.isEmpty())
    }

    @Test
    fun `detect returns zero result for silence`() {
        val pcm = FloatArray(44100 * 5) { 0f }  // 5 seconds of silence
        val result = BpmDetector.detect(pcm, 44100, 1)
        assertEquals(0.0, result.bpm, 0.001)
        assertTrue(result.beats.isEmpty())
    }

    @Test
    fun `detect 120 BPM pulse train within 2 BPM tolerance`() {
        val pcm = pulseAt(120.0)
        val result = BpmDetector.detect(pcm, 44100, 1)
        assertTrue(
            abs(result.bpm - 120.0) <= 2.0,
            "Expected ~120 BPM, got ${result.bpm}"
        )
        assertTrue(result.confidence > 0.5, "Expected confidence > 0.5, got ${result.confidence}")
    }

    @Test
    fun `detect 128 BPM pulse train within 2 BPM tolerance`() {
        val pcm = pulseAt(128.0)
        val result = BpmDetector.detect(pcm, 44100, 1)
        assertTrue(
            abs(result.bpm - 128.0) <= 2.0,
            "Expected ~128 BPM, got ${result.bpm}"
        )
    }

    @Test
    fun `stereo audio produces same BPM as mono`() {
        val mono = pulseAt(120.0)
        val stereo = FloatArray(mono.size * 2) { i -> mono[i / 2] }
        val monoResult   = BpmDetector.detect(mono, 44100, 1)
        val stereoResult = BpmDetector.detect(stereo, 44100, 2)
        assertEquals(monoResult.bpm, stereoResult.bpm, 0.001)
    }

    @Test
    fun `beat timestamps are monotonically increasing`() {
        val pcm = pulseAt(120.0)
        val result = BpmDetector.detect(pcm, 44100, 1)
        assertTrue(result.beats.size >= 2)
        for (i in 1 until result.beats.size) {
            assertTrue(result.beats[i] > result.beats[i - 1],
                "Non-monotonic: beats[$i]=${result.beats[i]} <= beats[${i-1}]=${result.beats[i-1]}")
        }
    }

    @Test
    fun `no beats in micro-fade region (first 5ms)`() {
        val pcm = pulseAt(120.0)
        val result = BpmDetector.detect(pcm, 44100, 1)
        assertTrue(result.beats.all { it >= 0.005 },
            "Found beat before 5ms: ${result.beats.filter { it < 0.005 }}")
    }

    @Test
    fun `confidence is in range 0 to 1`() {
        val pcm = pulseAt(120.0)
        val result = BpmDetector.detect(pcm, 44100, 1)
        assertTrue(result.confidence in 0.0..1.0,
            "Confidence out of range: ${result.confidence}")
    }
}

class PlaybackRateTest {

    @Test
    fun `rate coerces below minimum to 0_25`() {
        assertEquals(0.25f, 0.1f.coerceIn(0.25f, 4.0f), 0.001f)
    }

    @Test
    fun `rate coerces above maximum to 4_0`() {
        assertEquals(4.0f, 10f.coerceIn(0.25f, 4.0f), 0.001f)
    }

    @Test
    fun `normal rate 1_0 is within range`() {
        assertEquals(1.0f, 1.0f.coerceIn(0.25f, 4.0f), 0.001f)
    }
}

class PanFormulaTest {

    @Test
    fun `centre pan gives equal left and right gains`() {
        val (l, r) = panToGains(0f)
        assertEquals(l, r, 0.001f)
    }

    @Test
    fun `full left pan gives leftGain=1 rightGain=0`() {
        val (l, r) = panToGains(-1f)
        assertEquals(1.0f, l, 0.001f)
        assertEquals(0.0f, r, 0.001f)
    }

    @Test
    fun `full right pan gives leftGain=0 rightGain=1`() {
        val (l, r) = panToGains(1f)
        assertEquals(0.0f, l, 0.001f)
        assertEquals(1.0f, r, 0.001f)
    }

    @Test
    fun `centre gains satisfy equal-power property (sum of squares = 1)`() {
        val (l, r) = panToGains(0f)
        assertEquals(1.0f, l * l + r * r, 0.01f)
    }
}

class MeterDetectorTest {

    /**
     * Generates a mono float array with 10ms-wide amplitude pulses spaced at the beat period.
     * Beat 0 of each bar has amplitude 1.0; all other beats have amplitude 0.5.
     * This accent pattern gives the onset autocorrelation enough signal to distinguish
     * 3/4 from 4/4.
     */
    private fun pulseAtMeter(
        bpm: Double,
        beatsPerBar: Int,
        sampleRate: Int = 44100,
        durationSecs: Double = 16.0
    ): FloatArray {
        val n = (sampleRate * durationSecs).toInt()
        val pcm = FloatArray(n)
        val periodSamples = (sampleRate * 60.0 / bpm).toInt()
        val pulseLen = (sampleRate * 0.01).toInt() // 10 ms
        var pos = 0
        var beat = 0
        while (pos < n) {
            val amp = if (beat % beatsPerBar == 0) 1.0f else 0.5f
            val end = minOf(pos + pulseLen, n)
            for (i in pos until end) pcm[i] = amp
            pos += periodSamples
            beat++
        }
        return pcm
    }

    @Test
    fun `beatsPerBar is zero for silence`() {
        val pcm = FloatArray(44100 * 5) { 0f }
        val result = BpmDetector.detect(pcm, 44100, 1)
        assertEquals(0, result.beatsPerBar)
        assertTrue(result.bars.isEmpty())
    }

    @Test
    fun `beatsPerBar is zero for audio shorter than 2 seconds`() {
        val pcm = FloatArray(44100) { 0.5f }
        val result = BpmDetector.detect(pcm, 44100, 1)
        assertEquals(0, result.beatsPerBar)
        assertTrue(result.bars.isEmpty())
    }

    @Test
    fun `beatsPerBar is 4 for accented 4-4 click track`() {
        val pcm = pulseAtMeter(120.0, 4)
        val result = BpmDetector.detect(pcm, 44100, 1)
        assertEquals(4, result.beatsPerBar)
    }

    @Test
    fun `beatsPerBar is 3 for accented 3-4 waltz click track`() {
        val pcm = pulseAtMeter(120.0, 3)
        val result = BpmDetector.detect(pcm, 44100, 1)
        assertEquals(3, result.beatsPerBar)
    }

    @Test
    fun `bars list is monotonically increasing`() {
        val pcm = pulseAtMeter(120.0, 4)
        val result = BpmDetector.detect(pcm, 44100, 1)
        assertTrue(result.bars.size >= 2, "Expected at least 2 bars")
        for (i in 1 until result.bars.size) {
            assertTrue(
                result.bars[i] > result.bars[i - 1],
                "Non-monotonic: bars[$i]=${result.bars[i]} <= bars[${i-1}]=${result.bars[i-1]}"
            )
        }
    }
}

class MetronomeEngineTest {

    @Test
    fun `buildBarBuffer returns correct total sample count`() {
        val sampleRate   = 44100
        val bpm          = 120.0
        val beatsPerBar  = 4
        val channelCount = 1
        val beatFrames   = (sampleRate * 60.0 / bpm).toInt()         // 22050
        val expectedLen  = beatFrames * beatsPerBar * channelCount    // 88200

        val click  = FloatArray(1000) { 0.5f }
        val accent = FloatArray(1000) { 1.0f }

        val bar = MetronomeEngine.buildBarBuffer(
            accentPcm = accent, accentFrames = 1000,
            clickPcm  = click,  clickFrames  = 1000,
            sampleRate = sampleRate, channelCount = channelCount,
            bpm = bpm, beatsPerBar = beatsPerBar
        )

        assertEquals(expectedLen, bar.size)
    }

    @Test
    fun `buildBarBuffer places accent at frame 0`() {
        val click  = FloatArray(100) { 0.3f }
        val accent = FloatArray(100) { 0.9f }

        val bar = MetronomeEngine.buildBarBuffer(
            accentPcm = accent, accentFrames = 100,
            clickPcm  = click,  clickFrames  = 100,
            sampleRate = 44100, channelCount = 1,
            bpm = 120.0, beatsPerBar = 4
        )

        // First samples must be non-zero (accent placed at frame 0, after micro-fade ramp)
        // Micro-fade only zeros the very first sample, so check middle of accent region
        assertTrue(bar.slice(5 until 95).any { it != 0f },
            "Expected non-zero accent samples near frame 0")
    }

    @Test
    fun `buildBarBuffer places click at beat 1 position`() {
        val sampleRate = 44100
        val bpm        = 120.0
        val beatFrames = (sampleRate * 60.0 / bpm).toInt()  // 22050

        val click  = FloatArray(100) { 0.5f }
        val accent = FloatArray(100) { 1.0f }

        val bar = MetronomeEngine.buildBarBuffer(
            accentPcm = accent, accentFrames = 100,
            clickPcm  = click,  clickFrames  = 100,
            sampleRate = sampleRate, channelCount = 1,
            bpm = bpm, beatsPerBar = 4
        )

        // Click at beat 1: samples beatFrames..beatFrames+99 must be non-zero
        // (again, micro-fade only affects the very first and last few frames of the bar)
        val clickStart = beatFrames
        assertTrue(bar.slice(clickStart + 5 until clickStart + 95).any { it != 0f },
            "Expected non-zero click samples at beat 1 (frame $clickStart)")
    }

    @Test
    fun `buildBarBuffer silence between accent tail and beat 1`() {
        val sampleRate = 44100
        val bpm        = 120.0
        val beatFrames = (sampleRate * 60.0 / bpm).toInt()

        val click  = FloatArray(50) { 0.5f }
        val accent = FloatArray(50) { 1.0f }

        val bar = MetronomeEngine.buildBarBuffer(
            accentPcm = accent, accentFrames = 50,
            clickPcm  = click,  clickFrames  = 50,
            sampleRate = sampleRate, channelCount = 1,
            bpm = bpm, beatsPerBar = 4
        )

        // Region between accent tail (frame 50) and click start (beatFrames) must be silent
        for (i in 50 until beatFrames) {
            assertEquals(0f, bar[i], "Expected silence at frame $i")
        }
    }
}

class PlayOnceBehaviourTest {

    // resolveLoopWrap(isLooping, currentFrame, regionStart) returns:
    //   regionStart  — when looping (wrap back to start)
    //   null         — when one-shot (signal completion)

    @Test
    fun `resolveLoopWrap wraps to regionStart when looping`() {
        val result = resolveLoopWrap(isLooping = true, currentFrame = 100, regionStart = 42)
        assertEquals(42, result)
    }

    @Test
    fun `resolveLoopWrap returns null when not looping`() {
        val result = resolveLoopWrap(isLooping = false, currentFrame = 100, regionStart = 42)
        assertNull(result)
    }

    @Test
    fun `resolveLoopWrap returns regionStart=0 for full-file loop`() {
        val result = resolveLoopWrap(isLooping = true, currentFrame = 88200, regionStart = 0)
        assertEquals(0, result)
    }
}
