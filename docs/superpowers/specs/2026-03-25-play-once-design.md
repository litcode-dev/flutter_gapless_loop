# Play-Once / Loop Toggle — Design Spec

**Date:** 2026-03-25
**Status:** Approved

## Summary

Add a `loop` parameter to `LoopAudioPlayer.play()` (default `true`) so callers can choose between gapless looping (existing behaviour) and one-shot playback. When one-shot completes, `stateStream` emits `PlayerState.stopped`. Plays exactly one full pass through the audio (or loop region if one is set).

---

## Dart API

**File:** `lib/src/loop_audio_player.dart`

Change signature:

```dart
/// Starts playback.
///
/// Pass [loop] = false to play through exactly once; [stateStream] emits
/// [PlayerState.stopped] when the audio reaches the end naturally.
/// Defaults to [loop] = true (gapless looping) for backwards compatibility.
Future<void> play({bool loop = true}) async {
  _checkNotDisposed();
  await _channel.invokeMethod<void>('play', {
    'playerId': _playerId,
    'loop': loop,
  });
}
```

No other Dart changes. `resume()`, `pause()`, `stop()`, and `seek()` are unaffected. The `loop` flag is owned by the native engine after `play()` is called and persists across pause/resume automatically.

---

## iOS / macOS Swift

**File:** `darwin/Sources/flutter_gapless_loop/LoopAudioEngine.swift`

- Add `private var _loop = true` to `LoopAudioEngine`.
- Change `play()` to `play(loop: Bool = true)`, setting `_loop = loop` at the start.

**Modes A & B (no crossfade):**

```swift
let options: AVAudioPlayerNodeBufferOptions = _loop ? .loops : []
let completion: AVAudioPlayerNodeCompletionHandler? = _loop ? nil : { [weak self] _ in
    self?.audioQueue.async { self?.handlePlaybackComplete() }
}
nodeA.scheduleBuffer(buf, at: nil, options: options, completionHandler: completion)
```

**Modes C & D (crossfade):** `_loop` must be checked **inside `scheduleForCurrentMode()`** (single point of truth), not only at the `play()` call site. When `!_loop`, skip crossfade scheduling entirely — schedule `nodeA` once with `options: []` and the stop completion handler above. This ensures the `setLoopRegion()` and `setCrossfadeDuration()` paths that call `scheduleForCurrentMode()` while playing also respect the flag and do not restart the recursive `scheduleNodeBCrossfade` chain.

Additionally, `scheduleNodeBCrossfade` itself uses a recursive completion-handler dispatch pattern. If a previous looping session left a pending `scheduleNodeBCrossfade` callback in flight on `audioQueue` when `play(loop: false)` is called, that callback could fire and attempt to re-schedule crossfade on the new one-shot session. Guard against this by having `scheduleNodeBCrossfade` check `_loop` at the top of its body and return immediately if `!_loop`. This ensures the recursive chain self-terminates even if an in-flight callback fires after the flag changes.

**Seek path:** the existing "remaining one-shot → re-arm loop" pattern becomes "remaining one-shot → re-arm loop only if `_loop`". When `!_loop`:
- Schedule only the remaining one-shot buffer (from seek position to end) with `options: []`.
- Attach the stop completion handler to the remaining buffer.
- Do **not** schedule the full loop buffer afterwards.

In the fallback branch of `seek()` (where `extractSubBuffer` fails and `scheduleForCurrentMode()` is called directly), no special handling is needed — because `_loop` is checked inside `scheduleForCurrentMode()` (per the Modes C/D rule above), this path is automatically covered.

**`handlePlaybackComplete()`:** transitions state to `.stopped`, calls `onStateChange?(.stopped)`. No read-position reset is needed on iOS because `play()` always re-schedules from the buffer start.

**File:** `darwin/Sources/flutter_gapless_loop/FlutterGaplessLoopPlugin.swift`

Read `loop` bool from the method call args dict (default `true` if absent) and pass to `engine.play(loop:)`.

---

## Android Kotlin

**File:** `android/src/main/kotlin/com/fluttergaplessloop/LoopAudioEngine.kt`

- Add `@Volatile private var isLooping = true`.
- Change `play()` to `play(loop: Boolean = true)`, setting `isLooping = loop` before starting the write thread.

**Write thread wrap point:**

```kotlin
if (readPos >= totalFrames) {
    if (isLooping) readPos = loopStart
    else {
        stopRequested = true  // prevent outer while loop from re-iterating
        handlePlaybackComplete()
        break
    }
}
```

Setting `stopRequested = true` before `break` is necessary because the write thread's outer loop is `while (!stopRequested)`. Without it, the thread could re-enter the loop body after `break` exits the inner branch.

**`handlePlaybackComplete()`** (called from the write thread, before thread exits):

1. Capture a local reference: `val track = audioTrack` — `audioTrack` is not `@Volatile` and could be reassigned by a concurrent `loadFile` on the main thread; operating on the captured reference is safe.
2. Call `track?.pause()` then `track?.flush()` to halt the hardware renderer immediately and prevent it draining remaining buffered audio past the intended stop point.
3. Reset `currentFrameAtomic.set(loopStartFrame.toLong())` so `currentTime` returns to the start position (matching the behaviour of `stop()`).
4. Dispatch `EngineState.STOPPED` callback via `withContext(Dispatchers.Main)`.

This mirrors the teardown sequence in the existing `stop()` implementation.

**File:** `android/src/main/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPlugin.kt`

Read `loop` from method call args (default `true` if absent) and pass to `engine.play(loop)`.

---

## Windows C++

**Files:** `windows/loop_audio_engine.h` / `windows/loop_audio_engine.cpp`

- Add `bool loop_` member to `LoopAudioEngine`.
- Change `Play()` to `Play(bool loop)`, storing `loop_ = loop`.

**New `PlaybackVoiceCallback`:** `voiceA_` currently has no `IXAudio2VoiceCallback`. Create a new inner class and declare it as a **value member** (`PlaybackVoiceCallback playbackCallback_`) in the `LoopAudioEngine` header — not a heap pointer. This ensures its address is stable for the lifetime of the engine (required by XAudio2), and avoids the use-after-free risk that would arise if it were heap-allocated and deleted in `TeardownXAudio2` while the voice is still active. Do not follow the `xfadeCallback_` heap-pointer pattern for this callback.

```cpp
class PlaybackVoiceCallback : public IXAudio2VoiceCallback {
public:
    std::function<void()> onComplete;
    void OnBufferEnd(void* pBufferContext) override {
        if (onComplete) onComplete();
    }
    // All other IXAudio2VoiceCallback methods are no-ops.
    void OnStreamEnd() override {}
    void OnVoiceProcessingPassStart(UINT32) override {}
    void OnVoiceProcessingPassEnd() override {}
    void OnBufferStart(void*) override {}
    void OnLoopEnd(void*) override {}
    void OnVoiceError(void*, HRESULT) override {}
};
```

Register `playbackCallback_` on `voiceA_` in `InitXAudio2()`:

```cpp
hr = xaudio2_->CreateSourceVoice(&voiceA_, &wfx, 0,
    XAUDIO2_MAX_FREQ_RATIO, &playbackCallback_);
```

Set the callback in `Play(bool loop)`:

```cpp
playbackCallback_.onComplete = loop_ ? nullptr : [this]() {
    PostPlaybackComplete();
};
```

**XAudio2 buffer submission (normal play):**

```cpp
buffer.LoopCount  = loop_ ? XAUDIO2_LOOP_INFINITE : 0;
buffer.LoopBegin  = loop_ ? loopBegin_  : 0;
buffer.LoopLength = loop_ ? loopLength_ : 0;
```

**Seek path:** when `!loop_`:
- Submit only buf1 (the remaining frames from seek position to end) with `LoopCount = 0`.
- Do **not** submit buf2 (the full loop re-arm). `OnBufferEnd` will fire when buf1 completes, calling `PostPlaybackComplete()`.

**`PostPlaybackComplete()`:** uses the existing `PostMessage` pattern to marshal to the main thread and fire the `stopped` state event.

**File:** `windows/flutter_gapless_loop_plugin.cpp`

Read `loop` from the `EncodableMap` args (default `true` if absent) and pass to `engine->Play(loop)`.

---

## Behaviour Matrix

| Scenario | `loop = true` | `loop = false` |
|---|---|---|
| Reaches end of file | Wraps gaplessly | Transitions to `stopped` |
| Crossfade set | Equal-power crossfade at loop boundary | Crossfade ignored; one-shot scheduled without crossfade |
| Loop region set | Loops within region | Plays region once (from `loopStart` to `loopEnd`), then `stopped` |
| `pause()` then `resume()` | Continues looping | Continues one-shot from paused position |
| `seek()` then plays to end | Loops | Transitions to `stopped` at end |
| `play(loop: false)` with loop region + prior `seek()` | N/A | `play()` resets position to `loopStart`; prior `seek()` is overwritten |

> **Note:** With a loop region active, `play(loop: false)` always starts from `loopStart` and plays to `loopEnd`. A prior `seek()` call is overridden by `play()`'s position reset on both iOS and Android (existing behaviour).

---

## Error Handling

No new error cases. The `loop` param is a bool with a default; a missing or null value from the channel is treated as `true` (loop) on the native side for safety.

---

## Testing

- Dart: existing `play()` call sites compile without changes (default param).
- Android unit tests: add a `PlayOnceBehaviourTest` case to `FlutterGaplessLoopPluginTest.kt` that exercises the write-thread branch — verify `handlePlaybackComplete()` calls `pause()`, `flush()`, resets `currentFrameAtomic`, and dispatches `STOPPED`.
- Manual: verify `stateStream` emits `stopped` after one-shot on iOS, Android, macOS, and Windows.
- Manual: verify seek + `play(loop: false)` stops at the natural end on all platforms.
