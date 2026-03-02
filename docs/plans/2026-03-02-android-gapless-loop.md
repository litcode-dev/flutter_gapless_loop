# Android Gapless Loop — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement the Android/Kotlin native layer for `flutter_gapless_loop`, achieving sample-accurate gapless looping via AudioTrack MODE_STREAM with a high-priority write thread — fully API-compatible with the existing iOS/AVAudioEngine implementation.

**Architecture:** MediaExtractor + MediaCodec decodes audio to a `FloatArray`. A dedicated write thread (`THREAD_PRIORITY_URGENT_AUDIO`) feeds PCM to `AudioTrack.write(WRITE_BLOCKING)`, wrapping the read pointer at the loop boundary with zero gap. `AudioSessionManager` owns AudioFocus and `BECOMING_NOISY`. `FlutterGaplessLoopPlugin` bridges method and event channels.

**Tech Stack:** Kotlin 2.2.20, `kotlinx-coroutines-android:1.9.0`, AudioTrack WRITE_FLOAT MODE_STREAM, MediaCodec/MediaExtractor, Android minSdk 24

---

## Pre-work: Understand existing iOS structure

Before implementing, skim these files for API parity reference:
- `ios/Classes/FlutterGaplessLoopPlugin.swift` — channel names, method names, event shapes
- `lib/src/loop_audio_player.dart` — public Dart API that both platforms must satisfy
- `lib/src/loop_audio_state.dart` — `PlayerState` values the Dart layer understands

Channel name: `"flutter_gapless_loop"` | Event channel: `"flutter_gapless_loop/events"`

State strings Dart expects: `"idle"`, `"loading"`, `"ready"`, `"playing"`, `"paused"`, `"stopped"`, `"error"`

---

### Task 1: Project Scaffolding — Package Rename, Build Config, pubspec

**Files:**
- Modify: `android/build.gradle.kts`
- Modify: `android/src/main/AndroidManifest.xml`
- Modify: `pubspec.yaml`
- Delete: `android/src/main/kotlin/com/example/flutter_gapless_loop/FlutterGaplessLoopPlugin.kt`
- Delete: `android/src/test/kotlin/com/example/flutter_gapless_loop/FlutterGaplessLoopPluginTest.kt`
- Create stub: `android/src/main/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPlugin.kt`
- Create stub: `android/src/test/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPluginTest.kt`

**Step 1: Replace android/build.gradle.kts**

```kotlin
group = "com.fluttergaplessloop"
version = "1.0-SNAPSHOT"

buildscript {
    val kotlinVersion = "2.2.20"
    repositories {
        google()
        mavenCentral()
    }
    dependencies {
        classpath("com.android.tools.build:gradle:8.11.1")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
    id("kotlin-android")
}

android {
    namespace = "com.fluttergaplessloop"
    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    defaultConfig {
        minSdk = 24
    }

    testOptions {
        unitTests {
            isIncludeAndroidResources = true
            all {
                it.useJUnitPlatform()
                it.outputs.upToDateWhen { false }
                it.testLogging {
                    events("passed", "skipped", "failed", "standardOut", "standardError")
                    showStandardStreams = true
                }
            }
        }
    }
}

dependencies {
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.9.0")
    testImplementation("org.jetbrains.kotlin:kotlin-test")
    testImplementation("org.mockito:mockito-core:5.0.0")
}
```

**Step 2: Replace android/src/main/AndroidManifest.xml**

```xml
<manifest xmlns:android="http://schemas.android.com/apk/res/android"
    package="com.fluttergaplessloop">

    <!-- Read audio files from external storage (API ≤ 32) -->
    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"
        android:maxSdkVersion="32"/>

    <!-- Read audio files from media store (API 33+) -->
    <uses-permission android:name="android.permission.READ_MEDIA_AUDIO"/>

</manifest>
```

**Step 3: Add Android platform entry to pubspec.yaml**

In the `flutter.plugin.platforms` section (after the `ios:` block), add:

```yaml
      android:
        package: com.fluttergaplessloop
        pluginClass: FlutterGaplessLoopPlugin
```

The full `flutter.plugin` section becomes:
```yaml
  plugin:
    platforms:
      ios:
        pluginClass: FlutterGaplessLoopPlugin
      android:
        package: com.fluttergaplessloop
        pluginClass: FlutterGaplessLoopPlugin
```

**Step 4: Delete old scaffold files and create new directories**

```bash
rm android/src/main/kotlin/com/example/flutter_gapless_loop/FlutterGaplessLoopPlugin.kt
rm android/src/test/kotlin/com/example/flutter_gapless_loop/FlutterGaplessLoopPluginTest.kt
rmdir android/src/main/kotlin/com/example/flutter_gapless_loop
rmdir android/src/main/kotlin/com/example
rmdir android/src/test/kotlin/com/example/flutter_gapless_loop
rmdir android/src/test/kotlin/com/example
mkdir -p android/src/main/kotlin/com/fluttergaplessloop
mkdir -p android/src/test/kotlin/com/fluttergaplessloop
```

**Step 5: Create stub plugin so the project compiles**

Create `android/src/main/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPlugin.kt`:

```kotlin
package com.fluttergaplessloop

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/** Stub — replaced in Task 7. */
class FlutterGaplessLoopPlugin : FlutterPlugin, MethodChannel.MethodCallHandler {
    private lateinit var channel: MethodChannel

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, "flutter_gapless_loop")
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) =
        result.notImplemented()

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }
}
```

**Step 6: Create stub test file**

Create `android/src/test/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPluginTest.kt`:

```kotlin
package com.fluttergaplessloop

import kotlin.test.Test
import kotlin.test.assertTrue

/** Stub — real tests added in Tasks 2 and 3. */
class FlutterGaplessLoopPluginTest {
    @Test
    fun `stub passes`() {
        assertTrue(true)
    }
}
```

**Step 7: Also add permissions to the example app's AndroidManifest.xml**

In `example/android/app/src/main/AndroidManifest.xml`, add before `<application`:

```xml
    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE"
        android:maxSdkVersion="32"/>
    <uses-permission android:name="android.permission.READ_MEDIA_AUDIO"/>
```

**Step 8: Commit**

```bash
git add android/ pubspec.yaml example/android/
git commit -m "chore: rename android package to com.fluttergaplessloop, add coroutines dep, register android platform"
```

---

### Task 2: LoopEngineError.kt, EngineState, LoopAudioException

**Files:**
- Create: `android/src/main/kotlin/com/fluttergaplessloop/LoopEngineError.kt`
- Modify: `android/src/test/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPluginTest.kt`

**Step 1: Write the failing tests**

Replace the stub test file:

```kotlin
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
}
```

**Step 2: Run tests — expect compilation failure**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop/example/android
./gradlew :flutter_gapless_loop:testDebugUnitTest 2>&1 | tail -20
```

Expected: `error: unresolved reference: LoopEngineError`

**Step 3: Create LoopEngineError.kt**

```kotlin
package com.fluttergaplessloop

/**
 * Sealed hierarchy of all errors that can be produced by [LoopAudioEngine].
 *
 * Errors are surfaced two ways:
 * 1. Via the Flutter event channel (`"type": "error"`) for asynchronous errors.
 * 2. Via the method channel result callback for synchronous failures (e.g. load).
 */
sealed class LoopEngineError {

    /** The file at [path] does not exist on the device filesystem. */
    data class FileNotFound(val path: String) : LoopEngineError()

    /** MediaCodec or MediaExtractor failed with the given [reason]. */
    data class DecodeFailed(val reason: String) : LoopEngineError()

    /** The file contains no decodable audio track with [mimeType]. */
    data class UnsupportedFormat(val mimeType: String) : LoopEngineError()

    /** [start] >= [end], or region is outside the file duration. */
    data class InvalidLoopRegion(val start: Double, val end: Double) : LoopEngineError()

    /** Seek target [requested] is beyond [duration]. */
    data class SeekOutOfBounds(val requested: Double, val duration: Double) : LoopEngineError()

    /** Crossfade [requested] exceeds 50% of the loop region ([maximum]). */
    data class CrossfadeTooLong(val requested: Double, val maximum: Double) : LoopEngineError()

    /** [AudioTrack.write] returned a negative error code [errorCode]. */
    data class AudioTrackError(val errorCode: Int) : LoopEngineError()

    /** Android audio focus was denied with [reason]. */
    data class AudioFocusDenied(val reason: String) : LoopEngineError()

    /** Human-readable description suitable for sending to Dart. */
    fun toMessage(): String = when (this) {
        is FileNotFound      -> "File not found: $path"
        is DecodeFailed      -> "Decode failed: $reason"
        is UnsupportedFormat -> "Unsupported audio format: $mimeType"
        is InvalidLoopRegion -> "Invalid loop region: start=$start end=$end"
        is SeekOutOfBounds   -> "Seek $requested s out of bounds (duration: $duration s)"
        is CrossfadeTooLong  -> "Crossfade $requested s exceeds maximum $maximum s"
        is AudioTrackError   -> "AudioTrack error code: $errorCode"
        is AudioFocusDenied  -> "Audio focus denied: $reason"
    }
}

/**
 * Exception wrapper around [LoopEngineError].
 *
 * Used to propagate errors through Kotlin suspend functions and coroutine scopes
 * while carrying the structured error type for Dart result callbacks.
 */
class LoopAudioException(val error: LoopEngineError) : RuntimeException(error.toMessage())

/**
 * Operational state of [LoopAudioEngine].
 *
 * Mirrors iOS `EngineState` enum. The [rawValue] string is what is sent to Dart
 * via the event channel `stateChange` event.
 */
sealed class EngineState {
    object Idle    : EngineState()
    object Loading : EngineState()
    object Ready   : EngineState()
    object Playing : EngineState()
    object Paused  : EngineState()
    object Stopped : EngineState()
    data class Error(val error: LoopEngineError) : EngineState()

    val rawValue: String get() = when (this) {
        is Idle    -> "idle"
        is Loading -> "loading"
        is Ready   -> "ready"
        is Playing -> "playing"
        is Paused  -> "paused"
        is Stopped -> "stopped"
        is Error   -> "error"
    }
}
```

**Step 4: Run tests — expect pass**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop/example/android
./gradlew :flutter_gapless_loop:testDebugUnitTest 2>&1 | tail -20
```

Expected: `BUILD SUCCESSFUL` / all tests `PASSED`

**Step 5: Commit**

```bash
git add android/src/main/kotlin/com/fluttergaplessloop/LoopEngineError.kt \
        android/src/test/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPluginTest.kt
git commit -m "feat(android): add LoopEngineError, EngineState, LoopAudioException"
```

---

### Task 3: CrossfadeEngine.kt

**Files:**
- Create: `android/src/main/kotlin/com/fluttergaplessloop/CrossfadeEngine.kt`
- Modify: `android/src/test/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPluginTest.kt`

**Step 1: Add failing tests** (append to the test file)

```kotlin
import kotlin.math.abs

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
    fun `equal power property: fadeOut^2 + fadeIn^2 is near 1 at midpoint`() {
        val engine = CrossfadeEngine(44100, 1)
        engine.configure(0.1)
        val n = engine.fadeFrames
        val tail = FloatArray(n) { 1.0f }
        val head = FloatArray(n) { 1.0f }
        val block = engine.computeCrossfadeBlock(tail, head)
        // At midpoint, cos²+sin²=1 → blended amplitude should ≈ 1.0
        val mid = n / 2
        assertTrue(abs(block[mid] - 1.0f) < 0.05f, "Power at midpoint: ${block[mid]}")
    }

    @Test
    fun `reset clears fadeFrames`() {
        val engine = CrossfadeEngine(44100, 1)
        engine.configure(0.1)
        engine.reset()
        assertEquals(0, engine.fadeFrames)
    }

    @Test
    fun `stereo block has correct sample count`() {
        val engine = CrossfadeEngine(44100, 2)
        engine.configure(0.05)
        val n = engine.fadeFrames * 2 // stereo
        val tail = FloatArray(n) { 0.8f }
        val head = FloatArray(n) { 0.2f }
        val block = engine.computeCrossfadeBlock(tail, head)
        assertEquals(n, block.size)
    }
}
```

**Step 2: Run tests — expect compilation failure**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop/example/android
./gradlew :flutter_gapless_loop:testDebugUnitTest 2>&1 | tail -20
```

Expected: `error: unresolved reference: CrossfadeEngine`

**Step 3: Create CrossfadeEngine.kt**

```kotlin
package com.fluttergaplessloop

import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.sin

/**
 * Pre-computes an equal-power crossfade ramp and blends loop-boundary samples.
 *
 * Equal-power formula guarantees constant perceived loudness across the transition:
 *   fadeOut[i] = cos(i / N * π/2)   → 1.0 at i=0, 0.0 at i=N
 *   fadeIn[i]  = sin(i / N * π/2)   → 0.0 at i=0, 1.0 at i=N
 *   cos²(θ) + sin²(θ) = 1  ∴ sum of squared amplitudes is always 1
 *
 * All CPU work is done in [configure]; [computeCrossfadeBlock] is O(N) multiply-add,
 * safe to call from the write thread.
 *
 * @param sampleRate Audio sample rate (Hz).
 * @param channelCount Number of interleaved channels (1 = mono, 2 = stereo).
 */
class CrossfadeEngine(
    private val sampleRate: Int,
    private val channelCount: Int
) {
    private var fadeOutRamp: FloatArray = FloatArray(0)
    private var fadeInRamp: FloatArray  = FloatArray(0)

    /** Number of audio frames in the crossfade window. 0 = not configured. */
    var fadeFrames: Int = 0
        private set

    /**
     * Pre-computes equal-power ramps for the given [durationSeconds].
     *
     * Must be called before [computeCrossfadeBlock]. Can be called again when
     * the user changes crossfade duration — ramps are fully replaced.
     *
     * @param durationSeconds Crossfade duration in seconds. Must be > 0.
     */
    fun configure(durationSeconds: Double) {
        fadeFrames = (sampleRate * durationSeconds).toInt()
        val n = fadeFrames.toFloat()
        // Pre-compute ramps over [0, π/2] for equal-power blend
        fadeOutRamp = FloatArray(fadeFrames) { i -> cos(i / n * (PI / 2.0)).toFloat() }
        fadeInRamp  = FloatArray(fadeFrames) { i -> sin(i / n * (PI / 2.0)).toFloat() }
    }

    /**
     * Blends [tailSamples] (end of loop) and [headSamples] (start of loop) into a
     * crossfade block using the pre-computed equal-power ramps.
     *
     * Both arrays must be interleaved PCM of length `fadeFrames * channelCount`.
     * Returns a new `FloatArray` of the same length suitable for writing to `AudioTrack`.
     *
     * This function allocates one `FloatArray` — call from setup code, not from inside
     * the write loop. Store the result and reuse it every loop iteration.
     *
     * @throws IllegalArgumentException if tail and head sizes differ.
     */
    fun computeCrossfadeBlock(tailSamples: FloatArray, headSamples: FloatArray): FloatArray {
        require(tailSamples.size == headSamples.size) {
            "tail (${tailSamples.size}) and head (${headSamples.size}) must have the same size"
        }
        val out = FloatArray(tailSamples.size)
        for (frame in 0 until fadeFrames) {
            // Clamp ramp index to last valid position (defensive, should not trigger)
            val rampIdx = frame.coerceAtMost(fadeFrames - 1)
            val fo = fadeOutRamp[rampIdx]
            val fi = fadeInRamp[rampIdx]
            for (ch in 0 until channelCount) {
                val idx = frame * channelCount + ch
                // Equal-power blend: tail fades out while head fades in
                out[idx] = tailSamples[idx] * fo + headSamples[idx] * fi
            }
        }
        return out
    }

    /**
     * Resets all state. Call when the user removes crossfade or changes loop region
     * so a stale crossfade block is not applied.
     */
    fun reset() {
        fadeFrames  = 0
        fadeOutRamp = FloatArray(0)
        fadeInRamp  = FloatArray(0)
    }
}
```

**Step 4: Run tests — expect all pass**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop/example/android
./gradlew :flutter_gapless_loop:testDebugUnitTest 2>&1 | tail -20
```

Expected: `BUILD SUCCESSFUL` — all `CrossfadeEngineTest` tests `PASSED`

**Step 5: Commit**

```bash
git add android/src/main/kotlin/com/fluttergaplessloop/CrossfadeEngine.kt \
        android/src/test/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPluginTest.kt
git commit -m "feat(android): add CrossfadeEngine with equal-power ramps and unit tests"
```

---

### Task 4: AudioFileLoader.kt

**Files:**
- Create: `android/src/main/kotlin/com/fluttergaplessloop/AudioFileLoader.kt`

Note: MediaExtractor and MediaCodec are Android system classes — meaningful unit tests require
a real device or Robolectric. This file is tested via the example app in Task 8.

**Step 1: Create AudioFileLoader.kt**

```kotlin
package com.fluttergaplessloop

import android.content.res.AssetFileDescriptor
import android.media.AudioFormat
import android.media.MediaCodec
import android.media.MediaExtractor
import android.media.MediaFormat
import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Decodes audio files to a normalized `FloatArray` using [MediaExtractor] and [MediaCodec].
 *
 * Supports any container/codec recognized by the Android MediaCodec framework:
 * MP3, AAC, FLAC, OGG/Vorbis, WAV (PCM). Format is detected automatically from
 * the MIME type exposed by [MediaExtractor.getTrackFormat].
 *
 * Decoded PCM is always float, normalized to the range [-1.0, 1.0]:
 * - PCM_16BIT output: `floatSample = shortSample / 32768.0f`
 * - PCM_FLOAT output: passed through unchanged
 *
 * All operations run on [Dispatchers.IO]. Never call from the main thread.
 */
object AudioFileLoader {

    private const val TAG = "AudioFileLoader"

    /** Codec dequeue timeout in microseconds (10 ms). */
    private const val CODEC_TIMEOUT_US = 10_000L

    /**
     * Decoded audio data plus metadata needed to configure [AudioTrack] and the write thread.
     *
     * @param pcm        Interleaved float samples, normalized [-1.0, 1.0]. Length = totalFrames * channelCount.
     * @param sampleRate Sample rate in Hz (e.g. 44100, 48000).
     * @param channelCount Number of channels (1 = mono, 2 = stereo).
     * @param totalFrames Total number of audio frames (pcm.size / channelCount).
     */
    data class DecodedAudio(
        val pcm: FloatArray,
        val sampleRate: Int,
        val channelCount: Int,
        val totalFrames: Int
    )

    /**
     * Decodes the audio file at [path] to [DecodedAudio].
     *
     * Runs on [Dispatchers.IO]. Never call from the main thread or the write thread.
     *
     * @param path          Absolute filesystem path to the audio file.
     * @param onProgress    Optional progress callback, called with values in [0.0, 1.0].
     * @throws LoopAudioException wrapping [LoopEngineError.FileNotFound] if the file is missing.
     * @throws LoopAudioException wrapping [LoopEngineError.UnsupportedFormat] if no audio track found.
     * @throws LoopAudioException wrapping [LoopEngineError.DecodeFailed] on codec errors.
     */
    suspend fun decode(
        path: String,
        onProgress: ((Float) -> Unit)? = null
    ): DecodedAudio = withContext(Dispatchers.IO) {
        if (!File(path).exists()) {
            throw LoopAudioException(LoopEngineError.FileNotFound(path))
        }
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            extractor.setDataSource(path)
            decodeFromExtractor(extractor, codec, onProgress)
        } finally {
            safeRelease(extractor, codec)
        }
    }

    /**
     * Decodes an audio file exposed via [assetFd] (from `context.assets.openFd()`).
     *
     * Used by the `loadAsset` method channel handler to read Flutter bundled assets
     * without extracting them to the filesystem.
     *
     * @param assetFd       [AssetFileDescriptor] obtained from the Flutter asset registry.
     * @param onProgress    Optional progress callback.
     * @throws LoopAudioException on decode failure.
     */
    suspend fun decodeAsset(
        assetFd: AssetFileDescriptor,
        onProgress: ((Float) -> Unit)? = null
    ): DecodedAudio = withContext(Dispatchers.IO) {
        val extractor = MediaExtractor()
        var codec: MediaCodec? = null
        try {
            // setDataSource with offset+length is required for assets embedded in the APK
            extractor.setDataSource(assetFd.fileDescriptor, assetFd.startOffset, assetFd.declaredLength)
            decodeFromExtractor(extractor, codec, onProgress)
        } finally {
            safeRelease(extractor, codec)
        }
    }

    /**
     * Applies a 5 ms linear micro-fade in-place at both ends of [pcm].
     *
     * This eliminates clicks at the loop boundary by ensuring the sample amplitude
     * approaches zero at frame 0 and at the last frame. Applied once at load time —
     * never during playback.
     *
     * Formula:
     *   fadeFrames = (sampleRate * 0.005).toInt()
     *   fade-in:  pcm[i * ch + c]               *= i / fadeFrames   (first fadeFrames frames)
     *   fade-out: pcm[(totalFrames-1-i) * ch + c] *= i / fadeFrames   (last fadeFrames frames)
     */
    fun applyMicroFade(pcm: FloatArray, sampleRate: Int, channelCount: Int) {
        val fadeFrames = (sampleRate * 0.005).toInt().coerceAtLeast(1)
        val totalFrames = pcm.size / channelCount
        for (i in 0 until fadeFrames) {
            val gain = i.toFloat() / fadeFrames.toFloat()
            // Fade in: scale down the first N frames from silence to full amplitude
            for (ch in 0 until channelCount) {
                pcm[i * channelCount + ch] *= gain
            }
            // Fade out: scale down the last N frames from full amplitude to silence
            val endFrame = totalFrames - 1 - i
            if (endFrame > i) { // Guard: skip if file is shorter than 2 × fadeFrames
                for (ch in 0 until channelCount) {
                    pcm[endFrame * channelCount + ch] *= gain
                }
            }
        }
    }

    // ─── Private helpers ────────────────────────────────────────────────────

    /**
     * Core decode loop shared by [decode] and [decodeAsset].
     *
     * Feeds encoded data from [extractor] through [MediaCodec] input buffers and
     * collects decoded PCM from output buffers until END_OF_STREAM is signaled.
     *
     * The codec state machine:
     *   UNINITIALIZED → configure() → CONFIGURED → start() → EXECUTING
     *   In EXECUTING: dequeueInputBuffer / queueInputBuffer / dequeueOutputBuffer loop
     *   After EOS output: stop() → release()
     */
    private fun decodeFromExtractor(
        extractor: MediaExtractor,
        codecRef: MediaCodec?,
        onProgress: ((Float) -> Unit)?
    ): DecodedAudio {
        // Locate the first audio track
        val trackIndex = findAudioTrack(extractor)
            ?: throw LoopAudioException(
                LoopEngineError.UnsupportedFormat("No audio track found in file")
            )
        extractor.selectTrack(trackIndex)

        val format = extractor.getTrackFormat(trackIndex)
        val mime = format.getString(MediaFormat.KEY_MIME)
            ?: throw LoopAudioException(LoopEngineError.UnsupportedFormat("null MIME type"))
        val sampleRate   = format.getInteger(MediaFormat.KEY_SAMPLE_RATE)
        val channelCount = format.getInteger(MediaFormat.KEY_CHANNEL_COUNT)

        // Estimate duration for progress reporting (may be 0 for some formats)
        val durationUs = if (format.containsKey(MediaFormat.KEY_DURATION))
            format.getLong(MediaFormat.KEY_DURATION) else 0L
        val estFrames = ((durationUs / 1_000_000.0) * sampleRate).toInt().coerceAtLeast(1)

        Log.i(TAG, "Decoding: mime=$mime rate=$sampleRate ch=$channelCount ~$estFrames frames")

        // Create and configure decoder
        val codec = MediaCodec.createDecoderByType(mime)
        codec.configure(format, null, null, /* flags = */ 0)
        codec.start()

        val chunks = ArrayList<FloatArray>(estFrames / 2048 + 1)
        var totalSamples = 0
        val bufferInfo = MediaCodec.BufferInfo()
        var inputDone  = false
        var outputDone = false
        var currentOutputFormat = codec.outputFormat

        while (!outputDone) {
            // ── Feed compressed data to codec input ──────────────────────────
            if (!inputDone) {
                val inIdx = codec.dequeueInputBuffer(CODEC_TIMEOUT_US)
                if (inIdx >= 0) {
                    val inBuf = codec.getInputBuffer(inIdx)
                        ?: throw LoopAudioException(
                            LoopEngineError.DecodeFailed("Null input buffer at index $inIdx")
                        )
                    val sampleSize = extractor.readSampleData(inBuf, 0)
                    if (sampleSize < 0) {
                        // No more data — signal end of stream to codec
                        codec.queueInputBuffer(inIdx, 0, 0, 0L, MediaCodec.BUFFER_FLAG_END_OF_STREAM)
                        inputDone = true
                        Log.d(TAG, "Input EOS signaled")
                    } else {
                        codec.queueInputBuffer(inIdx, 0, sampleSize, extractor.sampleTime, 0)
                        extractor.advance()
                    }
                }
            }

            // ── Collect decoded PCM from codec output ────────────────────────
            val outIdx = codec.dequeueOutputBuffer(bufferInfo, CODEC_TIMEOUT_US)
            when {
                outIdx >= 0 -> {
                    val outBuf = codec.getOutputBuffer(outIdx)
                    if (outBuf != null && bufferInfo.size > 0) {
                        val chunk = extractFloatChunk(outBuf, bufferInfo, currentOutputFormat)
                        chunks.add(chunk)
                        totalSamples += chunk.size

                        // Report progress if caller requested it
                        if (durationUs > 0 && onProgress != null) {
                            val framesDecoded = totalSamples / channelCount
                            onProgress(framesDecoded.toFloat() / estFrames.toFloat())
                        }
                    }
                    codec.releaseOutputBuffer(outIdx, false)

                    if (bufferInfo.flags and MediaCodec.BUFFER_FLAG_END_OF_STREAM != 0) {
                        outputDone = true
                        Log.d(TAG, "Output EOS received")
                    }
                }
                outIdx == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED -> {
                    // Codec changed output format mid-stream (common for AAC)
                    currentOutputFormat = codec.outputFormat
                    Log.d(TAG, "Output format changed: $currentOutputFormat")
                }
                // INFO_TRY_AGAIN_LATER (-1): no output available yet, loop again
            }
        }

        // Stop and release codec here (before returning from helper)
        try { codec.stop()    } catch (_: Exception) {}
        try { codec.release() } catch (_: Exception) {}

        // Concatenate all decoded chunks into a single contiguous FloatArray
        val pcm = FloatArray(totalSamples)
        var offset = 0
        for (chunk in chunks) {
            chunk.copyInto(pcm, offset)
            offset += chunk.size
        }

        val totalFrames = totalSamples / channelCount
        Log.i(TAG, "Decode complete: $totalFrames frames, $sampleRate Hz, $channelCount ch")
        return DecodedAudio(pcm, sampleRate, channelCount, totalFrames)
    }

    /**
     * Scans [extractor]'s tracks and returns the index of the first audio track, or null.
     */
    private fun findAudioTrack(extractor: MediaExtractor): Int? {
        for (i in 0 until extractor.trackCount) {
            val mime = extractor.getTrackFormat(i).getString(MediaFormat.KEY_MIME) ?: continue
            if (mime.startsWith("audio/")) return i
        }
        return null
    }

    /**
     * Extracts samples from [outBuf] and normalizes to Float [-1.0, 1.0].
     *
     * Handles both PCM_16BIT (most common) and PCM_FLOAT codec output.
     * The encoding is detected from [format]'s KEY_PCM_ENCODING if present,
     * defaulting to PCM_16BIT for compatibility with older devices.
     */
    private fun extractFloatChunk(
        outBuf: ByteBuffer,
        bufferInfo: MediaCodec.BufferInfo,
        format: MediaFormat
    ): FloatArray {
        outBuf.position(bufferInfo.offset)
        outBuf.limit(bufferInfo.offset + bufferInfo.size)

        val encoding = if (format.containsKey(MediaFormat.KEY_PCM_ENCODING))
            format.getInteger(MediaFormat.KEY_PCM_ENCODING)
        else
            AudioFormat.ENCODING_PCM_16BIT

        return when (encoding) {
            AudioFormat.ENCODING_PCM_FLOAT -> {
                // Codec outputs 32-bit float — copy directly
                val buf = outBuf.order(ByteOrder.nativeOrder()).asFloatBuffer()
                FloatArray(buf.remaining()).also { arr -> buf.get(arr) }
            }
            else -> {
                // PCM_16BIT: convert to float by dividing by 32768
                val buf = outBuf.order(ByteOrder.nativeOrder()).asShortBuffer()
                FloatArray(buf.remaining()) { buf.get() / 32768.0f }
            }
        }
    }

    /**
     * Safely releases [extractor] and [codec], swallowing any exceptions.
     * Called in `finally` blocks to guarantee no resource leaks on any code path.
     */
    private fun safeRelease(extractor: MediaExtractor, codec: MediaCodec?) {
        try { extractor.release() } catch (_: Exception) {}
        try { codec?.stop()       } catch (_: Exception) {}
        try { codec?.release()    } catch (_: Exception) {}
    }
}
```

**Step 2: Verify the project still compiles**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop/example/android
./gradlew :flutter_gapless_loop:assembleDebug 2>&1 | tail -20
```

Expected: `BUILD SUCCESSFUL`

**Step 3: Commit**

```bash
git add android/src/main/kotlin/com/fluttergaplessloop/AudioFileLoader.kt
git commit -m "feat(android): add AudioFileLoader (MediaExtractor+MediaCodec decoder)"
```

---

### Task 5: AudioSessionManager.kt

**Files:**
- Create: `android/src/main/kotlin/com/fluttergaplessloop/AudioSessionManager.kt`

Note: AudioFocus and BroadcastReceiver require a real Android context — tested via example app in Task 8.

**Step 1: Create AudioSessionManager.kt**

```kotlin
package com.fluttergaplessloop

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.util.Log

/**
 * Manages Android audio focus and audio route change notifications.
 *
 * Audio focus prevents multiple apps from playing audio simultaneously.
 * This manager requests AUDIOFOCUS_GAIN before playback and responds to
 * focus changes per Android audio best practices.
 *
 * Route changes (headphone unplug) are detected via ACTION_AUDIO_BECOMING_NOISY.
 *
 * Lifecycle:
 * 1. Call [initialize] once after construction to register receivers.
 * 2. Call [requestAudioFocus] before calling [AudioTrack.play].
 * 3. Call [abandonAudioFocus] on pause/stop.
 * 4. Call [dispose] when the engine is torn down — this unregisters all receivers.
 *
 * All callbacks ([onFocusLoss], [onFocusGain], etc.) are invoked on the
 * Android main thread by the system. Dispatch to coroutines as needed.
 */
class AudioSessionManager(private val context: Context) {

    companion object {
        private const val TAG = "AudioSessionManager"
    }

    // ─── Callbacks (set by LoopAudioEngine) ─────────────────────────────────

    /** Called on permanent focus loss (e.g. another app starts playing). Stop playback. */
    var onFocusLoss: (() -> Unit)? = null

    /** Called on transient focus loss (e.g. incoming call). Pause playback. */
    var onFocusLossTransient: (() -> Unit)? = null

    /** Called when focus is regained after a transient loss. Resume if was playing. */
    var onFocusGain: (() -> Unit)? = null

    /**
     * Called when the system requests ducking or un-ducking.
     * Argument is the target volume multiplier: 0.2f = duck, 1.0f = restore.
     */
    var onDuckVolume: ((Float) -> Unit)? = null

    /**
     * Called when the audio route changes in a way that requires a pause.
     * Argument is the reason string sent to Dart: "headphonesUnplugged".
     */
    var onRouteChange: ((String) -> Unit)? = null

    // ─── AudioAttributes (shared with AudioTrack builder) ────────────────────

    /**
     * AudioAttributes for media music playback.
     * Pass this to [AudioTrack.Builder.setAudioAttributes] so the system can
     * apply correct routing, volume, and focus policies.
     */
    val audioAttributes: AudioAttributes = AudioAttributes.Builder()
        .setUsage(AudioAttributes.USAGE_MEDIA)
        .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
        .build()

    // ─── Private state ────────────────────────────────────────────────────────

    private val audioManager = context.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var focusRequest: AudioFocusRequest? = null // API 26+
    private var noisyReceiver: BroadcastReceiver? = null

    /** True if a transient focus loss occurred while playback was active. */
    private var wasPlayingBeforeTransientLoss = false

    // ─── Public API ──────────────────────────────────────────────────────────

    /**
     * Registers the ACTION_AUDIO_BECOMING_NOISY broadcast receiver.
     * Must be called once after construction, before any playback begins.
     */
    fun initialize() {
        registerNoisyReceiver()
        Log.i(TAG, "Initialized")
    }

    /**
     * Requests AUDIOFOCUS_GAIN from the Android audio system.
     *
     * Uses [AudioFocusRequest] on API 26+ and the deprecated overload on API 24–25.
     *
     * @return true if focus was granted immediately; false if denied.
     */
    fun requestAudioFocus(): Boolean {
        val granted = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            requestFocusModern()
        } else {
            requestFocusLegacy()
        }
        Log.i(TAG, "requestAudioFocus: granted=$granted")
        return granted
    }

    /**
     * Abandons audio focus. Call on pause and stop so other apps can take focus.
     */
    fun abandonAudioFocus() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            focusRequest?.let { audioManager.abandonAudioFocusRequest(it) }
        } else {
            @Suppress("DEPRECATION")
            audioManager.abandonAudioFocus(focusChangeListener)
        }
        Log.i(TAG, "Audio focus abandoned")
    }

    /**
     * Releases all resources. Must be called when [LoopAudioEngine.dispose] is called.
     * After this call the instance must not be reused.
     */
    fun dispose() {
        abandonAudioFocus()
        unregisterNoisyReceiver()
        // Null out callbacks to break any reference cycles
        onFocusLoss         = null
        onFocusLossTransient = null
        onFocusGain         = null
        onDuckVolume        = null
        onRouteChange       = null
        Log.i(TAG, "Disposed")
    }

    // ─── Private helpers ──────────────────────────────────────────────────────

    /** API 26+ focus request path. */
    private fun requestFocusModern(): Boolean {
        val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(audioAttributes)
            .setAcceptsDelayedFocusGain(false)
            .setOnAudioFocusChangeListener(focusChangeListener)
            .build()
        focusRequest = req
        return audioManager.requestAudioFocus(req) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    /** Legacy focus request for API 24–25. */
    @Suppress("DEPRECATION")
    private fun requestFocusLegacy(): Boolean {
        return audioManager.requestAudioFocus(
            focusChangeListener,
            AudioManager.STREAM_MUSIC,
            AudioManager.AUDIOFOCUS_GAIN
        ) == AudioManager.AUDIOFOCUS_REQUEST_GRANTED
    }

    /**
     * Reacts to audio focus change notifications from the system.
     *
     * This listener is called on the main thread by AudioManager.
     * All callbacks here are therefore safe to interact with Dart EventSink
     * as long as the engine dispatches to main when sending events.
     */
    private val focusChangeListener = AudioManager.OnAudioFocusChangeListener { change ->
        Log.d(TAG, "Focus change: $change")
        when (change) {
            AudioManager.AUDIOFOCUS_LOSS -> {
                // Permanent loss — another app owns audio. Stop playback completely.
                onFocusLoss?.invoke()
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT -> {
                // Temporary loss (e.g. phone call). Pause; resume on GAIN.
                wasPlayingBeforeTransientLoss = true
                onFocusLossTransient?.invoke()
            }
            AudioManager.AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK -> {
                // Another app needs brief audio (e.g. navigation prompt). Duck to 20%.
                onDuckVolume?.invoke(0.2f)
            }
            AudioManager.AUDIOFOCUS_GAIN -> {
                // Focus restored. Restore volume; resume if we were playing.
                onDuckVolume?.invoke(1.0f)
                if (wasPlayingBeforeTransientLoss) {
                    wasPlayingBeforeTransientLoss = false
                    onFocusGain?.invoke()
                }
            }
        }
    }

    private fun registerNoisyReceiver() {
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(context: Context?, intent: Intent?) {
                if (intent?.action == AudioManager.ACTION_AUDIO_BECOMING_NOISY) {
                    Log.i(TAG, "BECOMING_NOISY — headphones unplugged")
                    // Pause playback and report to Dart so the UI can reflect this
                    onRouteChange?.invoke("headphonesUnplugged")
                }
            }
        }
        context.registerReceiver(receiver, IntentFilter(AudioManager.ACTION_AUDIO_BECOMING_NOISY))
        noisyReceiver = receiver
        Log.d(TAG, "BECOMING_NOISY receiver registered")
    }

    private fun unregisterNoisyReceiver() {
        noisyReceiver?.let { receiver ->
            try {
                context.unregisterReceiver(receiver)
                Log.d(TAG, "BECOMING_NOISY receiver unregistered")
            } catch (e: IllegalArgumentException) {
                // Receiver was never registered (e.g. dispose called before initialize)
                Log.w(TAG, "Receiver not registered: ${e.message}")
            }
            noisyReceiver = null
        }
    }
}
```

**Step 2: Verify compile**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop/example/android
./gradlew :flutter_gapless_loop:assembleDebug 2>&1 | tail -10
```

Expected: `BUILD SUCCESSFUL`

**Step 3: Commit**

```bash
git add android/src/main/kotlin/com/fluttergaplessloop/AudioSessionManager.kt
git commit -m "feat(android): add AudioSessionManager (AudioFocus + BECOMING_NOISY)"
```

---

### Task 6: LoopAudioEngine.kt

**Files:**
- Create: `android/src/main/kotlin/com/fluttergaplessloop/LoopAudioEngine.kt`

This is the largest file. It owns the AudioTrack, write thread, state machine, and mode selection.

**Step 1: Create LoopAudioEngine.kt**

```kotlin
package com.fluttergaplessloop

import android.content.Context
import android.media.AudioFormat
import android.media.AudioTrack
import android.os.Process
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import java.util.concurrent.Semaphore
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/*
 * ARCHITECTURE NOTE — Why AudioTrack MODE_STREAM over Oboe or setLoopPoints()
 *
 * Three options were evaluated:
 *
 * Option A — AudioTrack.setLoopPoints() (MODE_STATIC):
 *   Rejected: 2 MB static buffer limit disqualifies large audio files. Known OEM
 *   inconsistencies on Huawei, Samsung make it unreliable for production.
 *
 * Option B — Oboe (C++ via JNI, CMakeLists.txt):
 *   Rejected: Oboe's primary advantage is ultra-low latency for the INPUT path
 *   (real-time instruments, monitoring). For pure PLAYBACK the latency is equivalent
 *   to AudioTrack, and the added NDK build complexity (CMakeLists, .so, JNI bridge)
 *   makes the plugin harder to integrate in host apps. No benefit for this use case.
 *
 * Option C — AudioTrack WRITE_FLOAT MODE_STREAM (CHOSEN):
 *   A dedicated write thread with THREAD_PRIORITY_URGENT_AUDIO feeds the AudioTrack
 *   a continuous stream of PCM. The write thread wraps the read pointer at the loop
 *   boundary atomically — the hardware renderer sees an uninterrupted byte stream,
 *   producing zero gap. This is the direct Android analog of iOS AVAudioEngine's
 *   scheduleBuffer(.loops).
 *
 * Threading:
 *   Main thread         ← Flutter method channel calls, EventSink dispatch
 *   IO coroutine        ← MediaExtractor + MediaCodec file decode
 *   writeThread         ← AudioTrack.write(WRITE_BLOCKING), wrap-around logic
 *   engineScope(Main)   ← state change callbacks dispatched to Dart
 */

/**
 * Core audio engine for sample-accurate gapless looping on Android.
 *
 * ## Playback Modes (auto-selected)
 * - **Mode A** (default): full file, no crossfade — write thread wraps at `totalFrames`
 * - **Mode B**: loop region, no crossfade — write thread wraps at `loopEndFrame`
 * - **Mode C**: full file + crossfade — crossfade block inserted at wrap point
 * - **Mode D**: loop region + crossfade
 *
 * ## Usage
 * ```kotlin
 * val engine = LoopAudioEngine(context)
 * engine.onStateChange = { state -> ... }
 * coroutineScope.launch { engine.loadFile("/sdcard/loop.mp3") }
 * engine.play()
 * ```
 */
class LoopAudioEngine(private val context: Context) {

    companion object {
        private const val TAG = "LoopAudioEngine"

        /**
         * AudioTrack buffer size multiplier.
         * 4× minimum provides sufficient headroom for the write thread without
         * excessive latency.
         */
        private const val BUFFER_MULTIPLIER = 4
    }

    // ─── Public callbacks ─────────────────────────────────────────────────────

    /** Called on every [EngineState] transition. Always invoked on the main thread. */
    var onStateChange: ((EngineState) -> Unit)? = null

    /** Called when an error occurs. Always invoked on the main thread. */
    var onError: ((LoopEngineError) -> Unit)? = null

    /**
     * Called when an audio route change requires a pause.
     * The argument matches iOS: "headphonesUnplugged" or "categoryChange".
     */
    var onRouteChange: ((String) -> Unit)? = null

    // ─── Public read-only state ───────────────────────────────────────────────

    private var _state: EngineState = EngineState.Idle

    /** Current engine state. Safe to read from any thread. */
    val state: EngineState get() = _state

    /** Total duration of the loaded file in seconds. */
    var duration: Double = 0.0
        private set

    /**
     * Current playback position in seconds.
     *
     * Read atomically from the write thread's frame counter so callers on any
     * thread get a consistent, up-to-date value without blocking the write thread.
     */
    val currentTime: Double
        get() {
            val frames = currentFrameAtomic.get()
            return if (sampleRate > 0) frames.toDouble() / sampleRate.toDouble() else 0.0
        }

    // ─── Private: decoded audio ───────────────────────────────────────────────

    private var pcmBuffer: FloatArray? = null
    private var sampleRate: Int = 44100
    private var channelCount: Int = 2
    private var totalFrames: Int = 0

    // ─── Private: loop region — updated atomically as a pair ─────────────────

    /**
     * Loop region boundaries, stored as an atomic pair to prevent the write thread
     * from observing a partially updated state (e.g. start updated but end not yet).
     */
    private data class LoopRegion(val start: Int, val end: Int)
    private val loopRegionRef = AtomicReference(LoopRegion(0, 0))

    private val loopStartFrame: Int get() = loopRegionRef.get().start
    private val loopEndFrame:   Int get() = loopRegionRef.get().end

    // ─── Private: crossfade ───────────────────────────────────────────────────

    private var crossfadeEngine: CrossfadeEngine? = null
    private var crossfadeDuration: Double = 0.0

    /**
     * Pre-computed crossfade block written at the loop boundary.
     * Updated atomically so the write thread always reads a complete block.
     */
    private val crossfadeBlockRef = AtomicReference<FloatArray?>(null)

    // ─── Private: write thread ────────────────────────────────────────────────

    /** Set to true to signal the write thread to exit its loop cleanly. */
    @Volatile private var stopRequested = false

    /** Set to true to signal the write thread to pause. */
    @Volatile private var pauseRequested = false

    /**
     * Semaphore used to suspend the write thread during pause without busy-waiting.
     * Starts at 0 (blocked). [resume] calls release() to unblock.
     */
    private val pauseSemaphore = Semaphore(0)

    /** Monotonically tracked playback frame position, updated by the write thread. */
    private val currentFrameAtomic = AtomicLong(0L)

    private var writeThread: Thread? = null
    private var audioTrack: AudioTrack? = null

    // ─── Private: session / coroutines ───────────────────────────────────────

    private val sessionManager = AudioSessionManager(context)

    /**
     * Coroutine scope bound to the Main dispatcher for state change callbacks.
     * SupervisorJob ensures one failed callback does not cancel the entire scope.
     */
    private val engineScope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    // ─── Initialization ───────────────────────────────────────────────────────

    init {
        wireSessionCallbacks()
        sessionManager.initialize()
    }

    // ─── Public API ──────────────────────────────────────────────────────────

    /**
     * Decodes [path] to PCM, applies micro-fade, and transitions to [EngineState.Ready].
     *
     * Suspends on [Dispatchers.IO] during MediaCodec decode. Must be called from a
     * coroutine — never from the main thread directly.
     *
     * On success: transitions to [EngineState.Ready].
     * On failure: transitions to [EngineState.Error] and rethrows as [LoopAudioException].
     *
     * @throws LoopAudioException on any decode or IO error.
     */
    suspend fun loadFile(path: String) {
        setState(EngineState.Loading)
        try {
            val decoded = AudioFileLoader.decode(path)
            AudioFileLoader.applyMicroFade(decoded.pcm, decoded.sampleRate, decoded.channelCount)
            commitDecodedAudio(decoded)
            setState(EngineState.Ready)
        } catch (e: LoopAudioException) {
            setState(EngineState.Error(e.error))
            onError?.invoke(e.error)
            throw e
        } catch (e: Exception) {
            val err = LoopEngineError.DecodeFailed(e.message ?: "Unknown error")
            setState(EngineState.Error(err))
            onError?.invoke(err)
            throw LoopAudioException(err)
        }
    }

    /**
     * Decodes a Flutter asset identified by [assetKey] using [assetFd].
     *
     * @param assetKey Human-readable key (for logging).
     * @param assetFd  [android.content.res.AssetFileDescriptor] from Flutter asset registry.
     * @throws LoopAudioException on decode failure.
     */
    suspend fun loadAsset(assetKey: String, assetFd: android.content.res.AssetFileDescriptor) {
        setState(EngineState.Loading)
        try {
            val decoded = AudioFileLoader.decodeAsset(assetFd)
            AudioFileLoader.applyMicroFade(decoded.pcm, decoded.sampleRate, decoded.channelCount)
            commitDecodedAudio(decoded)
            setState(EngineState.Ready)
            Log.i(TAG, "loadAsset complete: $assetKey")
        } catch (e: LoopAudioException) {
            setState(EngineState.Error(e.error))
            onError?.invoke(e.error)
            throw e
        } catch (e: Exception) {
            val err = LoopEngineError.DecodeFailed(e.message ?: "Unknown error")
            setState(EngineState.Error(err))
            onError?.invoke(err)
            throw LoopAudioException(err)
        }
    }

    /**
     * Starts playback from [loopStartFrame].
     *
     * Requests audio focus before starting. If focus is denied, fires [onError]
     * and returns without starting the write thread.
     */
    fun play() {
        if (_state != EngineState.Ready && _state != EngineState.Stopped) {
            Log.w(TAG, "play() ignored: state=$_state")
            return
        }
        if (!sessionManager.requestAudioFocus()) {
            val err = LoopEngineError.AudioFocusDenied("AudioManager denied AUDIOFOCUS_GAIN")
            onError?.invoke(err)
            return
        }
        currentFrameAtomic.set(loopStartFrame.toLong())
        audioTrack?.play()
        startWriteThread()
        setState(EngineState.Playing)
    }

    /**
     * Pauses playback, keeping the AudioTrack warm so [resume] produces no latency spike.
     *
     * Sets [pauseRequested] flag; the write thread suspends itself on [pauseSemaphore]
     * at its next iteration. AudioTrack.pause() stops the hardware renderer immediately.
     */
    fun pause() {
        if (_state != EngineState.Playing) {
            Log.w(TAG, "pause() ignored: state=$_state")
            return
        }
        pauseRequested = true
        audioTrack?.pause()
        sessionManager.abandonAudioFocus()
        setState(EngineState.Paused)
        Log.i(TAG, "Paused")
    }

    /**
     * Resumes a paused engine.
     *
     * Releases [pauseSemaphore] so the write thread exits its blocking wait,
     * then calls AudioTrack.play() to restart the hardware renderer.
     */
    fun resume() {
        if (_state != EngineState.Paused) {
            Log.w(TAG, "resume() ignored: state=$_state")
            return
        }
        if (!sessionManager.requestAudioFocus()) {
            val err = LoopEngineError.AudioFocusDenied("AudioManager denied AUDIOFOCUS_GAIN on resume")
            onError?.invoke(err)
            return
        }
        pauseRequested = false
        pauseSemaphore.release()   // Unblock the write thread
        audioTrack?.play()
        setState(EngineState.Playing)
        Log.i(TAG, "Resumed")
    }

    /**
     * Stops playback and resets the play cursor to [loopStartFrame].
     *
     * Joins the write thread before returning so AudioTrack is safe to manipulate.
     */
    fun stop() {
        stopWriteThread()
        audioTrack?.flush()
        currentFrameAtomic.set(loopStartFrame.toLong())
        sessionManager.abandonAudioFocus()
        setState(EngineState.Stopped)
        Log.i(TAG, "Stopped")
    }

    /**
     * Sets a custom loop region in seconds.
     *
     * Zero-crossing alignment is applied to both boundaries to minimize click risk.
     * The crossfade block is recomputed if a crossfade duration is active.
     * The write thread picks up the new [loopRegionRef] on its next wrap-around.
     *
     * @throws LoopEngineError.InvalidLoopRegion if start >= end or region is out of bounds.
     */
    fun setLoopRegion(start: Double, end: Double) {
        val buf = pcmBuffer ?: return
        if (start >= end || start < 0.0 || end > duration) {
            val err = LoopEngineError.InvalidLoopRegion(start, end)
            onError?.invoke(err)
            return
        }
        val startFrame = (start * sampleRate).toInt().coerceIn(0, totalFrames - 1)
        val endFrame   = (end   * sampleRate).toInt().coerceIn(startFrame + 1, totalFrames)
        val windowFrames = (sampleRate * 0.01).toInt() // 10 ms search window

        val alignedStart = findNearestZeroCrossing(buf, startFrame, channelCount, windowFrames, true)
        val alignedEnd   = findNearestZeroCrossing(buf, endFrame,   channelCount, windowFrames, false)

        // Update atomically — write thread will pick up on next wrap
        loopRegionRef.set(LoopRegion(alignedStart, alignedEnd))

        if (crossfadeDuration > 0.0) {
            recomputeCrossfadeBlock(buf)
        }
        Log.i(TAG, "setLoopRegion: $alignedStart–$alignedEnd frames ($start–${end}s)")
    }

    /**
     * Sets or clears the crossfade duration.
     *
     * - duration == 0: clears crossfade (Mode A or B)
     * - duration > 0: switches to Mode C or D, pre-computes crossfade block
     *
     * The crossfade must not exceed 50% of the loop region duration.
     *
     * @throws LoopEngineError.CrossfadeTooLong if duration exceeds the limit.
     */
    fun setCrossfadeDuration(seconds: Double) {
        val buf = pcmBuffer ?: return
        val loopDuration = (loopEndFrame - loopStartFrame).toDouble() / sampleRate
        val maxCrossfade = loopDuration * 0.5

        if (seconds > maxCrossfade) {
            onError?.invoke(LoopEngineError.CrossfadeTooLong(seconds, maxCrossfade))
            return
        }

        crossfadeDuration = seconds
        if (seconds > 0.0) {
            val eng = CrossfadeEngine(sampleRate, channelCount)
            eng.configure(seconds)
            crossfadeEngine = eng
            recomputeCrossfadeBlock(buf)
            Log.i(TAG, "setCrossfadeDuration: ${seconds}s (${eng.fadeFrames} frames)")
        } else {
            crossfadeEngine = null
            crossfadeBlockRef.set(null)
            Log.i(TAG, "setCrossfadeDuration: cleared")
        }
    }

    /**
     * Sets playback volume in [0.0, 1.0].
     *
     * Delegates to [AudioTrack.setVolume] which applies a software gain multiplier.
     */
    fun setVolume(volume: Float) {
        audioTrack?.setVolume(volume.coerceIn(0f, 1f))
    }

    /**
     * Seeks to [seconds] in the file.
     *
     * Updates [currentFrameAtomic] atomically. The write thread reads this value
     * at the start of each chunk fill, so the seek takes effect at the next chunk.
     *
     * @throws LoopEngineError.SeekOutOfBounds if [seconds] > [duration].
     */
    fun seek(seconds: Double) {
        if (seconds < 0.0 || seconds > duration) {
            onError?.invoke(LoopEngineError.SeekOutOfBounds(seconds, duration))
            return
        }
        val targetFrame = (seconds * sampleRate).toLong()
            .coerceIn(loopStartFrame.toLong(), loopEndFrame.toLong())
        currentFrameAtomic.set(targetFrame)
        Log.i(TAG, "seek: ${seconds}s → frame $targetFrame")
    }

    /**
     * Releases all resources. After calling this method the engine must not be reused.
     *
     * Stops the write thread, releases AudioTrack, abandons audio focus, unregisters
     * broadcast receivers, and cancels the coroutine scope.
     */
    fun dispose() {
        stopWriteThread()
        sessionManager.dispose()
        audioTrack?.release()
        audioTrack = null
        pcmBuffer = null
        crossfadeBlockRef.set(null)
        crossfadeEngine = null
        engineScope.cancel()
        _state = EngineState.Idle
        Log.i(TAG, "Disposed")
    }

    // ─── Private: audio setup ─────────────────────────────────────────────────

    /**
     * Stores decoded audio state and builds a new [AudioTrack].
     * Called inside [loadFile] after successful decode.
     */
    private fun commitDecodedAudio(decoded: AudioFileLoader.DecodedAudio) {
        // Stop any currently playing audio before replacing the buffer
        stopWriteThread()

        pcmBuffer    = decoded.pcm
        sampleRate   = decoded.sampleRate
        channelCount = decoded.channelCount
        totalFrames  = decoded.totalFrames
        duration     = decoded.totalFrames.toDouble() / decoded.sampleRate

        // Reset loop region to full file
        loopRegionRef.set(LoopRegion(0, totalFrames))
        currentFrameAtomic.set(0L)

        // Clear any stale crossfade state
        crossfadeBlockRef.set(null)
        crossfadeEngine = null
        crossfadeDuration = 0.0

        buildAudioTrack()
    }

    /**
     * Creates a new [AudioTrack] configured for the current [sampleRate] and [channelCount].
     *
     * Uses WRITE_FLOAT encoding (API 21+) for direct float PCM output without
     * the 16-bit quantization noise introduced by PCM_16BIT.
     *
     * Buffer size is 4× the system minimum to prevent underruns on slower devices.
     */
    private fun buildAudioTrack() {
        audioTrack?.release()

        val minBuf = AudioTrack.getMinBufferSize(
            sampleRate,
            if (channelCount == 1) AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO,
            AudioFormat.ENCODING_PCM_FLOAT
        )
        // 4 bytes per float sample
        val bufBytes = maxOf(minBuf * BUFFER_MULTIPLIER, 4096 * channelCount * 4)

        audioTrack = AudioTrack.Builder()
            .setAudioAttributes(sessionManager.audioAttributes)
            .setAudioFormat(
                AudioFormat.Builder()
                    .setEncoding(AudioFormat.ENCODING_PCM_FLOAT)
                    .setSampleRate(sampleRate)
                    .setChannelMask(
                        if (channelCount == 1) AudioFormat.CHANNEL_OUT_MONO
                        else AudioFormat.CHANNEL_OUT_STEREO
                    )
                    .build()
            )
            .setBufferSizeInBytes(bufBytes)
            .setTransferMode(AudioTrack.MODE_STREAM)
            .build()

        Log.i(TAG, "AudioTrack built: ${sampleRate}Hz ${channelCount}ch buf=${bufBytes}B")
    }

    // ─── Private: write thread ────────────────────────────────────────────────

    /**
     * Starts the audio write thread.
     *
     * The write thread:
     * 1. Sets its priority to THREAD_PRIORITY_URGENT_AUDIO.
     * 2. Allocates a write buffer ONCE before entering the loop.
     * 3. Fills the buffer from [pcmBuffer], wrapping at [loopEndFrame].
     * 4. Inserts the pre-computed crossfade block at the wrap point if configured.
     * 5. Writes to [AudioTrack] using WRITE_BLOCKING — never WRITE_NON_BLOCKING.
     * 6. Suspends on [pauseSemaphore] when [pauseRequested] is true.
     * 7. Exits cleanly when [stopRequested] is true.
     */
    private fun startWriteThread() {
        stopRequested  = false
        pauseRequested = false

        writeThread = Thread {
            // Highest audio priority — matches iOS THREAD_PRIORITY_URGENT_AUDIO
            Process.setThreadPriority(Process.THREAD_PRIORITY_URGENT_AUDIO)

            val track = audioTrack ?: run {
                Log.e(TAG, "Write thread started with null AudioTrack")
                return@Thread
            }
            val buffer = pcmBuffer ?: run {
                Log.e(TAG, "Write thread started with null pcmBuffer")
                return@Thread
            }

            // Chunk size: half the AudioTrack buffer in frames, converted to samples
            // Smaller chunks → lower latency for seek/stop; larger → fewer write calls
            val chunkFrames  = track.bufferSizeInFrames / 2
            val chunkSamples = chunkFrames * channelCount

            // Allocate the write buffer ONCE — never allocate inside the write loop
            val writeBuffer = FloatArray(chunkSamples)

            Log.d(TAG, "Write thread started: chunkFrames=$chunkFrames")

            try {
                while (!stopRequested) {
                    // ── Pause handling ────────────────────────────────────────
                    if (pauseRequested) {
                        // Block without spinning — Semaphore.acquire() parks the thread
                        try {
                            pauseSemaphore.acquire()
                        } catch (e: InterruptedException) {
                            Log.d(TAG, "Write thread interrupted during pause")
                            break
                        }
                        // After unblocking, re-check stop flag before writing
                        if (stopRequested) break
                        continue
                    }

                    // Read current region atomically for this chunk
                    val region       = loopRegionRef.get()
                    val regionStart  = region.start
                    val regionEnd    = region.end
                    var currentFrame = currentFrameAtomic.get().toInt()

                    // ── Fill write buffer with loop-wrapped samples ────────────
                    var writeIdx = 0
                    while (writeIdx < chunkSamples && !stopRequested && !pauseRequested) {
                        if (currentFrame >= regionEnd) {
                            // ── Loop boundary: insert crossfade block if present ──
                            val cfBlock = crossfadeBlockRef.get()
                            if (cfBlock != null && writeIdx + cfBlock.size <= chunkSamples) {
                                cfBlock.copyInto(writeBuffer, writeIdx)
                                writeIdx += cfBlock.size
                            }
                            // Wrap read pointer back to loop start
                            currentFrame = regionStart
                        }

                        // How many contiguous samples can we copy without crossing regionEnd?
                        val framesUntilEnd  = regionEnd - currentFrame
                        val samplesUntilEnd = framesUntilEnd * channelCount
                        val samplesNeeded   = chunkSamples - writeIdx
                        val samplesToCopy   = minOf(samplesNeeded, samplesUntilEnd)

                        // Copy directly from the PCM buffer — no per-sample allocation
                        val srcOffset = currentFrame * channelCount
                        buffer.copyInto(writeBuffer, writeIdx, srcOffset, srcOffset + samplesToCopy)
                        writeIdx     += samplesToCopy
                        currentFrame += samplesToCopy / channelCount
                    }

                    // Update the atomic frame counter so currentTime stays accurate
                    currentFrameAtomic.set(currentFrame.toLong())

                    // ── Write to AudioTrack ───────────────────────────────────
                    // WRITE_BLOCKING: block until the AudioTrack has consumed the data.
                    // Never use WRITE_NON_BLOCKING here — partial writes break the loop.
                    if (writeIdx > 0) {
                        val written = track.write(writeBuffer, 0, writeIdx, AudioTrack.WRITE_BLOCKING)
                        if (written < 0) {
                            // Negative return is an AudioTrack error code
                            val err = LoopEngineError.AudioTrackError(written)
                            Log.e(TAG, "AudioTrack.write error: $written")
                            engineScope.launch {
                                setState(EngineState.Error(err))
                                onError?.invoke(err)
                            }
                            break
                        }
                    }
                }
            } catch (e: Exception) {
                Log.e(TAG, "Write thread exception: ${e.message}", e)
                val err = LoopEngineError.DecodeFailed("Write thread: ${e.message}")
                engineScope.launch {
                    setState(EngineState.Error(err))
                    onError?.invoke(err)
                }
            }
            Log.d(TAG, "Write thread exited")
        }

        writeThread?.isDaemon = true
        writeThread?.start()
    }

    /**
     * Signals the write thread to stop and waits for it to exit.
     *
     * If the thread is blocked on [pauseSemaphore], releasing it allows it to
     * see [stopRequested] and exit. Waits up to 2 s before giving up.
     */
    private fun stopWriteThread() {
        stopRequested  = true
        // If write thread is blocked on pause, wake it so it can see stopRequested
        if (pauseRequested) {
            pauseRequested = false
            pauseSemaphore.release()
        }
        writeThread?.let { thread ->
            thread.interrupt()
            thread.join(2_000L) // Wait up to 2 s for clean exit
            if (thread.isAlive) Log.w(TAG, "Write thread did not exit cleanly within 2 s")
        }
        writeThread = null
        audioTrack?.pause() // Halt hardware renderer
    }

    // ─── Private: zero-crossing detection ────────────────────────────────────

    /**
     * Scans a window of up to [searchWindowFrames] from [boundary] for the nearest
     * zero-crossing in the first channel.
     *
     * A zero-crossing occurs where consecutive frames have opposite signs in the
     * first channel. The search is forward (increasing frame index) if [searchForward]
     * is true, otherwise backward.
     *
     * If no zero-crossing is found within the window, [boundary] is returned unchanged.
     * The micro-fade applied at load time handles the residual click for these cases.
     *
     * @param buffer         The PCM FloatArray to search.
     * @param boundary       The initial boundary frame index.
     * @param channelCount   Number of interleaved channels.
     * @param searchWindowFrames  Maximum frames to search.
     * @param searchForward  Search direction.
     * @return Frame index of the nearest zero-crossing, or [boundary] if none found.
     */
    private fun findNearestZeroCrossing(
        buffer: FloatArray,
        boundary: Int,
        channelCount: Int,
        searchWindowFrames: Int,
        searchForward: Boolean
    ): Int {
        val totalFrames = buffer.size / channelCount
        if (searchForward) {
            val limit = minOf(boundary + searchWindowFrames, totalFrames - 1)
            for (frame in boundary until limit) {
                val cur  = buffer[frame * channelCount]          // first channel
                val next = buffer[(frame + 1) * channelCount]
                if (cur * next <= 0f) return frame               // sign change = zero-crossing
            }
        } else {
            val limit = maxOf(boundary - searchWindowFrames, 1)
            for (frame in boundary downTo limit) {
                val prev = buffer[(frame - 1) * channelCount]
                val cur  = buffer[frame * channelCount]
                if (prev * cur <= 0f) return frame
            }
        }
        return boundary // No crossing found — return original boundary
    }

    // ─── Private: crossfade recompute ─────────────────────────────────────────

    /**
     * Recomputes and atomically replaces the crossfade block.
     *
     * The block is a pre-blended [FloatArray] that the write thread inserts at the
     * loop boundary. It is computed here (outside the write thread) so the write
     * thread never does per-loop allocation.
     */
    private fun recomputeCrossfadeBlock(buffer: FloatArray) {
        val engine = crossfadeEngine ?: return
        val fadeFrames  = engine.fadeFrames
        if (fadeFrames <= 0) return

        val fadeSamples  = fadeFrames * channelCount
        val startSample  = loopStartFrame * channelCount
        val endSample    = loopEndFrame   * channelCount

        if (startSample + fadeSamples > buffer.size || endSample - fadeSamples < 0) {
            Log.w(TAG, "Crossfade block exceeds buffer bounds — skipping")
            return
        }

        // Extract tail (last N samples before loop end) and head (first N samples from loop start)
        val tail = buffer.copyOfRange(endSample - fadeSamples, endSample)
        val head = buffer.copyOfRange(startSample, startSample + fadeSamples)

        // computeCrossfadeBlock allocates a new FloatArray — safe here, not on write thread
        val block = engine.computeCrossfadeBlock(tail, head)
        crossfadeBlockRef.set(block)
        Log.d(TAG, "Crossfade block recomputed: ${block.size} samples")
    }

    // ─── Private: state helpers ───────────────────────────────────────────────

    /**
     * Updates [_state] and dispatches [onStateChange] on the main thread.
     *
     * Thread-safe: can be called from the write thread (via [engineScope.launch]) or main.
     */
    private fun setState(newState: EngineState) {
        _state = newState
        engineScope.launch {
            onStateChange?.invoke(newState)
        }
    }

    /**
     * Connects [AudioSessionManager] callbacks to engine actions.
     * Called once during [init].
     */
    private fun wireSessionCallbacks() {
        sessionManager.onFocusLoss = {
            // Permanent focus loss — stop, notify Dart
            engineScope.launch {
                stopWriteThread()
                audioTrack?.flush()
                sessionManager.abandonAudioFocus()
                setState(EngineState.Stopped)
            }
        }
        sessionManager.onFocusLossTransient = {
            // Transient loss — pause
            engineScope.launch {
                if (_state == EngineState.Playing) pause()
            }
        }
        sessionManager.onFocusGain = {
            // Focus returned — auto-resume if we were paused due to transient loss
            engineScope.launch {
                if (_state == EngineState.Paused) resume()
            }
        }
        sessionManager.onDuckVolume = { vol ->
            setVolume(vol)
        }
        sessionManager.onRouteChange = { reason ->
            // Route change (headphones unplugged) — pause and report to Dart
            engineScope.launch {
                if (_state == EngineState.Playing) pause()
                onRouteChange?.invoke(reason)
            }
        }
    }
}
```

**Step 2: Verify compile**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop/example/android
./gradlew :flutter_gapless_loop:assembleDebug 2>&1 | tail -15
```

Expected: `BUILD SUCCESSFUL`

**Step 3: Run unit tests — existing tests must still pass**

```bash
./gradlew :flutter_gapless_loop:testDebugUnitTest 2>&1 | tail -15
```

Expected: `BUILD SUCCESSFUL` — all tests pass

**Step 4: Commit**

```bash
git add android/src/main/kotlin/com/fluttergaplessloop/LoopAudioEngine.kt
git commit -m "feat(android): add LoopAudioEngine with write thread, 4-mode state machine"
```

---

### Task 7: FlutterGaplessLoopPlugin.kt (Full Bridge)

**Files:**
- Replace: `android/src/main/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPlugin.kt`

**Step 1: Replace the stub plugin with the full implementation**

```kotlin
package com.fluttergaplessloop

import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

/**
 * Flutter plugin entry point for flutter_gapless_loop (Android).
 *
 * Registers:
 * - MethodChannel `"flutter_gapless_loop"` — handles all Dart API calls
 * - EventChannel  `"flutter_gapless_loop/events"` — pushes state changes to Dart
 *
 * Mirrors the iOS FlutterGaplessLoopPlugin in channel names, method names, and
 * event payload shapes so the shared Dart [LoopAudioPlayer] class works on both platforms.
 *
 * Threading contract:
 * - [onMethodCall] is called on the platform (main) thread by Flutter.
 * - [LoopAudioEngine.loadFile] suspends on IO; result is returned on Main.
 * - All [EventChannel.EventSink] calls are dispatched through [mainHandler] to satisfy
 *   Flutter's requirement that EventSink is only called from the platform thread.
 */
class FlutterGaplessLoopPlugin : FlutterPlugin, MethodCallHandler, EventChannel.StreamHandler {

    companion object {
        private const val TAG            = "FlutterGaplessLoopPlugin"
        private const val METHOD_CHANNEL = "flutter_gapless_loop"
        private const val EVENT_CHANNEL  = "flutter_gapless_loop/events"
    }

    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel

    /** EventSink for pushing state/error/route events to Dart. Null when not subscribed. */
    private var eventSink: EventChannel.EventSink? = null

    private var engine: LoopAudioEngine? = null
    private var pluginBinding: FlutterPlugin.FlutterPluginBinding? = null

    /** Coroutine scope for async operations (file loading). Main dispatcher = Flutter-safe. */
    private val pluginScope = CoroutineScope(Dispatchers.Main + SupervisorJob())

    /** Ensures EventSink calls are always posted to the platform (main) thread. */
    private val mainHandler = Handler(Looper.getMainLooper())

    // ─── FlutterPlugin lifecycle ──────────────────────────────────────────────

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        pluginBinding = binding

        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
        eventChannel.setStreamHandler(this)

        Log.i(TAG, "Attached to engine")
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        engine?.dispose()
        engine = null
        pluginBinding = null
        Log.i(TAG, "Detached from engine")
    }

    // ─── EventChannel.StreamHandler ──────────────────────────────────────────

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
        // Lazily create the engine when Dart subscribes (matches iOS onListen behavior)
        getOrCreateEngine()
        Log.i(TAG, "Event channel opened")
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
        Log.i(TAG, "Event channel closed")
    }

    // ─── MethodChannel.MethodCallHandler ─────────────────────────────────────

    override fun onMethodCall(call: MethodCall, result: Result) {
        val eng = getOrCreateEngine()

        when (call.method) {

            // ── Load from absolute file path ──────────────────────────────────
            "load" -> {
                val path = call.argument<String>("path")
                    ?: return result.error("INVALID_ARGS", "'path' is required", null)
                pluginScope.launch {
                    try {
                        eng.loadFile(path)
                        result.success(null)
                    } catch (e: LoopAudioException) {
                        result.error("LOAD_FAILED", e.message, null)
                    } catch (e: Exception) {
                        result.error("LOAD_FAILED", e.message, null)
                    }
                }
            }

            // ── Load from Flutter asset key ───────────────────────────────────
            "loadAsset" -> {
                val assetKey = call.argument<String>("assetKey")
                    ?: return result.error("INVALID_ARGS", "'assetKey' is required", null)
                val binding = pluginBinding
                    ?: return result.error("REGISTRAR_MISSING", "Plugin not attached", null)

                // Resolve Flutter asset key → relative APK assets path
                val assetPath = binding.flutterAssets.getAssetFilePathByName(assetKey)
                    ?: return result.error("ASSET_NOT_FOUND", "Asset not found: $assetKey", null)

                // Open asset as AssetFileDescriptor — works for assets inside the APK
                val assetFd = try {
                    binding.applicationContext.assets.openFd(assetPath)
                } catch (e: Exception) {
                    return result.error("ASSET_NOT_FOUND", "Cannot open asset: $assetKey — ${e.message}", null)
                }

                pluginScope.launch {
                    try {
                        eng.loadAsset(assetKey, assetFd)
                        result.success(null)
                    } catch (e: LoopAudioException) {
                        result.error("LOAD_FAILED", e.message, null)
                    } catch (e: Exception) {
                        result.error("LOAD_FAILED", e.message, null)
                    } finally {
                        try { assetFd.close() } catch (_: Exception) {}
                    }
                }
            }

            "play"   -> { eng.play();   result.success(null) }
            "pause"  -> { eng.pause();  result.success(null) }
            "stop"   -> { eng.stop();   result.success(null) }
            "resume" -> { eng.resume(); result.success(null) }

            "setLoopRegion" -> {
                val start = call.argument<Double>("start") ?: 0.0
                val end   = call.argument<Double>("end")   ?: 0.0
                eng.setLoopRegion(start, end)
                result.success(null)
            }

            "setCrossfadeDuration" -> {
                val duration = call.argument<Double>("duration") ?: 0.0
                eng.setCrossfadeDuration(duration)
                result.success(null)
            }

            "setVolume" -> {
                val volume = call.argument<Double>("volume")?.toFloat() ?: 1.0f
                eng.setVolume(volume)
                result.success(null)
            }

            "seek" -> {
                val position = call.argument<Double>("position") ?: 0.0
                eng.seek(position)
                result.success(null)
            }

            "getDuration"         -> result.success(eng.duration)
            "getCurrentPosition"  -> result.success(eng.currentTime)

            "dispose" -> {
                eng.dispose()
                engine = null
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    // ─── Private helpers ──────────────────────────────────────────────────────

    /**
     * Returns the existing engine or creates a fresh one.
     *
     * Creating lazily (rather than in [onAttachedToEngine]) matches the iOS pattern
     * where the engine is built in [onListen], allowing hot-restart to work correctly.
     */
    private fun getOrCreateEngine(): LoopAudioEngine {
        return engine ?: run {
            val ctx = pluginBinding?.applicationContext
                ?: throw IllegalStateException("Plugin not attached to an engine")
            val eng = LoopAudioEngine(ctx)
            wireEngineCallbacks(eng)
            engine = eng
            eng
        }
    }

    /**
     * Connects [LoopAudioEngine] callbacks to [eventSink] so Dart receives events.
     *
     * Event payload shapes (must match iOS FlutterGaplessLoopPlugin.swift):
     * - State change: `{"type": "stateChange", "state": "playing"}`
     * - Error:        `{"type": "error", "message": "..."}`
     * - Route change: `{"type": "routeChange", "reason": "headphonesUnplugged"}`
     */
    private fun wireEngineCallbacks(eng: LoopAudioEngine) {
        eng.onStateChange = { state ->
            sendEvent(mapOf("type" to "stateChange", "state" to state.rawValue))
        }
        eng.onError = { error ->
            sendEvent(mapOf("type" to "error", "message" to error.toMessage()))
        }
        eng.onRouteChange = { reason ->
            sendEvent(mapOf("type" to "routeChange", "reason" to reason))
        }
    }

    /**
     * Posts an event map to [eventSink] on the platform (main) thread.
     *
     * Flutter requires that [EventChannel.EventSink.success] is always called from
     * the platform thread. [mainHandler.post] guarantees this regardless of which
     * thread the engine callback fires on.
     */
    private fun sendEvent(event: Map<String, Any>) {
        mainHandler.post { eventSink?.success(event) }
    }
}
```

**Step 2: Verify compile and tests**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop/example/android
./gradlew :flutter_gapless_loop:assembleDebug :flutter_gapless_loop:testDebugUnitTest 2>&1 | tail -20
```

Expected: `BUILD SUCCESSFUL` — all tests pass

**Step 3: Commit**

```bash
git add android/src/main/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPlugin.kt
git commit -m "feat(android): add FlutterGaplessLoopPlugin (method+event channel bridge)"
```

---

### Task 8: Final Wiring — pubspec, flutter analyze, example app smoke-test

**Files:**
- Modify: `pubspec.yaml` — verify Android platform entry (done in Task 1)
- Verify: `flutter analyze`
- Verify: `flutter pub get` and example app builds on Android

**Step 1: Update pubspec description to mention both platforms**

In `pubspec.yaml`, change:
```yaml
description: "True sample-accurate gapless audio looping for iOS using AVAudioEngine. ..."
```
to:
```yaml
description: "True sample-accurate gapless audio looping on iOS (AVAudioEngine) and Android (AudioTrack). Zero-gap, zero-click loop playback for music production apps."
```

**Step 2: Run flutter pub get from repo root**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop
flutter pub get
```

Expected: `Got dependencies!` — no errors

**Step 3: Run flutter analyze**

```bash
flutter analyze 2>&1
```

Expected: `No issues found!` or only info-level suggestions, no errors.

**Step 4: Run Android unit tests one more time**

```bash
cd example/android
./gradlew :flutter_gapless_loop:testDebugUnitTest 2>&1 | tail -20
```

Expected: All tests `PASSED`

**Step 5: Build the example app for Android**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop/example
flutter build apk --debug 2>&1 | tail -30
```

Expected: `Built build/app/outputs/flutter-apk/app-debug.apk`

Fix any compilation errors before proceeding.

**Step 6: (Optional — requires connected device or emulator) Run example app**

```bash
flutter run -d <android-device-id>
```

Smoke-test checklist:
- [ ] App launches without crash
- [ ] File picker opens and selects an audio file
- [ ] Play button triggers state → "loading" → "ready" → "playing"
- [ ] Audio plays with no audible gap on loop boundary
- [ ] Pause and resume work
- [ ] Stop works
- [ ] Loop region sliders update without gap

**Step 7: Commit**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop
git add pubspec.yaml
git commit -m "feat(android): complete Android implementation — both platforms registered"
```

---

## Summary of All New Files

| File | Purpose |
|------|---------|
| `android/src/main/kotlin/com/fluttergaplessloop/LoopEngineError.kt` | Sealed errors + EngineState + LoopAudioException |
| `android/src/main/kotlin/com/fluttergaplessloop/CrossfadeEngine.kt` | Equal-power crossfade ramp |
| `android/src/main/kotlin/com/fluttergaplessloop/AudioFileLoader.kt` | MediaCodec decoder → FloatArray |
| `android/src/main/kotlin/com/fluttergaplessloop/AudioSessionManager.kt` | AudioFocus + BECOMING_NOISY |
| `android/src/main/kotlin/com/fluttergaplessloop/LoopAudioEngine.kt` | Core engine + write thread |
| `android/src/main/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPlugin.kt` | Channel bridge |
| `android/build.gradle.kts` | Updated namespace + coroutines dep |
| `android/src/main/AndroidManifest.xml` | READ_MEDIA_AUDIO permissions |
| `pubspec.yaml` | Android platform registered |

## Deleted Files

| File |
|------|
| `android/src/main/kotlin/com/example/flutter_gapless_loop/FlutterGaplessLoopPlugin.kt` |
| `android/src/test/kotlin/com/example/flutter_gapless_loop/FlutterGaplessLoopPluginTest.kt` |
