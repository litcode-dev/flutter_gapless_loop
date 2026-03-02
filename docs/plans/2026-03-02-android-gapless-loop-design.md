# Android Gapless Loop — Design Document
**Date:** 2026-03-02
**Author:** Claude
**Status:** Approved

---

## Goal

Implement the Android/Kotlin counterpart to the existing iOS/AVAudioEngine Flutter plugin
`flutter_gapless_loop`. The Android layer must be API-compatible with the existing Dart public API
(`LoopAudioPlayer`, `PlayerState`) and produce identical gapless looping behaviour.

---

## Architecture Decision: AudioTrack WRITE_FLOAT MODE_STREAM

**Chosen:** AudioTrack `MODE_STREAM` with a dedicated high-priority write thread.
**Rejected:** AudioTrack MODE_STATIC (`setLoopPoints()`) — 2 MB buffer limit disqualifies it for 50 MB files.
**Rejected:** Oboe (C++/JNI) — optimal for real-time input latency, not required for pure playback;
adds NDK build complexity incompatible with a pub.dev plugin.

AudioTrack `WRITE_FLOAT` + write thread is the direct analog of `AVAudioPlayerNode.scheduleBuffer(.loops)`:
the hardware renderer sees an uninterrupted stream of PCM data while the write thread wraps
the read pointer at the loop boundary.

---

## File Structure

```
android/src/main/kotlin/com/fluttergaplessloop/
  LoopAudioEngine.kt          — core engine, write thread, 4-mode state machine
  CrossfadeEngine.kt          — equal-power crossfade ramp (pre-computed)
  AudioFileLoader.kt          — MediaExtractor + MediaCodec → FloatArray decoder
  AudioSessionManager.kt      — AudioFocus, AudioAttributes, BECOMING_NOISY
  FlutterGaplessLoopPlugin.kt — method channel + event channel bridge
  LoopEngineError.kt          — sealed error hierarchy
android/build.gradle.kts      — Kotlin DSL, Kotlin 2.2.20, compileSdk 36, minSdk 24, Java 17
android/src/main/AndroidManifest.xml — READ_MEDIA_AUDIO + READ_EXTERNAL_STORAGE permissions
pubspec.yaml                  — android platform entry added
```

No `CMakeLists.txt` — Oboe is not used.

---

## Threading Model

| Thread | Responsibility |
|--------|----------------|
| Main thread | Flutter method channel calls; EventSink dispatch |
| IO coroutine (`Dispatchers.IO`) | MediaExtractor + MediaCodec decode |
| Write thread (raw `Thread`) | `AudioTrack.write()` + loop wrap-around (`THREAD_PRIORITY_URGENT_AUDIO`) |
| Main coroutine (`Dispatchers.Main`) | State-change callbacks → Dart EventSink |

Rules:
- `AudioTrack.write()` is **never** called from the main thread.
- Flutter `result()` and `EventSink` calls are **always** dispatched to main.
- The write thread is the only raw `Thread` — all other async is coroutines.
- `@Volatile` on every flag shared between threads (`stopRequested`, `pauseRequested`, `currentFrame`).
- Pause suspends the write thread via `Semaphore(0)` — no `Thread.sleep()`.

---

## Playback Mode Auto-Selection (mirrors iOS)

| Mode | Condition | Wrap point |
|------|-----------|------------|
| A (default) | full file, crossfade = 0 | `totalFrames` |
| B | loop region set, crossfade = 0 | `loopEndFrame` |
| C | full file, crossfade > 0 | `totalFrames` with crossfade block |
| D | loop region + crossfade > 0 | `loopEndFrame` with crossfade block |

Mode is derived from two flags: `hasLoopRegion` and `crossfadeDuration > 0`. Write thread
re-evaluates on every wrap so mode transitions are lock-free.

---

## Click Prevention

Applied **once** at load time in `AudioFileLoader.kt` — never during playback:

```
fadeFrames = (sampleRate * 0.005).toInt()   // 5 ms
fade-in:  pcm[i] *= i / fadeFrames           (first fadeFrames frames)
fade-out: pcm[totalFrames-1-i] *= i / fadeFrames  (last fadeFrames frames)
```

---

## Zero-Crossing Detection

Applied at `setLoopRegion()` time. Scans a 10 ms window at each boundary for the nearest
zero-crossing (sign change between consecutive samples, averaged across channels).
Falls back to the original boundary + micro-fade if no crossing found within the window.

---

## Crossfade Block

Pre-computed by `CrossfadeEngine` at `setCrossfadeDuration()` time:

```
fadeOut[i] = cos(i / N * π/2)
fadeIn[i]  = sin(i / N * π/2)
block[i]   = tail[i]*fadeOut[i] + head[i]*fadeIn[i]
```

The write thread replaces the wrap-boundary frames with this pre-computed block.
Block is only recomputed when configuration changes, never on every loop.

---

## Audio Session Management

- `AudioAttributes`: `USAGE_MEDIA` + `CONTENT_TYPE_MUSIC`
- AudioFocus: `AudioFocusRequest` (API 26+) with API 21 fallback
- `AUDIOFOCUS_LOSS` → stop, send `stateChange` to Dart
- `AUDIOFOCUS_LOSS_TRANSIENT` → pause, send `stateChange`
- `AUDIOFOCUS_LOSS_TRANSIENT_CAN_DUCK` → volume 20%
- `AUDIOFOCUS_GAIN` → restore volume, resume if was playing
- `ACTION_AUDIO_BECOMING_NOISY` → pause, send `routeChange "headphonesUnplugged"` to Dart
- All receivers unregistered in `dispose()` — no leaks

---

## pubspec.yaml Change

Add to `flutter.plugin.platforms`:
```yaml
android:
  package: com.fluttergaplessloop
  pluginClass: FlutterGaplessLoopPlugin
```

---

## iOS Concept Mapping

| iOS | Android |
|-----|---------|
| `AVAudioEngine` | `AudioTrack` + write thread |
| `AVAudioPlayerNode` | Write thread loop logic |
| `AVAudioPCMBuffer` | `FloatArray` (decoded PCM) |
| `scheduleBuffer(.loops)` | Write thread wrap-around |
| `AVAudioSession.category = .playback` | `AudioAttributes.USAGE_MEDIA` |
| `AVAudioSession` interruption | `AudioFocus` loss callback |
| Route change notification | `ACTION_AUDIO_BECOMING_NOISY` |
| `AVAudioMixerNode` | Sample blending in `CrossfadeEngine` |
| `os_log Logger` | `android.util.Log` |
| `DispatchQueue` serial | Coroutine single-thread dispatcher |
| `[weak self]` | `WeakReference` / structured coroutine scope |
