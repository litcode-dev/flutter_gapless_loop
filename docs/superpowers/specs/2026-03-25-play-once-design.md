# Play-Once / Loop Toggle — Design Spec

**Date:** 2026-03-25
**Status:** Approved

## Summary

Add a `loop` parameter to `LoopAudioPlayer.play()` (default `true`) so callers can choose between gapless looping (existing behaviour) and one-shot playback. When one-shot completes, `stateStream` emits `PlayerState.stopped`.

---

## Dart API

**File:** `lib/src/loop_audio_player.dart`

Change signature:

```dart
/// Starts playback.
///
/// Pass [loop] = false to play through once; [stateStream] emits
/// [PlayerState.stopped] when the audio reaches the end.
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

**Modes C & D (crossfade):** when `!_loop`, skip crossfade scheduling entirely — schedule `nodeA` once with `options: []` and the stop completion handler. Crossfade only applies at loop boundaries; one-shot ignores it.

**Seek path:** the existing "remaining one-shot → re-arm loop" pattern becomes "remaining one-shot → re-arm loop only if `_loop`". When `!_loop`, only the remaining one-shot is scheduled (with the stop completion handler).

**`handlePlaybackComplete()`:** transitions state to `.stopped`, calls `onStateChange?(.stopped)`.

**File:** `darwin/Sources/flutter_gapless_loop/FlutterGaplessLoopPlugin.swift`

Read `loop` bool from the method call args dict and pass it to `engine.play(loop:)`.

---

## Android Kotlin

**File:** `android/src/main/kotlin/com/fluttergaplessloop/LoopAudioEngine.kt`

- Add `@Volatile private var isLooping = true`.
- Change `play()` to `play(loop: Boolean = true)`, setting `isLooping = loop` before starting the write thread.

**Write thread wrap point:**

```kotlin
if (readPos >= totalFrames) {
    if (isLooping) readPos = loopStart
    else { handlePlaybackComplete(); break }
}
```

**`handlePlaybackComplete()`:** dispatches `EngineState.STOPPED` callback on `Dispatchers.Main`.

**File:** `android/src/main/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPlugin.kt`

Read `loop` from method call args and pass to `engine.play(loop)`.

---

## Windows C++

**Files:** `windows/loop_audio_engine.h` / `windows/loop_audio_engine.cpp`

- Add `bool loop_` member to `LoopAudioEngine`.
- Change `Play()` to `Play(bool loop)`, storing `loop_ = loop`.

**XAudio2 buffer submission:**

```cpp
buffer.LoopCount  = loop_ ? XAUDIO2_LOOP_INFINITE : 0;
buffer.LoopBegin  = loop_ ? loopBegin_  : 0;
buffer.LoopLength = loop_ ? loopLength_ : 0;
```

**Completion callback** on the existing `IXAudio2VoiceCallback`:

```cpp
void OnBufferEnd(void* pBufferContext) override {
    if (!loop_) PostPlaybackComplete();
}
```

`PostPlaybackComplete()` uses the existing `PostMessage` pattern to marshal to the main thread and fire the `stopped` state event.

**File:** `windows/flutter_gapless_loop_plugin.cpp`

Read `loop` from the `EncodableMap` args and pass to `engine->Play(loop)`.

---

## Behaviour Matrix

| Scenario | `loop = true` | `loop = false` |
|---|---|---|
| Reaches end of file | Wraps gaplessly | Transitions to `stopped` |
| Crossfade set | Equal-power crossfade at loop boundary | Crossfade ignored; one-shot |
| Loop region set | Loops within region | Plays region once, then `stopped` |
| `pause()` then `resume()` | Continues looping | Continues one-shot from paused pos |
| `seek()` then plays to end | Loops | Stopped at end |

---

## Error Handling

No new error cases. The `loop` param is a bool with a default; missing/null from the channel is treated as `true` (loop) on the native side for safety.

---

## Testing

- Dart: existing `play()` call sites compile without changes (default param).
- Android unit tests: add a `PlayOnceBehaviourTest` case to `FlutterGaplessLoopPluginTest.kt` exercising the write-thread branch.
- Manual: verify `stateStream` emits `stopped` after one-shot on iOS, Android, macOS, Windows.
