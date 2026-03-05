# Multi-Instance Player Support — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Allow multiple concurrent `LoopAudioPlayer` and `MetronomePlayer` instances without cross-talk, using a player ID injected into every method call and event.

**Architecture:** Each Dart instance generates a unique `_playerId` at construction via a static counter. The shared event channel broadcast stream is filtered per-instance by `playerId`. Native side holds a `[String: Engine]` map and routes every call by the `playerId` argument.

**Tech Stack:** Dart (Flutter method/event channels), Swift (iOS AVFoundation), Kotlin (Android AudioTrack)

---

### Task 1: Update `LoopAudioPlayer` — player ID + shared stream

**Files:**
- Modify: `lib/src/loop_audio_player.dart`

**Step 1: Write the failing test**

Add a new file `test/multi_instance_test.dart`:

```dart
import 'dart:typed_data';
import 'package:flutter/services.dart';
import 'package:flutter_gapless_loop/flutter_gapless_loop.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('flutter_gapless_loop'),
      (call) async { calls.add(call); return null; },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('flutter_gapless_loop'), null);
  });

  group('LoopAudioPlayer multi-instance', () {
    test('two instances get different playerIds', () {
      final p1 = LoopAudioPlayer();
      final p2 = LoopAudioPlayer();
      expect(p1.playerId, isNot(equals(p2.playerId)));
    });

    test('play() includes playerId in args', () async {
      final p1 = LoopAudioPlayer();
      await p1.play();
      expect(calls.first.arguments['playerId'], equals(p1.playerId));
    });

    test('loadFromFile() includes playerId in args', () async {
      final p1 = LoopAudioPlayer();
      await p1.loadFromFile('/tmp/test.wav');
      expect(calls.first.arguments['playerId'], equals(p1.playerId));
    });

    test('dispose() includes playerId in args', () async {
      final p1 = LoopAudioPlayer();
      await p1.dispose();
      expect(calls.first.arguments['playerId'], equals(p1.playerId));
    });

    test('two instances send different playerIds', () async {
      final p1 = LoopAudioPlayer();
      final p2 = LoopAudioPlayer();
      await p1.play();
      await p2.play();
      final id1 = calls[0].arguments['playerId'] as String;
      final id2 = calls[1].arguments['playerId'] as String;
      expect(id1, isNot(equals(id2)));
    });
  });
}
```

**Step 2: Run the test to verify it fails**

```
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop
flutter test test/multi_instance_test.dart
```

Expected: FAIL — `p1.playerId` getter doesn't exist, `play()` args don't include `playerId`.

**Step 3: Update `lib/src/loop_audio_player.dart`**

Changes:
1. Add static counter + `_playerId` field
2. Expose `playerId` getter (for tests)
3. Change `_events` to use a static shared stream filtered by `_playerId`
4. Inject `playerId` into every `_channel.invokeMethod` call

Replace the top of the class (lines 31–44) and all `invokeMethod` calls:

```dart
class LoopAudioPlayer {
  static const _channel = MethodChannel('flutter_gapless_loop');
  static const _eventChannel = EventChannel('flutter_gapless_loop/events');

  // Shared broadcast stream — one subscription for all instances.
  static final Stream<Map<Object?, Object?>> _sharedEvents = _eventChannel
      .receiveBroadcastStream()
      .cast<Map<Object?, Object?>>();

  static int _nextId = 0;
  final String _playerId = 'loop_${_nextId++}';

  /// Exposes the player ID for testing.
  String get playerId => _playerId;

  late final Stream<Map<Object?, Object?>> _events;

  bool _isDisposed = false;

  LoopAudioPlayer() {
    _events = _sharedEvents.where((e) => e['playerId'] == _playerId);
  }
```

Update every `invokeMethod` to include `playerId`. Full list of changes:

```dart
// load
await _channel.invokeMethod<void>('loadAsset', {'playerId': _playerId, 'assetKey': assetPath});

// loadFromFile
await _channel.invokeMethod<void>('load', {'playerId': _playerId, 'path': filePath});

// play
await _channel.invokeMethod<void>('play', {'playerId': _playerId});

// pause
await _channel.invokeMethod<void>('pause', {'playerId': _playerId});

// resume
await _channel.invokeMethod<void>('resume', {'playerId': _playerId});

// stop
await _channel.invokeMethod<void>('stop', {'playerId': _playerId});

// setLoopRegion
await _channel.invokeMethod<void>('setLoopRegion', {'playerId': _playerId, 'start': start, 'end': end});

// setCrossfadeDuration
await _channel.invokeMethod<void>('setCrossfadeDuration', {'playerId': _playerId, 'duration': seconds});

// setVolume
await _channel.invokeMethod<void>('setVolume', {'playerId': _playerId, 'volume': volume});

// setPan
await _channel.invokeMethod<void>('setPan', {'playerId': _playerId, 'pan': pan.clamp(-1.0, 1.0)});

// setPlaybackRate
await _channel.invokeMethod<void>('setPlaybackRate', {'playerId': _playerId, 'rate': rate.clamp(0.25, 4.0)});

// seek
await _channel.invokeMethod<void>('seek', {'playerId': _playerId, 'position': seconds});

// getDuration
final secs = await _channel.invokeMethod<double>('getDuration', {'playerId': _playerId}) ?? 0.0;

// getCurrentPosition
return await _channel.invokeMethod<double>('getCurrentPosition', {'playerId': _playerId}) ?? 0.0;

// dispose
await _channel.invokeMethod<void>('dispose', {'playerId': _playerId});
```

Also remove the old `_events` field and its init in the constructor (replaced by the static version above).

**Step 4: Run the new test to verify it passes**

```
flutter test test/multi_instance_test.dart
```

Expected: PASS (5 tests).

**Step 5: Run the full existing test suite to verify no regressions**

```
flutter test test/flutter_gapless_loop_test.dart test/load_from_url_bytes_test.dart
```

Expected: All tests in `flutter_gapless_loop_test.dart` pass (they don't touch method channel args for play/load calls directly, only BpmResult parsing).

Note: `load_from_url_bytes_test.dart` checks `call.arguments['path']` — this still works because `invokeMethod` args are a Map and `path` is still present.

**Step 6: Commit**

```bash
git add lib/src/loop_audio_player.dart test/multi_instance_test.dart
git commit -m "feat: add playerId to LoopAudioPlayer — multi-instance Dart layer"
```

---

### Task 2: Update `MetronomePlayer` — player ID + shared stream

**Files:**
- Modify: `lib/src/metronome_player.dart`
- Modify: `test/multi_instance_test.dart`

**Step 1: Add MetronomePlayer tests to `test/multi_instance_test.dart`**

Append a new `group` after the LoopAudioPlayer group. Also add the metronome mock handler to `setUp`/`tearDown`:

```dart
// In setUp, also mock the metronome channel:
TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
    .setMockMethodCallHandler(
  const MethodChannel('flutter_gapless_loop/metronome'),
  (call) async { metroCalls.add(call); return null; },
);
// Add: late List<MethodCall> metroCalls; to the top

// In tearDown, also clear the metronome channel:
TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
    .setMockMethodCallHandler(
  const MethodChannel('flutter_gapless_loop/metronome'), null);
```

New group:
```dart
group('MetronomePlayer multi-instance', () {
  final stubBytes = Uint8List(4);

  test('two MetronomePlayer instances get different playerIds', () {
    final m1 = MetronomePlayer();
    final m2 = MetronomePlayer();
    expect(m1.playerId, isNot(equals(m2.playerId)));
  });

  test('start() includes playerId in args', () async {
    final m1 = MetronomePlayer();
    await m1.start(bpm: 120, beatsPerBar: 4, click: stubBytes, accent: stubBytes);
    expect(metroCalls.first.arguments['playerId'], equals(m1.playerId));
  });

  test('stop() includes playerId in args', () async {
    final m1 = MetronomePlayer();
    await m1.stop();
    expect(metroCalls.first.arguments['playerId'], equals(m1.playerId));
  });

  test('dispose() includes playerId in args', () async {
    final m1 = MetronomePlayer();
    await m1.dispose();
    expect(metroCalls.first.arguments['playerId'], equals(m1.playerId));
  });

  test('two MetronomePlayer instances send different playerIds', () async {
    final m1 = MetronomePlayer();
    final m2 = MetronomePlayer();
    await m1.stop();
    await m2.stop();
    final id1 = metroCalls[0].arguments['playerId'] as String;
    final id2 = metroCalls[1].arguments['playerId'] as String;
    expect(id1, isNot(equals(id2)));
  });
});
```

**Step 2: Run the test to verify it fails**

```
flutter test test/multi_instance_test.dart
```

Expected: FAIL — `m1.playerId` doesn't exist, args don't include `playerId`.

**Step 3: Update `lib/src/metronome_player.dart`**

Same pattern as LoopAudioPlayer:

```dart
class MetronomePlayer {
  static const _channel = MethodChannel('flutter_gapless_loop/metronome');
  static const _eventChannel = EventChannel('flutter_gapless_loop/metronome/events');

  static final Stream<Map<Object?, Object?>> _sharedEvents = _eventChannel
      .receiveBroadcastStream()
      .cast<Map<Object?, Object?>>();

  static int _nextId = 0;
  final String _playerId = 'metro_${_nextId++}';

  /// Exposes the player ID for testing.
  String get playerId => _playerId;

  late final Stream<Map<Object?, Object?>> _events;
  bool _isDisposed = false;

  MetronomePlayer() {
    _events = _sharedEvents.where((e) => e['playerId'] == _playerId);
  }
```

Update every `invokeMethod` call:

```dart
// start
await _channel.invokeMethod<void>('start', {
  'playerId': _playerId,
  'bpm': bpm,
  'beatsPerBar': beatsPerBar,
  'click': click,
  'accent': accent,
  'extension': extension,
});

// stop
await _channel.invokeMethod<void>('stop', {'playerId': _playerId});

// setBpm
await _channel.invokeMethod<void>('setBpm', {'playerId': _playerId, 'bpm': bpm});

// setBeatsPerBar
await _channel.invokeMethod<void>('setBeatsPerBar', {'playerId': _playerId, 'beatsPerBar': beatsPerBar});

// dispose
await _channel.invokeMethod<void>('dispose', {'playerId': _playerId});
```

**Step 4: Run the tests**

```
flutter test test/multi_instance_test.dart
```

Expected: PASS (10 tests total — 5 LoopAudioPlayer + 5 MetronomePlayer).

**Step 5: Update existing `test/metronome_player_test.dart` to assert `playerId` is present**

The existing tests check `args['bpm']`, `args['beatsPerBar']` etc. They pass without change because extra keys don't break anything. But add an assertion in the `start sends correct method channel payload` test:

```dart
// Add to the existing 'sends correct method channel payload' test:
expect(args.containsKey('playerId'), isTrue);
expect(args['playerId'], startsWith('metro_'));
```

**Step 6: Run all Dart tests**

```
flutter test
```

Expected: All tests pass.

**Step 7: Commit**

```bash
git add lib/src/metronome_player.dart test/multi_instance_test.dart test/metronome_player_test.dart
git commit -m "feat: add playerId to MetronomePlayer — multi-instance Dart layer"
```

---

### Task 3: Update iOS plugin bridge

**Files:**
- Modify: `ios/Classes/FlutterGaplessLoopPlugin.swift`

**Step 1: Replace single-engine properties with dictionaries**

In `FlutterGaplessLoopPlugin`, replace:
```swift
private var engine: LoopAudioEngine?
private var metronomeEngine: MetronomeEngine?
```

With:
```swift
private var engines:    [String: LoopAudioEngine] = [:]
private var metronomes: [String: MetronomeEngine] = [:]
```

**Step 2: Add `getOrCreateEngine(for:)` helper**

Replace the existing `setupEngine()` method and `onListen`/`handle` usage pattern with a `getOrCreate` pattern:

```swift
@discardableResult
private func getOrCreateEngine(for playerId: String) -> LoopAudioEngine {
    if let eng = engines[playerId] { return eng }
    let eng = LoopAudioEngine()
    wireEngineCallbacks(eng, playerId: playerId)
    engines[playerId] = eng
    return eng
}
```

Extract the callback wiring out of `setupEngine()` into a new method `wireEngineCallbacks(_:playerId:)`:

```swift
private func wireEngineCallbacks(_ eng: LoopAudioEngine, playerId: String) {
    eng.onStateChange = { [weak self] state in
        DispatchQueue.main.async {
            self?.eventSink?(["playerId": playerId, "type": "stateChange", "state": state.rawValue])
        }
    }
    eng.onError = { [weak self] error in
        DispatchQueue.main.async {
            self?.eventSink?(["playerId": playerId, "type": "error", "message": error.localizedDescription])
        }
    }
    eng.onRouteChange = { [weak self] reason in
        DispatchQueue.main.async {
            self?.eventSink?(["playerId": playerId, "type": "routeChange", "reason": reason])
        }
    }
    eng.onBpmDetected = { [weak self] bpmResult in
        DispatchQueue.main.async {
            self?.eventSink?([
                "playerId":    playerId,
                "type":        "bpmDetected",
                "bpm":         bpmResult.bpm,
                "confidence":  bpmResult.confidence,
                "beats":       bpmResult.beats,
                "beatsPerBar": bpmResult.beatsPerBar,
                "bars":        bpmResult.bars
            ])
        }
    }
}
```

**Step 3: Update `onListen` and `handle(_:result:)`**

`onListen` no longer creates an engine (engines are created lazily on first method call):

```swift
public func onListen(withArguments arguments: Any?,
                     eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    logger.info("Event channel opened")
    return nil
}
```

In `handle(_:result:)`, extract `playerId` and use `getOrCreateEngine(for:)`:

```swift
public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    guard let pid = args?["playerId"] as? String else {
        DispatchQueue.main.async { result(FlutterError(
            code: "INVALID_ARGS", message: "'playerId' is required", details: nil)) }
        return
    }
    let eng = getOrCreateEngine(for: pid)
    logger.debug("Method call: \(call.method) pid=\(pid)")

    switch call.method {
    // ... all cases unchanged except:
    case "dispose":
        eng.dispose()
        engines.removeValue(forKey: pid)
        DispatchQueue.main.async { result(nil) }
    // ... rest unchanged
    }
}
```

For all non-dispose cases, remove the old `if engine == nil { setupEngine() }` guard — `getOrCreateEngine(for:)` handles it.

**Step 4: Update `getOrCreateMetronomeEngine` to use dictionaries**

Replace:
```swift
@discardableResult
private func getOrCreateMetronomeEngine() -> MetronomeEngine {
    if let eng = metronomeEngine { return eng }
    let eng = MetronomeEngine()
    eng.onBeatTick = { [weak self] beat in
        self?.metronomeStreamHandler.eventSink?(["type": "beatTick", "beat": beat])
    }
    eng.onError = { [weak self] msg in
        self?.metronomeStreamHandler.eventSink?(["type": "error", "message": msg])
    }
    metronomeEngine = eng
    return eng
}
```

With:
```swift
@discardableResult
private func getOrCreateMetronomeEngine(for playerId: String) -> MetronomeEngine {
    if let eng = metronomes[playerId] { return eng }
    let eng = MetronomeEngine()
    eng.onBeatTick = { [weak self] beat in
        self?.metronomeStreamHandler.eventSink?(
            ["playerId": playerId, "type": "beatTick", "beat": beat])
    }
    eng.onError = { [weak self] msg in
        self?.metronomeStreamHandler.eventSink?(
            ["playerId": playerId, "type": "error", "message": msg])
    }
    metronomes[playerId] = eng
    return eng
}
```

**Step 5: Update `handleMetronomeCall` to extract playerId**

```swift
func handleMetronomeCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    guard let pid = args?["playerId"] as? String else {
        result(FlutterError(code: "INVALID_ARGS", message: "'playerId' is required", details: nil))
        return
    }

    switch call.method {
    case "start":
        guard let bpmVal     = args?["bpm"]        as? Double,
              let beatsVal   = args?["beatsPerBar"] as? Int,
              let clickData  = args?["click"]       as? FlutterStandardTypedData,
              let accentData = args?["accent"]      as? FlutterStandardTypedData else {
            result(FlutterError(code: "INVALID_ARGS",
                                message: "start requires bpm, beatsPerBar, click, accent",
                                details: nil))
            return
        }
        let ext = args?["extension"] as? String ?? "wav"
        getOrCreateMetronomeEngine(for: pid).start(
            bpm: bpmVal, beatsPerBar: beatsVal,
            clickData: clickData.data, accentData: accentData.data, fileExtension: ext)
        result(nil)

    case "setBpm":
        guard let bpmVal = args?["bpm"] as? Double else {
            result(FlutterError(code: "INVALID_ARGS", message: "'bpm' required", details: nil))
            return
        }
        metronomes[pid]?.setBpm(bpmVal)
        result(nil)

    case "setBeatsPerBar":
        guard let beatsVal = args?["beatsPerBar"] as? Int else {
            result(FlutterError(code: "INVALID_ARGS", message: "'beatsPerBar' required", details: nil))
            return
        }
        metronomes[pid]?.setBeatsPerBar(beatsVal)
        result(nil)

    case "stop":
        metronomes[pid]?.stop()
        result(nil)

    case "dispose":
        metronomes[pid]?.dispose()
        metronomes.removeValue(forKey: pid)
        result(nil)

    default:
        result(FlutterMethodNotImplemented)
    }
}
```

**Step 6: Update `onDetachedFromEngine` cleanup**

```swift
// Remove old:
//   engine?.dispose(); engine = nil
//   metronomeEngine?.dispose(); metronomeEngine = nil

// Add:
engines.values.forEach { $0.dispose() }
engines.removeAll()
metronomes.values.forEach { $0.dispose() }
metronomes.removeAll()
```

**Step 7: Build iOS to verify**

```
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop/example
flutter build ios --no-codesign
```

Expected: Build succeeds with no errors or warnings.

**Step 8: Commit**

```bash
git add ios/Classes/FlutterGaplessLoopPlugin.swift
git commit -m "feat: iOS plugin — engine registry for multi-instance support"
```

---

### Task 4: Update Android plugin bridge

**Files:**
- Modify: `android/src/main/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPlugin.kt`

**Step 1: Replace single-engine fields with HashMaps**

Replace:
```kotlin
private var engine: LoopAudioEngine? = null
private var metronomeEngine: MetronomeEngine? = null
```

With:
```kotlin
private val engines    = HashMap<String, LoopAudioEngine>()
private val metronomes = HashMap<String, MetronomeEngine>()
```

**Step 2: Update `getOrCreateEngine` to take playerId**

Replace:
```kotlin
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
```

With:
```kotlin
private fun getOrCreateEngine(playerId: String): LoopAudioEngine {
    return engines.getOrPut(playerId) {
        val ctx = pluginBinding?.applicationContext
            ?: throw IllegalStateException("Plugin not attached to an engine")
        val eng = LoopAudioEngine(ctx)
        wireEngineCallbacks(eng, playerId)
        eng
    }
}
```

**Step 3: Update `wireEngineCallbacks` to tag events with playerId**

Replace the signature and all `sendEvent` calls:

```kotlin
private fun wireEngineCallbacks(eng: LoopAudioEngine, playerId: String) {
    eng.onStateChange = { state ->
        sendEvent(mapOf("playerId" to playerId, "type" to "stateChange", "state" to state.rawValue))
    }
    eng.onError = { error ->
        sendEvent(mapOf("playerId" to playerId, "type" to "error", "message" to error.toMessage()))
    }
    eng.onRouteChange = { reason ->
        sendEvent(mapOf("playerId" to playerId, "type" to "routeChange", "reason" to reason))
    }
    eng.onBpmDetected = { bpmResult ->
        sendEvent(mapOf(
            "playerId"    to playerId,
            "type"        to "bpmDetected",
            "bpm"         to bpmResult.bpm,
            "confidence"  to bpmResult.confidence,
            "beats"       to bpmResult.beats,
            "beatsPerBar" to bpmResult.beatsPerBar,
            "bars"        to bpmResult.bars
        ))
    }
}
```

**Step 4: Update `onMethodCall` to extract playerId**

At the top of `onMethodCall`, extract `playerId` and pass it to `getOrCreateEngine`:

```kotlin
override fun onMethodCall(call: MethodCall, result: Result) {
    val playerId = call.argument<String>("playerId")
        ?: return result.error("INVALID_ARGS", "'playerId' is required", null)

    val eng = try {
        getOrCreateEngine(playerId)
    } catch (e: IllegalStateException) {
        return result.error("NOT_ATTACHED", e.message, null)
    }

    when (call.method) {
        // ...
        "dispose" -> {
            eng.dispose()
            engines.remove(playerId)
            result.success(null)
        }
        // all other cases unchanged
    }
}
```

Also update `onListen` — it no longer calls `getOrCreateEngine()` (engines are created lazily on first method call):

```kotlin
override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
    eventSink = events
    Log.i(TAG, "Event channel opened")
}
```

**Step 5: Update `getOrCreateMetronomeEngine` to take playerId**

Replace:
```kotlin
private fun getOrCreateMetronomeEngine(): MetronomeEngine {
    metronomeEngine?.let { return it }
    val eng = MetronomeEngine(
        onBeatTick = { beat ->
            mainHandler.post {
                metronomeEventSink?.success(mapOf("type" to "beatTick", "beat" to beat))
            }
        },
        onError = { msg ->
            mainHandler.post {
                metronomeEventSink?.success(mapOf("type" to "error", "message" to msg))
            }
        }
    )
    metronomeEngine = eng
    return eng
}
```

With:
```kotlin
private fun getOrCreateMetronomeEngine(playerId: String): MetronomeEngine {
    return metronomes.getOrPut(playerId) {
        MetronomeEngine(
            onBeatTick = { beat ->
                mainHandler.post {
                    metronomeEventSink?.success(
                        mapOf("playerId" to playerId, "type" to "beatTick", "beat" to beat))
                }
            },
            onError = { msg ->
                mainHandler.post {
                    metronomeEventSink?.success(
                        mapOf("playerId" to playerId, "type" to "error", "message" to msg))
                }
            }
        )
    }
}
```

**Step 6: Update `handleMetronomeCall` to extract playerId**

Add at the top:
```kotlin
private fun handleMetronomeCall(call: MethodCall, result: Result) {
    val playerId = call.argument<String>("playerId")
        ?: return result.error("INVALID_ARGS", "'playerId' is required", null)

    when (call.method) {
        "start" -> {
            // ... same args extraction, but use getOrCreateMetronomeEngine(playerId)
            getOrCreateMetronomeEngine(playerId).start(bpm, beatsPerBar, clickBytes, accentBytes, ext)
            result.success(null)
        }
        "setBpm" -> {
            val bpm = call.argument<Double>("bpm")
                ?: return result.error("INVALID_ARGS", "'bpm' required", null)
            metronomes[playerId]?.setBpm(bpm)
            result.success(null)
        }
        "setBeatsPerBar" -> {
            val beatsPerBar = call.argument<Int>("beatsPerBar")
                ?: return result.error("INVALID_ARGS", "'beatsPerBar' required", null)
            metronomes[playerId]?.setBeatsPerBar(beatsPerBar)
            result.success(null)
        }
        "stop" -> {
            metronomes[playerId]?.stop()
            result.success(null)
        }
        "dispose" -> {
            metronomes[playerId]?.dispose()
            metronomes.remove(playerId)
            result.success(null)
        }
        else -> result.notImplemented()
    }
}
```

**Step 7: Update `onDetachedFromEngine` cleanup**

Replace:
```kotlin
engine?.dispose()
engine = null
metronomeEngine?.dispose()
metronomeEngine = null
```

With:
```kotlin
engines.values.forEach { it.dispose() }
engines.clear()
metronomes.values.forEach { it.dispose() }
metronomes.clear()
```

**Step 8: Run Android unit tests**

```
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop
./gradlew -p android test
```

Expected: All 26+ existing tests pass. (Android unit tests test pure functions, not the plugin bridge, so no changes needed there.)

**Step 9: Commit**

```bash
git add android/src/main/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPlugin.kt
git commit -m "feat: Android plugin — engine registry for multi-instance support"
```

---

### Task 5: Update all existing Dart tests to expect `playerId` in args

**Files:**
- Modify: `test/load_from_url_bytes_test.dart`
- Modify: `test/metronome_player_test.dart`

**Context:** After Tasks 1 and 2, `invokeMethod` always passes `playerId` in args. The existing tests check specific keys (`path`, `bpm`, etc.) which still work. But add `playerId` assertions to catch regressions.

**Step 1: Update `test/load_from_url_bytes_test.dart`**

In the `loadFromBytes` group, after each `expect(methodCalls.first.method, ...)`, add:
```dart
expect(methodCalls.first.arguments['playerId'], startsWith('loop_'));
```

Do the same for the `loadFromUrl` group (for tests that verify `methodCalls.first.method == 'load'`).

**Step 2: Update `test/metronome_player_test.dart`**

In `group('start')`, the `'sends correct method channel payload'` test already has `args['bpm']` assertions. Add:
```dart
expect(args['playerId'], startsWith('metro_'));
```

In `group('setBpm')`, `'sends correct payload'` test, add:
```dart
expect((calls.first.arguments as Map)['playerId'], startsWith('metro_'));
```

In `group('setBeatsPerBar')`, `'sends correct payload'` test, add:
```dart
expect((calls.first.arguments as Map)['playerId'], startsWith('metro_'));
```

**Step 3: Run all tests**

```
flutter test
```

Expected: All tests pass.

**Step 4: Commit**

```bash
git add test/load_from_url_bytes_test.dart test/metronome_player_test.dart
git commit -m "test: assert playerId present in existing method channel tests"
```

---

### Task 6: Update README

**Files:**
- Modify: `README.md`

**Step 1: Remove single-instance warning**

Find and remove or replace the warning in the `LoopAudioPlayer` doc comment:
```
/// Note: This plugin uses a single shared [MethodChannel] — instantiating
/// multiple [LoopAudioPlayer] objects will result in cross-talk. Use a single
/// instance per application.
```

Change to:
```
/// Multiple [LoopAudioPlayer] instances can run concurrently without cross-talk —
/// each instance is independently managed by the native layer.
```

**Step 2: Add multi-instance section to README**

After the existing "Quick Start" or basic usage section, add:

```markdown
## Multiple Instances

You can run multiple players simultaneously — each instance is fully independent:

```dart
final player1 = LoopAudioPlayer();
final player2 = LoopAudioPlayer();
final metro1  = MetronomePlayer();
final metro2  = MetronomePlayer();

await player1.loadFromFile('/path/to/bass.wav');
await player2.loadFromFile('/path/to/drums.wav');
await player1.play();
await player2.play();

await metro1.start(bpm: 120, beatsPerBar: 4, click: click, accent: accent);
await metro2.start(bpm: 90,  beatsPerBar: 3, click: click, accent: accent);

// Each player's streams are isolated — no cross-talk
player1.stateStream.listen((s) => print('player1: $s'));
player2.bpmStream.listen((r)  => print('player2 bpm: ${r.bpm}'));
metro1.beatStream.listen((b)  => print('metro1 beat: $b'));
metro2.beatStream.listen((b)  => print('metro2 beat: $b'));

// Independent lifecycle
await player1.dispose();  // player2 unaffected
await metro1.dispose();   // metro2 unaffected
```
```

**Step 3: Run flutter analyze to verify no doc issues**

```
flutter analyze
```

Expected: No errors or warnings.

**Step 4: Commit**

```bash
git add README.md lib/src/loop_audio_player.dart
git commit -m "docs: update README for multi-instance support"
```

---

### Task 7: Build verification

**Step 1: Run all Dart tests**

```
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop
flutter test
```

Expected: All tests pass.

**Step 2: Run flutter analyze**

```
flutter analyze
```

Expected: No issues.

**Step 3: Build iOS (no-codesign)**

```
cd example
flutter build ios --no-codesign
```

Expected: Build succeeds.

**Step 4: Run Android unit tests**

```
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop
./gradlew -p android test
```

Expected: All tests pass.

**Step 5: Commit (if any loose files)**

```bash
git status
# Commit anything not yet committed
```

---

## Summary of all files changed

| File | Change |
|------|--------|
| `lib/src/loop_audio_player.dart` | Add `_playerId`, static shared stream, inject `playerId` into every `invokeMethod` call |
| `lib/src/metronome_player.dart` | Same |
| `ios/Classes/FlutterGaplessLoopPlugin.swift` | `engine` → `engines[pid]`; `metronomeEngine` → `metronomes[pid]`; tag all events with `playerId`; update detach cleanup |
| `android/.../FlutterGaplessLoopPlugin.kt` | Same pattern as iOS |
| `test/multi_instance_test.dart` | New — 10 tests: 5 per player type |
| `test/load_from_url_bytes_test.dart` | Add `playerId` assertions |
| `test/metronome_player_test.dart` | Add `playerId` assertions |
| `README.md` | Remove single-instance warning; add multi-instance section |
