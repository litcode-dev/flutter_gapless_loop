# Multi-Instance Player Support — Design Doc

**Date:** 2026-03-05
**Status:** Approved
**Scope:** `LoopAudioPlayer` and `MetronomePlayer`

---

## Goal

Allow multiple concurrent `LoopAudioPlayer` and `MetronomePlayer` instances without cross-talk. Each instance runs its own independent native engine, streams, and lifecycle.

## Approach: Player ID in shared channels (Approach A)

Each Dart instance generates a unique `_playerId` string at construction using a static counter. Every method call includes that ID. Every native event is tagged with it. The shared broadcast stream on the Dart side is filtered per-instance so players only see their own events.

Channel names are unchanged — no podspec, manifest, or plugin registration changes required.

---

## Architecture

### Player ID generation

```dart
// LoopAudioPlayer
static int _nextId = 0;
final String _playerId = 'loop_${_nextId++}';

// MetronomePlayer
static int _nextId = 0;
final String _playerId = 'metro_${_nextId++}';
```

### Dart → Native

Every method call wraps its args with `playerId`:

```dart
await _channel.invokeMethod('play', {'playerId': _playerId});
await _channel.invokeMethod('setBpm', {'playerId': _playerId, 'bpm': 120.0});
await _channel.invokeMethod('start', {
  'playerId': _playerId,
  'bpm': bpm,
  'beatsPerBar': beatsPerBar,
  'click': click,
  'accent': accent,
  'extension': extension,
});
```

### Native → Dart

Every event emitted on the event channel includes `playerId`:

```
{'playerId': 'loop_0', 'type': 'stateChange', 'state': 'playing'}
{'playerId': 'loop_1', 'type': 'bpmDetected', 'bpm': 124.0}
{'playerId': 'metro_0', 'type': 'beatTick', 'beat': 0}
```

### Dart event filtering

```dart
_events = _eventChannel
    .receiveBroadcastStream()
    .cast<Map<Object?, Object?>>()
    .where((e) => e['playerId'] == _playerId);
```

### Native registries

**iOS (`FlutterGaplessLoopPlugin.swift`):**
```swift
private var engines:    [String: LoopAudioEngine]    = [:]
private var metronomes: [String: MetronomeEngine]    = [:]
```

**Android (`FlutterGaplessLoopPlugin.kt`):**
```kotlin
private val engines    = HashMap<String, LoopAudioEngine>()
private val metronomes = HashMap<String, MetronomeEngine>()
```

Engines are created lazily on first method call for a given `playerId`. On `dispose`, the engine is stopped, released, and removed from the map.

### `getOrCreate*` helpers

```swift
// iOS
private func getOrCreateEngine(for playerId: String) -> LoopAudioEngine {
    if let eng = engines[playerId] { return eng }
    let eng = LoopAudioEngine()
    wireEngineCallbacks(eng, playerId: playerId)
    engines[playerId] = eng
    return eng
}

private func getOrCreateMetronomeEngine(for playerId: String) -> MetronomeEngine {
    if let eng = metronomes[playerId] { return eng }
    let eng = MetronomeEngine()
    eng.onBeatTick = { [weak self] beat in
        self?.metronomeStreamHandler.eventSink?([
            "playerId": playerId, "type": "beatTick", "beat": beat
        ])
    }
    eng.onError = { [weak self] msg in
        self?.metronomeStreamHandler.eventSink?([
            "playerId": playerId, "type": "error", "message": msg
        ])
    }
    metronomes[playerId] = eng
    return eng
}
```

```kotlin
// Android
private fun getOrCreateEngine(playerId: String): LoopAudioEngine {
    return engines.getOrPut(playerId) {
        val eng = LoopAudioEngine(ctx)
        wireEngineCallbacks(eng, playerId)
        eng
    }
}

private fun getOrCreateMetronomeEngine(playerId: String): MetronomeEngine {
    return metronomes.getOrPut(playerId) {
        MetronomeEngine(
            onBeatTick = { beat ->
                mainHandler.post {
                    metronomeEventSink?.success(
                        mapOf("playerId" to playerId, "type" to "beatTick", "beat" to beat)
                    )
                }
            },
            onError = { msg ->
                mainHandler.post {
                    metronomeEventSink?.success(
                        mapOf("playerId" to playerId, "type" to "error", "message" to msg)
                    )
                }
            }
        )
    }
}
```

### Dispose

```swift
// iOS — in handleMetronomeCall / handle(_:result:)
case "dispose":
    guard let pid = args?["playerId"] as? String else { ... }
    engines[pid]?.dispose()
    engines.removeValue(forKey: pid)
    result(nil)
```

```kotlin
// Android — in onMethodCall / handleMetronomeCall
"dispose" -> {
    val pid = call.argument<String>("playerId")
        ?: return result.error("INVALID_ARGS", "'playerId' required", null)
    engines[pid]?.dispose()
    engines.remove(pid)
    result.success(null)
}
```

### Cleanup on engine detach

```swift
// iOS
override func onDetachedFromEngine(...) {
    engines.values.forEach { $0.dispose() }
    engines.removeAll()
    metronomes.values.forEach { $0.dispose() }
    metronomes.removeAll()
}
```

```kotlin
// Android
override fun onDetachedFromEngine(...) {
    engines.values.forEach { it.dispose() }
    engines.clear()
    metronomes.values.forEach { it.dispose() }
    metronomes.clear()
}
```

---

## Public API

**Completely unchanged.** Users create instances as today:

```dart
final player1 = LoopAudioPlayer();
final player2 = LoopAudioPlayer();
final metro1  = MetronomePlayer();
final metro2  = MetronomePlayer();

await player1.load('assets/bass.wav');
await player2.load('assets/drums.wav');
await player1.play();
await player2.play();

await metro1.start(bpm: 120, beatsPerBar: 4, click: click, accent: accent);
await metro2.start(bpm: 90,  beatsPerBar: 3, click: click, accent: accent);

// Streams are fully isolated
player1.stateStream.listen((s) => ...);  // only player1 events
player2.bpmStream.listen((r)  => ...);  // only player2 events
metro1.beatStream.listen((b)  => ...);
metro2.beatStream.listen((b)  => ...);

// Independent lifecycle
await player1.dispose();  // player2 unaffected
await metro1.dispose();   // metro2 unaffected
```

---

## Error Handling

| Scenario | Behaviour |
|----------|-----------|
| Method call after `dispose` | `StateError` from Dart guard (unchanged) |
| `playerId` missing from native call | Native returns `INVALID_ARGS` — defensive only |
| `dispose` for unknown `playerId` | Native no-ops silently |
| Engine creation failure | `PlatformException` propagated to Dart (unchanged) |

---

## Testing

### New Dart tests (`test/multi_instance_test.dart`)

- Two `LoopAudioPlayer` instances get different `_playerId` values
- Each player's method calls carry its own `playerId`
- Events for player A are invisible to player B's streams (cross-talk isolation)
- `dispose` of player A does not affect player B
- Four equivalent tests for `MetronomePlayer`

### Existing tests

- All existing Dart tests updated: mock handler checks now assert `playerId` is present in call arguments
- Android unit tests (`buildBarBuffer`, BPM detector, etc.) — unaffected, pure functions
- Build verification: `flutter test`, Android unit tests, `flutter analyze`, `flutter build ios --no-codesign`

---

## Files Changed

| File | Change |
|------|--------|
| `lib/src/loop_audio_player.dart` | Add `_playerId`; inject into every method call; filter `_events` by `playerId` |
| `lib/src/metronome_player.dart` | Same |
| `ios/Classes/FlutterGaplessLoopPlugin.swift` | `engine` → `engines[playerId]`; tag all events with `playerId`; update detach cleanup |
| `android/.../FlutterGaplessLoopPlugin.kt` | Same |
| `test/loop_audio_player_test.dart` | Update existing mocks to expect `playerId` in args |
| `test/metronome_player_test.dart` | Same |
| `test/multi_instance_test.dart` | New — cross-talk isolation tests |
| `test/load_from_url_bytes_test.dart` | Update mocks to expect `playerId` |
| `README.md` | Remove single-instance warning; add multi-instance example |
