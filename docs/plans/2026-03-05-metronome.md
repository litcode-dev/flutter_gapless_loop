# Metronome Feature Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a `MetronomePlayer` class that pre-generates a single-bar PCM buffer (accent at beat 0, click at beats 1…N-1) and loops it via the hardware scheduler for sample-accurate timing, with a UI-hint beat-tick event stream.

**Architecture:** Dart API on two new channels (`flutter_gapless_loop/metronome` method, `flutter_gapless_loop/metronome/events` event). Native `MetronomeEngine` on each platform. iOS uses `AVAudioPlayerNode.scheduleBuffer(.loops)` + `DispatchSourceTimer`. Android uses `AudioTrack MODE_STATIC` + `setLoopPoints(0, barFrames, -1)` + `Handler`. Click/accent bytes decoded from a temp file via `AVAudioFile` (iOS) / `AudioFileLoader.decode` (Android).

**Tech Stack:** Dart, Flutter MethodChannel/EventChannel, Swift/AVFoundation (iOS 14+), Kotlin/AudioTrack (Android API 23+), existing `AudioFileLoader.kt` for Android decoding.

---

### Task 1: Dart MetronomePlayer + failing tests

**Files:**
- Create: `test/metronome_player_test.dart`
- Create: `lib/src/metronome_player.dart` (stub only — enough to compile)

**Step 1: Create stub `lib/src/metronome_player.dart`**

This stub lets the test file compile. We'll fill in the real implementation in Step 4.

```dart
import 'dart:async';
import 'package:flutter/services.dart';

class MetronomePlayer {
  static const _channel = MethodChannel('flutter_gapless_loop/metronome');
  static const _eventChannel = EventChannel('flutter_gapless_loop/metronome/events');

  bool _isDisposed = false;

  void _checkNotDisposed() {
    if (_isDisposed) throw StateError('MetronomePlayer has been disposed.');
  }

  Future<void> start({
    required double bpm,
    required int beatsPerBar,
    required Uint8List click,
    required Uint8List accent,
    String extension = 'wav',
  }) async => throw UnimplementedError();

  Future<void> stop() async => throw UnimplementedError();
  Future<void> setBpm(double bpm) async => throw UnimplementedError();
  Future<void> setBeatsPerBar(int beatsPerBar) async => throw UnimplementedError();
  Stream<int> get beatStream => throw UnimplementedError();
  Future<void> dispose() async => throw UnimplementedError();
}
```

**Step 2: Create `test/metronome_player_test.dart`**

```dart
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_gapless_loop/flutter_gapless_loop.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final stubBytes = Uint8List(100);
  late List<MethodCall> calls;

  setUp(() {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('flutter_gapless_loop/metronome'),
      (call) async {
        calls.add(call);
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('flutter_gapless_loop/metronome'),
      null,
    );
  });

  group('start', () {
    test('sends correct method channel payload', () async {
      final player = MetronomePlayer();
      await player.start(
        bpm: 120.0,
        beatsPerBar: 4,
        click: stubBytes,
        accent: stubBytes,
      );
      expect(calls, hasLength(1));
      expect(calls.first.method, 'start');
      final args = calls.first.arguments as Map;
      expect(args['bpm'], 120.0);
      expect(args['beatsPerBar'], 4);
      expect(args['click'], stubBytes);
      expect(args['accent'], stubBytes);
      expect(args['extension'], 'wav');
    });

    test('passes custom extension', () async {
      final player = MetronomePlayer();
      await player.start(
        bpm: 120.0,
        beatsPerBar: 4,
        click: stubBytes,
        accent: stubBytes,
        extension: 'mp3',
      );
      expect((calls.first.arguments as Map)['extension'], 'mp3');
    });

    test('throws ArgumentError for bpm <= 0', () {
      final player = MetronomePlayer();
      expect(
        () => player.start(bpm: 0.0, beatsPerBar: 4, click: stubBytes, accent: stubBytes),
        throwsArgumentError,
      );
      expect(
        () => player.start(bpm: -10.0, beatsPerBar: 4, click: stubBytes, accent: stubBytes),
        throwsArgumentError,
      );
    });

    test('throws ArgumentError for bpm > 400', () {
      final player = MetronomePlayer();
      expect(
        () => player.start(bpm: 401.0, beatsPerBar: 4, click: stubBytes, accent: stubBytes),
        throwsArgumentError,
      );
    });

    test('throws ArgumentError for beatsPerBar < 1', () {
      final player = MetronomePlayer();
      expect(
        () => player.start(bpm: 120.0, beatsPerBar: 0, click: stubBytes, accent: stubBytes),
        throwsArgumentError,
      );
    });

    test('throws ArgumentError for beatsPerBar > 16', () {
      final player = MetronomePlayer();
      expect(
        () => player.start(bpm: 120.0, beatsPerBar: 17, click: stubBytes, accent: stubBytes),
        throwsArgumentError,
      );
    });
  });

  group('setBpm', () {
    test('sends correct payload', () async {
      final player = MetronomePlayer();
      await player.setBpm(140.0);
      expect(calls.first.method, 'setBpm');
      expect((calls.first.arguments as Map)['bpm'], 140.0);
    });

    test('throws ArgumentError for bpm <= 0', () {
      expect(() => MetronomePlayer().setBpm(0.0), throwsArgumentError);
    });

    test('throws ArgumentError for bpm > 400', () {
      expect(() => MetronomePlayer().setBpm(500.0), throwsArgumentError);
    });
  });

  group('setBeatsPerBar', () {
    test('sends correct payload', () async {
      final player = MetronomePlayer();
      await player.setBeatsPerBar(3);
      expect(calls.first.method, 'setBeatsPerBar');
      expect((calls.first.arguments as Map)['beatsPerBar'], 3);
    });

    test('throws ArgumentError for beatsPerBar < 1', () {
      expect(() => MetronomePlayer().setBeatsPerBar(0), throwsArgumentError);
    });

    test('throws ArgumentError for beatsPerBar > 16', () {
      expect(() => MetronomePlayer().setBeatsPerBar(17), throwsArgumentError);
    });
  });

  group('beatStream', () {
    test('returns Stream<int>', () {
      expect(MetronomePlayer().beatStream, isA<Stream<int>>());
    });
  });

  group('dispose', () {
    test('throws StateError on start after dispose', () async {
      final player = MetronomePlayer();
      await player.dispose();
      expect(
        () => player.start(bpm: 120.0, beatsPerBar: 4, click: stubBytes, accent: stubBytes),
        throwsStateError,
      );
    });

    test('throws StateError on stop after dispose', () async {
      final player = MetronomePlayer();
      await player.dispose();
      expect(() => player.stop(), throwsStateError);
    });

    test('throws StateError on setBpm after dispose', () async {
      final player = MetronomePlayer();
      await player.dispose();
      expect(() => player.setBpm(120.0), throwsStateError);
    });

    test('throws StateError on setBeatsPerBar after dispose', () async {
      final player = MetronomePlayer();
      await player.dispose();
      expect(() => player.setBeatsPerBar(4), throwsStateError);
    });

    test('throws StateError on beatStream after dispose', () async {
      final player = MetronomePlayer();
      await player.dispose();
      expect(() => player.beatStream, throwsStateError);
    });
  });
}
```

**Step 3: Run tests to verify they fail**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop
flutter test test/metronome_player_test.dart 2>&1 | tail -10
```

Expected: tests compile but fail with `UnimplementedError`.

**Step 4: Implement `lib/src/metronome_player.dart`**

Replace the stub with the full implementation:

```dart
import 'dart:async';
import 'package:flutter/services.dart';

/// A sample-accurate metronome that pre-generates a bar buffer and loops it
/// on the native hardware scheduler.
///
/// Runs independently from [LoopAudioPlayer] — both can play simultaneously.
///
/// Method channel: `"flutter_gapless_loop/metronome"`
/// Event channel:  `"flutter_gapless_loop/metronome/events"`
class MetronomePlayer {
  static const _channel =
      MethodChannel('flutter_gapless_loop/metronome');
  static const _eventChannel =
      EventChannel('flutter_gapless_loop/metronome/events');

  late final Stream<Map<Object?, Object?>> _events;
  bool _isDisposed = false;

  MetronomePlayer() {
    _events = _eventChannel
        .receiveBroadcastStream()
        .cast<Map<Object?, Object?>>();
  }

  void _checkNotDisposed() {
    if (_isDisposed) throw StateError('MetronomePlayer has been disposed.');
  }

  /// Starts the metronome.
  ///
  /// [bpm] must be in (0, 400]. [beatsPerBar] must be in [1, 16].
  /// [click] is audio bytes for a regular beat; [accent] for the downbeat (beat 0).
  /// [extension] is the decoder hint for click/accent format (default `'wav'`).
  Future<void> start({
    required double bpm,
    required int beatsPerBar,
    required Uint8List click,
    required Uint8List accent,
    String extension = 'wav',
  }) async {
    _checkNotDisposed();
    if (bpm <= 0 || bpm > 400) {
      throw ArgumentError.value(bpm, 'bpm', 'must be in (0, 400]');
    }
    if (beatsPerBar < 1 || beatsPerBar > 16) {
      throw ArgumentError.value(beatsPerBar, 'beatsPerBar', 'must be in [1, 16]');
    }
    await _channel.invokeMethod<void>('start', {
      'bpm': bpm,
      'beatsPerBar': beatsPerBar,
      'click': click,
      'accent': accent,
      'extension': extension,
    });
  }

  /// Stops the metronome immediately.
  Future<void> stop() async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>('stop');
  }

  /// Updates tempo without stopping. Regenerates the bar buffer.
  Future<void> setBpm(double bpm) async {
    _checkNotDisposed();
    if (bpm <= 0 || bpm > 400) {
      throw ArgumentError.value(bpm, 'bpm', 'must be in (0, 400]');
    }
    await _channel.invokeMethod<void>('setBpm', {'bpm': bpm});
  }

  /// Updates time signature. Regenerates the bar buffer.
  Future<void> setBeatsPerBar(int beatsPerBar) async {
    _checkNotDisposed();
    if (beatsPerBar < 1 || beatsPerBar > 16) {
      throw ArgumentError.value(beatsPerBar, 'beatsPerBar', 'must be in [1, 16]');
    }
    await _channel.invokeMethod<void>('setBeatsPerBar', {'beatsPerBar': beatsPerBar});
  }

  /// Beat index fired on each click: 0 = downbeat, 1…N-1 = regular beats.
  /// UI hint only — not used for audio scheduling (±5 ms jitter acceptable).
  Stream<int> get beatStream {
    _checkNotDisposed();
    return _events
        .where((e) => e['type'] == 'beatTick')
        .map((e) => e['beat'] as int? ?? 0);
  }

  /// Releases all native resources. This instance cannot be used after dispose.
  Future<void> dispose() async {
    _isDisposed = true;
    await _channel.invokeMethod<void>('dispose');
  }
}
```

**Step 5: Run tests — expect all to pass**

```bash
flutter test test/metronome_player_test.dart 2>&1 | tail -5
```

Expected: `All tests passed!`

**Step 6: Commit**

```bash
git add lib/src/metronome_player.dart test/metronome_player_test.dart
git commit -m "feat: add MetronomePlayer Dart class with unit tests"
```

---

### Task 2: Export MetronomePlayer from barrel file

**Files:**
- Modify: `lib/flutter_gapless_loop.dart`

**Step 1: Add export**

In `lib/flutter_gapless_loop.dart`, add after the existing exports:

```dart
export 'src/metronome_player.dart';
```

Full file after edit:

```dart
/// Flutter plugin for true sample-accurate gapless audio looping on iOS.
///
/// Primary entry point is [LoopAudioPlayer].
///
/// ## Quick Start
///
/// ```dart
/// import 'package:flutter_gapless_loop/flutter_gapless_loop.dart';
///
/// final player = LoopAudioPlayer();
/// await player.loadFromFile('/absolute/path/to/loop.wav');
/// await player.play();
/// // ... later
/// await player.dispose();
/// ```
library;

export 'src/loop_audio_player.dart';
export 'src/loop_audio_state.dart';
export 'src/metronome_player.dart';
```

**Step 2: Run full test suite**

```bash
flutter test 2>&1 | tail -5
```

Expected: all tests pass.

**Step 3: Commit**

```bash
git add lib/flutter_gapless_loop.dart
git commit -m "feat: export MetronomePlayer from package barrel"
```

---

### Task 3: iOS MetronomeEngine.swift

**Files:**
- Create: `ios/Classes/MetronomeEngine.swift`

**Step 1: Create the file**

```swift
#if os(iOS)
import AVFoundation
import os.log

/// Generates a single-bar PCM buffer (accent + N-1 clicks + silence) and loops
/// it indefinitely via AVAudioPlayerNode.scheduleBuffer(.loops).
///
/// Beat-tick events (UI hint, ±5 ms jitter) are fired via DispatchSourceTimer.
/// All mutations must be called from the main thread.
@available(iOS 14.0, *)
final class MetronomeEngine {

    // MARK: - Callbacks

    /// Called on main thread each beat. 0 = downbeat, 1…N-1 = regular beat.
    var onBeatTick: ((Int) -> Void)?
    /// Called on main thread when a recoverable error occurs.
    var onError: ((String) -> Void)?

    // MARK: - Private state

    private var audioEngine     = AVAudioEngine()
    private var playerNode      = AVAudioPlayerNode()
    private let logger          = Logger(subsystem: "com.fluttergaplessloop", category: "Metronome")

    private var clickBuffer:    AVAudioPCMBuffer?
    private var accentBuffer:   AVAudioPCMBuffer?
    private var barBuffer:      AVAudioPCMBuffer?

    private var currentBpm:         Double = 120
    private var currentBeatsPerBar: Int    = 4
    private var isRunning = false

    private var beatTimer:    DispatchSourceTimer?
    private var beatIndex     = 0

    // MARK: - Public API

    /// Decodes click/accent bytes and starts looping.
    func start(bpm: Double,
               beatsPerBar: Int,
               clickData: Data,
               accentData: Data,
               fileExtension: String) {
        do {
            clickBuffer  = try loadBuffer(from: clickData,  ext: fileExtension)
            accentBuffer = try loadBuffer(from: accentData, ext: fileExtension)
        } catch {
            onError?(error.localizedDescription)
            return
        }

        currentBpm         = bpm
        currentBeatsPerBar = beatsPerBar

        guard let bar = buildBarBuffer(bpm: bpm, beatsPerBar: beatsPerBar) else {
            onError?("Failed to build bar buffer")
            return
        }
        barBuffer = bar

        setupAndPlay(format: bar.format)
        startBeatTimer(bpm: bpm, beatsPerBar: beatsPerBar)
        isRunning = true
        logger.info("MetronomeEngine started: \(bpm) BPM, \(beatsPerBar)/4")
    }

    /// Stops playback immediately.
    func stop() {
        stopBeatTimer()
        playerNode.stop()
        isRunning = false
    }

    /// Rebuilds bar buffer and restarts at new tempo. No-op if not started.
    func setBpm(_ bpm: Double) {
        guard isRunning else { return }
        currentBpm = bpm
        rebuildAndRestart()
    }

    /// Rebuilds bar buffer and restarts with new time signature. No-op if not started.
    func setBeatsPerBar(_ beatsPerBar: Int) {
        guard isRunning else { return }
        currentBeatsPerBar = beatsPerBar
        rebuildAndRestart()
    }

    /// Releases all native resources.
    func dispose() {
        stop()
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.detach(playerNode)
    }

    // MARK: - Private helpers

    private func setupAndPlay(format: AVAudioFormat) {
        // Reset graph on each start / restart to avoid stale connections.
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine = AVAudioEngine()
        playerNode  = AVAudioPlayerNode()

        audioEngine.attach(playerNode)
        audioEngine.connect(playerNode,
                            to: audioEngine.mainMixerNode,
                            format: format)
        do {
            try audioEngine.start()
        } catch {
            onError?("AVAudioEngine start failed: \(error.localizedDescription)")
            return
        }

        guard let bar = barBuffer else { return }
        playerNode.scheduleBuffer(bar, at: nil, options: .loops, completionHandler: nil)
        playerNode.play()
    }

    private func rebuildAndRestart() {
        guard let bar = buildBarBuffer(bpm: currentBpm, beatsPerBar: currentBeatsPerBar) else {
            onError?("Failed to rebuild bar buffer")
            return
        }
        barBuffer = bar
        stopBeatTimer()
        setupAndPlay(format: bar.format)
        beatIndex = 0
        startBeatTimer(bpm: currentBpm, beatsPerBar: currentBeatsPerBar)
    }

    // MARK: Bar buffer generation

    /// Builds a bar buffer: accent at frame 0, click at beat positions 1…N-1.
    ///
    /// Returns nil if click or accent buffers are not loaded.
    private func buildBarBuffer(bpm: Double, beatsPerBar: Int) -> AVAudioPCMBuffer? {
        guard let click = clickBuffer, let accent = accentBuffer else { return nil }

        let format           = click.format
        let sampleRate       = format.sampleRate
        let beatFrames       = AVAudioFrameCount(sampleRate * 60.0 / bpm)
        let barFrames        = beatFrames * AVAudioFrameCount(beatsPerBar)

        guard let bar = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: barFrames) else {
            return nil
        }
        bar.frameLength = barFrames

        // Zero-fill is guaranteed by AVAudioPCMBuffer initialisation.
        mixInto(bar, source: accent, atFrame: 0)
        for beat in 1..<beatsPerBar {
            mixInto(bar, source: click, atFrame: AVAudioFramePosition(beat) * AVAudioFramePosition(beatFrames))
        }

        // Apply 5 ms micro-fade at both ends to prevent click artefacts on restart.
        applyMicroFade(bar)
        return bar
    }

    /// Adds [source] samples into [dest] at [offsetFrame], clamped to dest length.
    private func mixInto(_ dest: AVAudioPCMBuffer,
                         source: AVAudioPCMBuffer,
                         atFrame offsetFrame: AVAudioFramePosition) {
        guard let srcCh = source.floatChannelData,
              let dstCh = dest.floatChannelData else { return }

        let channelCount = Int(dest.format.channelCount)
        let destRemaining = Int(dest.frameLength) - Int(offsetFrame)
        guard destRemaining > 0 else { return }
        let framesToCopy = Int(min(source.frameLength, AVAudioFrameCount(destRemaining)))

        for ch in 0..<channelCount {
            let src = srcCh[ch]
            let dst = dstCh[ch]
            for i in 0..<framesToCopy {
                dst[Int(offsetFrame) + i] += src[i]
            }
        }

        // Clamp to [-1, 1] after mixing.
        for ch in 0..<channelCount {
            let dst = dstCh[ch]
            for i in 0..<Int(dest.frameLength) {
                dst[i] = max(-1.0, min(1.0, dst[i]))
            }
        }
    }

    /// Applies a 5 ms linear fade-in at frame 0 and fade-out at the end.
    private func applyMicroFade(_ buffer: AVAudioPCMBuffer) {
        guard let channels = buffer.floatChannelData else { return }
        let sampleRate  = buffer.format.sampleRate
        let fadeFrames  = Int(sampleRate * 0.005)
        let totalFrames = Int(buffer.frameLength)
        let nCh         = Int(buffer.format.channelCount)

        for i in 0..<fadeFrames {
            let gain = Float(i) / Float(fadeFrames)
            for ch in 0..<nCh {
                channels[ch][i] *= gain
                let endIdx = totalFrames - 1 - i
                if endIdx > i { channels[ch][endIdx] *= gain }
            }
        }
    }

    // MARK: Audio byte loading

    /// Writes [data] to a temp file, opens it as AVAudioFile, reads into PCM buffer.
    private func loadBuffer(from data: Data, ext: String) throws -> AVAudioPCMBuffer {
        let tmpURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("metronome_\(UInt64(Date().timeIntervalSince1970 * 1000)).\(ext)")
        try data.write(to: tmpURL)
        defer { try? FileManager.default.removeItem(at: tmpURL) }

        let file = try AVAudioFile(forReading: tmpURL)
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)
        ) else {
            throw NSError(domain: "MetronomeEngine", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to create PCM buffer"])
        }
        try file.read(into: buffer)
        return buffer
    }

    // MARK: Beat timer

    private func startBeatTimer(bpm: Double, beatsPerBar: Int) {
        beatIndex = 0
        let beatNs = UInt64(60_000_000_000.0 / bpm)

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(Int(beatNs)), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.onBeatTick?(self.beatIndex)
            self.beatIndex = (self.beatIndex + 1) % beatsPerBar
        }
        timer.resume()
        beatTimer = timer
    }

    private func stopBeatTimer() {
        beatTimer?.cancel()
        beatTimer = nil
        beatIndex = 0
    }
}
#endif
```

**Step 2: Commit**

```bash
git add ios/Classes/MetronomeEngine.swift
git commit -m "feat(ios): add MetronomeEngine — bar buffer generation + AVAudioPlayerNode loop"
```

---

### Task 4: iOS plugin bridge updates

**Files:**
- Modify: `ios/Classes/FlutterGaplessLoopPlugin.swift`

**Step 1: Read the current file (to get exact current content before editing)**

```bash
cat ios/Classes/FlutterGaplessLoopPlugin.swift
```

**Step 2: Add MetronomeStreamHandler class and wire it**

At the **top** of `FlutterGaplessLoopPlugin.swift`, **after** the `#if os(iOS)` line and imports, add the helper class:

```swift
/// StreamHandler for the metronome event channel.
/// Separate class keeps the metronome's onListen/onCancel isolated from the loop player's.
@available(iOS 14.0, *)
private final class MetronomeStreamHandler: NSObject, FlutterStreamHandler {
    var eventSink: FlutterEventSink?

    func onListen(withArguments arguments: Any?,
                  eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }
}
```

**Step 3: Add metronome properties to `FlutterGaplessLoopPlugin`**

Inside `FlutterGaplessLoopPlugin`, after `private var registrar: FlutterPluginRegistrar?`, add:

```swift
    private var metronomeEngine: MetronomeEngine?
    private let metronomeStreamHandler = MetronomeStreamHandler()
```

**Step 4: Register metronome channels in `register(with:)`**

After `eventChannel.setStreamHandler(instance)`, add:

```swift
        let metronomeMethodChannel = FlutterMethodChannel(
            name: "flutter_gapless_loop/metronome",
            binaryMessenger: registrar.messenger()
        )
        let metronomeEventChannel = FlutterEventChannel(
            name: "flutter_gapless_loop/metronome/events",
            binaryMessenger: registrar.messenger()
        )
        metronomeEventChannel.setStreamHandler(instance.metronomeStreamHandler)
        registrar.addMethodCallDelegate(instance, channel: metronomeMethodChannel)
```

**Step 5: Add metronome cases to `handle(_:result:)`**

In the `switch call.method` block, add after the existing cases and before the `default:`:

```swift
        // MARK: Metronome

        case "start":
            guard let bpmVal    = args?["bpm"]         as? Double,
                  let beatsVal  = args?["beatsPerBar"]  as? Int,
                  let clickData = args?["click"]        as? FlutterStandardTypedData,
                  let accentData = args?["accent"]      as? FlutterStandardTypedData else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "INVALID_ARGS",
                                        message: "start requires bpm, beatsPerBar, click, accent",
                                        details: nil))
                }
                return
            }
            let ext = args?["extension"] as? String ?? "wav"
            let eng = getOrCreateMetronomeEngine()
            eng.start(bpm: bpmVal,
                      beatsPerBar: beatsVal,
                      clickData: clickData.data,
                      accentData: accentData.data,
                      fileExtension: ext)
            DispatchQueue.main.async { result(nil) }

        case "setBpm":
            guard let bpmVal = args?["bpm"] as? Double else {
                DispatchQueue.main.async { result(FlutterError(code: "INVALID_ARGS", message: "'bpm' required", details: nil)) }
                return
            }
            metronomeEngine?.setBpm(bpmVal)
            DispatchQueue.main.async { result(nil) }

        case "setBeatsPerBar":
            guard let beatsVal = args?["beatsPerBar"] as? Int else {
                DispatchQueue.main.async { result(FlutterError(code: "INVALID_ARGS", message: "'beatsPerBar' required", details: nil)) }
                return
            }
            metronomeEngine?.setBeatsPerBar(beatsVal)
            DispatchQueue.main.async { result(nil) }

        case "stop":
            metronomeEngine?.stop()
            DispatchQueue.main.async { result(nil) }

        case "dispose":
            metronomeEngine?.dispose()
            metronomeEngine = nil
            DispatchQueue.main.async { result(nil) }
```

**Important:** The existing `dispose` case for the loop player also uses `"dispose"`. You must ensure the two method channels don't conflict. They are registered on **separate** `FlutterMethodChannel` instances with different names, but both call `addMethodCallDelegate(instance, channel:)`. Flutter routes calls by channel name, so there will be no conflict — each channel's calls come in separately. However, both will hit the same `handle(_:result:)` switch. The existing loop player `dispose` case is fine; add the metronome dispose case with a distinct name:

Rename the metronome dispose handling to `"dispose"` — but it is on a different channel. Since the same `handle(_:result:)` is the delegate for both channels, there **is** a naming conflict for `dispose` and `stop`.

**Fix:** Use separate method call delegates. Replace:

```swift
registrar.addMethodCallDelegate(instance, channel: metronomeMethodChannel)
```

With a dedicated handler class. Add this class to the file:

```swift
/// Routes metronome method calls to MetronomeEngine.
@available(iOS 14.0, *)
private final class MetronomeMethodHandler: NSObject, FlutterPlugin {
    static func register(with registrar: FlutterPluginRegistrar) {}

    weak var plugin: FlutterGaplessLoopPlugin?

    func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        plugin?.handleMetronomeCall(call, result: result)
    }
}
```

And in `register(with:)`, replace `addMethodCallDelegate(instance, ...)` for metronome with:

```swift
        let metronomeHandler = MetronomeMethodHandler()
        metronomeHandler.plugin = instance
        registrar.addMethodCallDelegate(metronomeHandler, channel: metronomeMethodChannel)
```

Add `handleMetronomeCall` to `FlutterGaplessLoopPlugin`:

```swift
    func handleMetronomeCall(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]

        switch call.method {

        case "start":
            guard let bpmVal     = args?["bpm"]          as? Double,
                  let beatsVal   = args?["beatsPerBar"]   as? Int,
                  let clickData  = args?["click"]         as? FlutterStandardTypedData,
                  let accentData = args?["accent"]        as? FlutterStandardTypedData else {
                result(FlutterError(code: "INVALID_ARGS",
                                    message: "start requires bpm, beatsPerBar, click, accent",
                                    details: nil))
                return
            }
            let ext = args?["extension"] as? String ?? "wav"
            let eng = getOrCreateMetronomeEngine()
            eng.start(bpm: bpmVal,
                      beatsPerBar: beatsVal,
                      clickData: clickData.data,
                      accentData: accentData.data,
                      fileExtension: ext)
            result(nil)

        case "setBpm":
            guard let bpmVal = args?["bpm"] as? Double else {
                result(FlutterError(code: "INVALID_ARGS", message: "'bpm' required", details: nil))
                return
            }
            metronomeEngine?.setBpm(bpmVal)
            result(nil)

        case "setBeatsPerBar":
            guard let beatsVal = args?["beatsPerBar"] as? Int else {
                result(FlutterError(code: "INVALID_ARGS", message: "'beatsPerBar' required", details: nil))
                return
            }
            metronomeEngine?.setBeatsPerBar(beatsVal)
            result(nil)

        case "stop":
            metronomeEngine?.stop()
            result(nil)

        case "dispose":
            metronomeEngine?.dispose()
            metronomeEngine = nil
            result(nil)

        default:
            result(FlutterMethodNotImplemented)
        }
    }
```

Add the helper that creates the engine and wires beat-tick callback:

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

**Step 6: Commit**

```bash
git add ios/Classes/FlutterGaplessLoopPlugin.swift
git commit -m "feat(ios): register metronome channels and wire MetronomeEngine to plugin bridge"
```

---

### Task 5: Android MetronomeEngine.kt + unit tests

**Files:**
- Create: `android/src/main/kotlin/com/fluttergaplessloop/MetronomeEngine.kt`
- Modify: `android/src/test/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPluginTest.kt`

**Step 1: Write failing unit tests first**

Add this class at the bottom of `FlutterGaplessLoopPluginTest.kt`:

```kotlin
class MetronomeEngineTest {

    @Test
    fun `buildBarBuffer returns correct frame count`() {
        val sampleRate   = 44100
        val bpm          = 120.0
        val beatsPerBar  = 4
        val channelCount = 1
        val beatFrames   = (sampleRate * 60.0 / bpm).toInt()    // 22050
        val expectedLen  = beatFrames * beatsPerBar * channelCount  // 88200

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
        val sampleRate = 44100
        val click      = FloatArray(100) { 0.3f }
        val accent     = FloatArray(100) { 0.9f }

        val bar = MetronomeEngine.buildBarBuffer(
            accentPcm = accent, accentFrames = 100,
            clickPcm  = click,  clickFrames  = 100,
            sampleRate = sampleRate, channelCount = 1,
            bpm = 120.0, beatsPerBar = 4
        )

        // First 100 samples should be non-zero (accent placed at frame 0)
        assertTrue(bar.take(100).any { it != 0f })
    }

    @Test
    fun `buildBarBuffer places click at beat 1 position`() {
        val sampleRate  = 44100
        val bpm         = 120.0
        val beatFrames  = (sampleRate * 60.0 / bpm).toInt()  // 22050

        val click  = FloatArray(100) { 0.5f }
        val accent = FloatArray(100) { 1.0f }

        val bar = MetronomeEngine.buildBarBuffer(
            accentPcm = accent, accentFrames = 100,
            clickPcm  = click,  clickFrames  = 100,
            sampleRate = sampleRate, channelCount = 1,
            bpm = bpm, beatsPerBar = 4
        )

        // Silence between accent end (100) and click start (beatFrames)
        for (i in 100 until beatFrames) {
            assertEquals(0f, bar[i], "Expected silence at frame $i")
        }

        // Click at beatFrames
        assertTrue(bar[beatFrames] != 0f, "Expected click at beat 1 frame $beatFrames")
    }

    @Test
    fun `buildBarBuffer silence region between beats`() {
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

        // Silence between accent tail (50) and beat 1 (22050)
        for (i in 50 until beatFrames) {
            assertEquals(0f, bar[i], "Expected silence at frame $i")
        }
    }
}
```

**Step 2: Run to verify they fail**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop
./gradlew :flutter_gapless_loop:testDebugUnitTest 2>&1 | tail -20
```

Expected: compile error — `MetronomeEngine` not found.

**Step 3: Create `android/src/main/kotlin/com/fluttergaplessloop/MetronomeEngine.kt`**

```kotlin
package com.fluttergaplessloop

import android.audio.play.java.android.media.AudioAttributes
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioManager
import android.media.AudioTrack
import android.os.Handler
import android.os.Looper
import android.util.Log
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import java.io.File

/**
 * Pre-generates a single-bar PCM buffer and loops it via [AudioTrack] MODE_STATIC +
 * [AudioTrack.setLoopPoints] for sample-accurate metronome timing.
 *
 * Beat-tick events (UI hint, ±5 ms jitter) are fired via a [Handler] timer.
 *
 * All public methods must be called from the main thread.
 *
 * @param onBeatTick  Called on main thread with beat index (0 = downbeat, 1…N-1 = click).
 * @param onError     Called on main thread with error message string.
 */
class MetronomeEngine(
    private val onBeatTick: (Int) -> Unit,
    private val onError:    (String) -> Unit
) {

    companion object {
        private const val TAG = "MetronomeEngine"

        /**
         * Builds a bar PCM buffer: accent at frame 0, click at beat positions 1…N-1.
         *
         * The result is a float array of length = beatPeriodFrames * beatsPerBar * channelCount.
         * Both accent and click are mixed (summed + clamped) into the silence buffer.
         *
         * @param accentPcm    Decoded accent PCM (interleaved floats, [-1,1]).
         * @param accentFrames Frame count of accent.
         * @param clickPcm     Decoded click PCM (interleaved floats, [-1,1]).
         * @param clickFrames  Frame count of click.
         * @param sampleRate   Sample rate in Hz.
         * @param channelCount 1 = mono, 2 = stereo.
         * @param bpm          Tempo in beats per minute.
         * @param beatsPerBar  Time signature numerator.
         */
        internal fun buildBarBuffer(
            accentPcm:    FloatArray, accentFrames: Int,
            clickPcm:     FloatArray, clickFrames:  Int,
            sampleRate:   Int,        channelCount: Int,
            bpm:          Double,     beatsPerBar:  Int
        ): FloatArray {
            val beatFrames = (sampleRate * 60.0 / bpm).toInt()
            val barFrames  = beatFrames * beatsPerBar
            val bar        = FloatArray(barFrames * channelCount)  // zero-filled

            // Place accent at frame 0
            val accentSamples = minOf(accentFrames * channelCount, bar.size)
            for (i in 0 until accentSamples) {
                bar[i] = (bar[i] + accentPcm[i]).coerceIn(-1f, 1f)
            }

            // Place click at beat positions 1…beatsPerBar-1
            for (beat in 1 until beatsPerBar) {
                val offset    = beat * beatFrames * channelCount
                val available = bar.size - offset
                if (available <= 0) break
                val clickSamples = minOf(clickFrames * channelCount, available)
                for (i in 0 until clickSamples) {
                    bar[offset + i] = (bar[offset + i] + clickPcm[i]).coerceIn(-1f, 1f)
                }
            }

            // Apply 5 ms micro-fade at both ends to avoid click on restart
            AudioFileLoader.applyMicroFade(bar, sampleRate, channelCount)
            return bar
        }
    }

    private val scope = CoroutineScope(Dispatchers.Main + SupervisorJob())
    private val mainHandler = Handler(Looper.getMainLooper())

    private var audioTrack:     AudioTrack? = null
    private var beatRunnable:   Runnable?   = null

    private var accentPcm:    FloatArray? = null
    private var accentFrames: Int         = 0
    private var clickPcm:     FloatArray? = null
    private var clickFrames:  Int         = 0
    private var sampleRate:   Int         = 44100
    private var channelCount: Int         = 1

    private var currentBpm:         Double = 120.0
    private var currentBeatsPerBar: Int    = 4
    private var isRunning = false

    // ─── Public API ───────────────────────────────────────────────────────────

    /**
     * Decodes click/accent bytes from temp files and starts the metronome.
     *
     * @param bpm          Tempo in BPM.
     * @param beatsPerBar  Time signature numerator.
     * @param clickBytes   Raw audio bytes for regular beat click.
     * @param accentBytes  Raw audio bytes for downbeat accent.
     * @param extension    File extension hint for the decoder (e.g. "wav", "mp3").
     */
    fun start(
        bpm:         Double,
        beatsPerBar: Int,
        clickBytes:  ByteArray,
        accentBytes: ByteArray,
        extension:   String
    ) {
        scope.launch {
            try {
                val click  = decodeBytes(clickBytes,  extension)
                val accent = decodeBytes(accentBytes, extension)

                accentPcm    = accent.pcm
                accentFrames = accent.totalFrames
                clickPcm     = click.pcm
                clickFrames  = click.totalFrames
                sampleRate   = click.sampleRate
                channelCount = click.channelCount

                currentBpm         = bpm
                currentBeatsPerBar = beatsPerBar

                val bar = buildBarBuffer(
                    accentPcm    = accent.pcm, accentFrames = accent.totalFrames,
                    clickPcm     = click.pcm,  clickFrames  = click.totalFrames,
                    sampleRate   = click.sampleRate, channelCount = click.channelCount,
                    bpm          = bpm, beatsPerBar = beatsPerBar
                )
                playBarBuffer(bar, click.sampleRate, click.channelCount)
                startBeatTimer(bpm, beatsPerBar)
                isRunning = true
                Log.i(TAG, "Started: $bpm BPM, $beatsPerBar/4")
            } catch (e: Exception) {
                onError("MetronomeEngine start failed: ${e.message}")
            }
        }
    }

    /** Stops playback immediately. */
    fun stop() {
        stopBeatTimer()
        releaseAudioTrack()
        isRunning = false
    }

    /** Rebuilds bar buffer at new tempo. No-op if not started. */
    fun setBpm(bpm: Double) {
        if (!isRunning) return
        currentBpm = bpm
        rebuildAndRestart()
    }

    /** Rebuilds bar buffer with new time signature. No-op if not started. */
    fun setBeatsPerBar(beatsPerBar: Int) {
        if (!isRunning) return
        currentBeatsPerBar = beatsPerBar
        rebuildAndRestart()
    }

    /** Releases all resources. */
    fun dispose() {
        stop()
    }

    // ─── Private helpers ─────────────────────────────────────────────────────

    private fun rebuildAndRestart() {
        val aPcm = accentPcm ?: return
        val cPcm = clickPcm  ?: return

        scope.launch {
            stopBeatTimer()
            releaseAudioTrack()

            val bar = buildBarBuffer(
                accentPcm    = aPcm,    accentFrames = accentFrames,
                clickPcm     = cPcm,    clickFrames  = clickFrames,
                sampleRate   = sampleRate, channelCount = channelCount,
                bpm          = currentBpm, beatsPerBar = currentBeatsPerBar
            )
            playBarBuffer(bar, sampleRate, channelCount)
            startBeatTimer(currentBpm, currentBeatsPerBar)
        }
    }

    private fun playBarBuffer(bar: FloatArray, sampleRate: Int, channelCount: Int) {
        releaseAudioTrack()

        val barFrames       = bar.size / channelCount
        val bufferSizeBytes = bar.size * 2  // PCM_16BIT = 2 bytes per sample

        val channelMask = if (channelCount == 1)
            AudioFormat.CHANNEL_OUT_MONO else AudioFormat.CHANNEL_OUT_STEREO

        val track = AudioTrack(
            AudioAttributes.Builder()
                .setUsage(AudioAttributes.USAGE_MEDIA)
                .setContentType(AudioAttributes.CONTENT_TYPE_MUSIC)
                .build(),
            AudioFormat.Builder()
                .setSampleRate(sampleRate)
                .setChannelMask(channelMask)
                .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
                .build(),
            bufferSizeBytes,
            AudioTrack.MODE_STATIC,
            AudioManager.AUDIO_SESSION_ID_GENERATE
        )

        // Convert float → int16
        val pcmShort = ShortArray(bar.size) { i ->
            (bar[i] * 32767f).toInt().coerceIn(-32768, 32767).toShort()
        }

        track.write(pcmShort, 0, pcmShort.size)
        track.setLoopPoints(0, barFrames, -1)  // -1 = loop forever
        track.play()
        audioTrack = track
    }

    private fun releaseAudioTrack() {
        audioTrack?.let {
            try { it.stop() }  catch (_: Exception) {}
            try { it.release() } catch (_: Exception) {}
        }
        audioTrack = null
    }

    private fun startBeatTimer(bpm: Double, beatsPerBar: Int) {
        stopBeatTimer()
        val beatMs = (60_000.0 / bpm).toLong()
        var beat   = 0

        val runnable = object : Runnable {
            override fun run() {
                onBeatTick(beat)
                beat = (beat + 1) % beatsPerBar
                mainHandler.postDelayed(this, beatMs)
            }
        }
        beatRunnable = runnable
        mainHandler.post(runnable)
    }

    private fun stopBeatTimer() {
        beatRunnable?.let { mainHandler.removeCallbacks(it) }
        beatRunnable = null
    }

    // ─── Byte decoding ────────────────────────────────────────────────────────

    /**
     * Writes [bytes] to a temp file with [extension] and decodes via [AudioFileLoader].
     * Temp file is deleted after decode.
     */
    private suspend fun decodeBytes(bytes: ByteArray, extension: String): AudioFileLoader.DecodedAudio {
        val tmp = File(
            "${android.os.Environment.getExternalStorageState().let {
                android.app.ActivityThread.currentApplication()?.cacheDir?.absolutePath
                    ?: "/data/local/tmp"
            }}/metronome_${System.currentTimeMillis()}.$extension"
        )
        // Prefer the app's cache dir — use a simpler approach:
        return decodeFromTempFile(bytes, extension)
    }

    private suspend fun decodeFromTempFile(bytes: ByteArray, extension: String): AudioFileLoader.DecodedAudio {
        // Write to system temp directory
        val tmpFile = File.createTempFile("metronome_", ".$extension")
        try {
            tmpFile.writeBytes(bytes)
            return AudioFileLoader.decode(tmpFile.absolutePath)
        } finally {
            try { tmpFile.delete() } catch (_: Exception) {}
        }
    }
}
```

**Note on decodeBytes:** The two-method mess above is because `ActivityThread` is not accessible. Replace the `decodeBytes` + `decodeFromTempFile` pair with just `decodeFromTempFile` and call it directly:

Clean up the implementation — remove `decodeBytes` and keep only `decodeFromTempFile`. In `start(...)`, replace:
```kotlin
val click  = decodeBytes(clickBytes,  extension)
val accent = decodeBytes(accentBytes, extension)
```
with:
```kotlin
val click  = decodeFromTempFile(clickBytes,  extension)
val accent = decodeFromTempFile(accentBytes, extension)
```

**Step 4: Run tests**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop
./gradlew :flutter_gapless_loop:testDebugUnitTest 2>&1 | grep -E "PASSED|FAILED|ERROR|tests"
```

Expected: all `MetronomeEngineTest` tests pass, existing tests continue to pass.

**Step 5: Commit**

```bash
git add android/src/main/kotlin/com/fluttergaplessloop/MetronomeEngine.kt \
        android/src/test/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPluginTest.kt
git commit -m "feat(android): add MetronomeEngine — bar buffer + AudioTrack loop + Handler beat timer"
```

---

### Task 6: Android plugin bridge updates

**Files:**
- Modify: `android/src/main/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPlugin.kt`

**Step 1: Add metronome fields after `private val mainHandler = Handler(Looper.getMainLooper())`**

```kotlin
    private var metronomeEngine: MetronomeEngine? = null
    private lateinit var metronomeMethodChannel: MethodChannel
    private lateinit var metronomeEventChannel:  EventChannel
    private var metronomeEventSink: EventChannel.EventSink? = null
```

**Step 2: Register metronome channels in `onAttachedToEngine`**

After the existing channel registrations, add:

```kotlin
        metronomeMethodChannel = MethodChannel(binding.binaryMessenger, "flutter_gapless_loop/metronome")
        metronomeMethodChannel.setMethodCallHandler { call, result -> handleMetronomeCall(call, result) }

        metronomeEventChannel = EventChannel(binding.binaryMessenger, "flutter_gapless_loop/metronome/events")
        metronomeEventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                metronomeEventSink = events
            }
            override fun onCancel(arguments: Any?) {
                metronomeEventSink = null
            }
        })
```

**Step 3: Clean up in `onDetachedFromEngine`**

After `engine?.dispose()`, add:

```kotlin
        metronomeEngine?.dispose()
        metronomeEngine = null
        metronomeMethodChannel.setMethodCallHandler(null)
        metronomeEventChannel.setStreamHandler(null)
```

**Step 4: Add `handleMetronomeCall` method**

Add as a new private method in `FlutterGaplessLoopPlugin`:

```kotlin
    private fun handleMetronomeCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {

            "start" -> {
                val bpm         = call.argument<Double>("bpm")
                    ?: return result.error("INVALID_ARGS", "'bpm' required", null)
                val beatsPerBar = call.argument<Int>("beatsPerBar")
                    ?: return result.error("INVALID_ARGS", "'beatsPerBar' required", null)
                val clickBytes  = call.argument<ByteArray>("click")
                    ?: return result.error("INVALID_ARGS", "'click' required", null)
                val accentBytes = call.argument<ByteArray>("accent")
                    ?: return result.error("INVALID_ARGS", "'accent' required", null)
                val ext         = call.argument<String>("extension") ?: "wav"

                val eng = getOrCreateMetronomeEngine()
                eng.start(bpm, beatsPerBar, clickBytes, accentBytes, ext)
                result.success(null)
            }

            "setBpm" -> {
                val bpm = call.argument<Double>("bpm")
                    ?: return result.error("INVALID_ARGS", "'bpm' required", null)
                metronomeEngine?.setBpm(bpm)
                result.success(null)
            }

            "setBeatsPerBar" -> {
                val beatsPerBar = call.argument<Int>("beatsPerBar")
                    ?: return result.error("INVALID_ARGS", "'beatsPerBar' required", null)
                metronomeEngine?.setBeatsPerBar(beatsPerBar)
                result.success(null)
            }

            "stop" -> {
                metronomeEngine?.stop()
                result.success(null)
            }

            "dispose" -> {
                metronomeEngine?.dispose()
                metronomeEngine = null
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

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

**Step 5: Run Android tests to verify no regressions**

```bash
./gradlew :flutter_gapless_loop:testDebugUnitTest 2>&1 | tail -5
```

Expected: all tests pass.

**Step 6: Commit**

```bash
git add android/src/main/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPlugin.kt
git commit -m "feat(android): register metronome channels and wire MetronomeEngine to plugin bridge"
```

---

### Task 7: Example app _MetronomeCard widget

**Files:**
- Modify: `example/lib/main.dart`

**Step 1: Read current `main.dart` to find the correct insertion point**

```bash
wc -l example/lib/main.dart
grep -n "class _.*Card\|class _.*Widget\|class _Bpm" example/lib/main.dart | head -20
```

**Step 2: Add click/accent audio assets**

Create two minimal WAV files for demo purposes. The example app can generate them programmatically using a simple sine-burst helper, or load from assets. Use programmatic generation to avoid adding binary assets:

Add this helper at the top of `main.dart` (after imports):

```dart
/// Generates a short sine burst as raw WAV bytes.
/// [freq] Hz, [durationMs] milliseconds, [amplitude] 0.0–1.0.
Uint8List _generateSineWav({
  required double freq,
  required int durationMs,
  double amplitude = 0.8,
  int sampleRate = 44100,
}) {
  final numSamples = (sampleRate * durationMs / 1000).round();
  final pcm = Int16List(numSamples);
  for (var i = 0; i < numSamples; i++) {
    final t = i / sampleRate;
    // Apply 5 ms fade-in and 20 ms fade-out to avoid clicks
    double env = 1.0;
    if (i < sampleRate * 0.005) env = i / (sampleRate * 0.005);
    if (i > numSamples - sampleRate * 0.020) {
      env = (numSamples - i) / (sampleRate * 0.020);
    }
    pcm[i] = (amplitude * env * 32767 * math.sin(2 * math.pi * freq * t)).round().clamp(-32768, 32767);
  }

  // Build WAV header (44 bytes) + PCM data
  final dataBytes = pcm.buffer.asUint8List();
  final totalBytes = 44 + dataBytes.length;
  final header = ByteData(44)
    ..setUint32(0,  0x52494646, Endian.big)   // "RIFF"
    ..setUint32(4,  totalBytes - 8, Endian.little)
    ..setUint32(8,  0x57415645, Endian.big)   // "WAVE"
    ..setUint32(12, 0x666d7420, Endian.big)   // "fmt "
    ..setUint32(16, 16, Endian.little)         // chunk size
    ..setUint16(20, 1,  Endian.little)         // PCM
    ..setUint16(22, 1,  Endian.little)         // mono
    ..setUint32(24, sampleRate, Endian.little)
    ..setUint32(28, sampleRate * 2, Endian.little) // byte rate
    ..setUint16(32, 2, Endian.little)          // block align
    ..setUint16(34, 16, Endian.little)         // bits per sample
    ..setUint32(36, 0x64617461, Endian.big)   // "data"
    ..setUint32(40, dataBytes.length, Endian.little);

  return Uint8List.fromList([...header.buffer.asUint8List(), ...dataBytes]);
}
```

Add `import 'dart:math' as math;` and `import 'dart:typed_data';` to imports if not already present.

**Step 3: Add `_MetronomeCard` widget**

Find the last card/widget class in `main.dart` and add `_MetronomeCard` after it:

```dart
// ──────────────────────────────────────────────────────────────────────────────
// Metronome Card
// ──────────────────────────────────────────────────────────────────────────────

class _MetronomeCard extends StatefulWidget {
  const _MetronomeCard();

  @override
  State<_MetronomeCard> createState() => _MetronomeCardState();
}

class _MetronomeCardState extends State<_MetronomeCard> {
  final _metronome = MetronomePlayer();

  bool     _running      = false;
  double   _bpm          = 100.0;
  int      _beatsPerBar  = 4;
  int      _currentBeat  = -1;

  StreamSubscription<int>? _beatSub;

  static final _clickBytes  = _generateSineWav(freq: 880, durationMs: 40);
  static final _accentBytes = _generateSineWav(freq: 1760, durationMs: 50, amplitude: 1.0);

  @override
  void dispose() {
    _beatSub?.cancel();
    _metronome.dispose();
    super.dispose();
  }

  Future<void> _toggleMetronome() async {
    if (_running) {
      await _metronome.stop();
      _beatSub?.cancel();
      setState(() { _running = false; _currentBeat = -1; });
    } else {
      await _metronome.start(
        bpm: _bpm,
        beatsPerBar: _beatsPerBar,
        click: _clickBytes,
        accent: _accentBytes,
      );
      _beatSub = _metronome.beatStream.listen((beat) {
        setState(() => _currentBeat = beat);
      });
      setState(() => _running = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.all(8),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Metronome', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
            const SizedBox(height: 12),

            // Beat indicator dots
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(_beatsPerBar, (i) {
                final isActive = _running && i == _currentBeat;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 80),
                  margin: const EdgeInsets.symmetric(horizontal: 6),
                  width: 24, height: 24,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isActive
                        ? (i == 0 ? Colors.orange : Colors.blue)
                        : Colors.grey.shade300,
                  ),
                );
              }),
            ),
            const SizedBox(height: 16),

            // BPM row
            Row(
              children: [
                const Text('BPM: '),
                Expanded(
                  child: Slider(
                    value: _bpm,
                    min: 40, max: 240,
                    divisions: 200,
                    label: _bpm.round().toString(),
                    onChanged: (v) async {
                      setState(() => _bpm = v);
                      if (_running) await _metronome.setBpm(v);
                    },
                  ),
                ),
                SizedBox(width: 40, child: Text(_bpm.round().toString())),
              ],
            ),

            // Time signature row
            Row(
              children: [
                const Text('Beats/bar: '),
                const SizedBox(width: 8),
                DropdownButton<int>(
                  value: _beatsPerBar,
                  items: [2, 3, 4, 5, 6, 7]
                      .map((n) => DropdownMenuItem(value: n, child: Text('$n/4')))
                      .toList(),
                  onChanged: (v) async {
                    if (v == null) return;
                    setState(() { _beatsPerBar = v; _currentBeat = -1; });
                    if (_running) await _metronome.setBeatsPerBar(v);
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Start / Stop button
            Center(
              child: ElevatedButton.icon(
                onPressed: _toggleMetronome,
                icon: Icon(_running ? Icons.stop : Icons.play_arrow),
                label: Text(_running ? 'Stop' : 'Start'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _running ? Colors.red : Colors.green,
                  foregroundColor: Colors.white,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

**Step 4: Add `_MetronomeCard()` to the main scroll view**

Find where the other cards are added (e.g. `_BpmCard()`, `_PanCard()`) and append:

```dart
const _MetronomeCard(),
```

**Step 5: Commit**

```bash
git add example/lib/main.dart
git commit -m "feat(example): add _MetronomeCard with beat indicator dots, BPM slider, time signature dropdown"
```

---

### Task 8: Build verification and final commit

**Step 1: Run all Dart tests**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop
flutter test 2>&1 | tail -5
```

Expected: all tests pass.

**Step 2: Run Android unit tests**

```bash
./gradlew :flutter_gapless_loop:testDebugUnitTest 2>&1 | tail -5
```

Expected: all tests pass.

**Step 3: Run flutter analyze**

```bash
flutter analyze lib/ example/lib/ 2>&1 | tail -5
```

Expected: `No issues found!`

**Step 4: Build iOS example (no-codesign)**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop/example
flutter build ios --no-codesign 2>&1 | tail -5
```

Expected: `Build complete.`

**Step 5: Log final git history**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop
git log --oneline -8
```

---

## Summary of Changes

| File | Change |
|------|--------|
| `lib/src/metronome_player.dart` | **New.** `MetronomePlayer` Dart class |
| `lib/flutter_gapless_loop.dart` | Export `metronome_player.dart` |
| `test/metronome_player_test.dart` | **New.** 14 unit tests |
| `ios/Classes/MetronomeEngine.swift` | **New.** Bar buffer generation + AVAudioPlayerNode loop + DispatchSourceTimer |
| `ios/Classes/FlutterGaplessLoopPlugin.swift` | Register `"flutter_gapless_loop/metronome"` channels; add `MetronomeMethodHandler`, `MetronomeStreamHandler`, `getOrCreateMetronomeEngine` |
| `android/src/.../MetronomeEngine.kt` | **New.** Bar buffer generation + AudioTrack MODE_STATIC + Handler beat timer |
| `android/src/.../FlutterGaplessLoopPlugin.kt` | Register metronome channels; add `handleMetronomeCall`, `getOrCreateMetronomeEngine` |
| `android/src/test/.../FlutterGaplessLoopPluginTest.kt` | Add `MetronomeEngineTest` (4 unit tests) |
| `example/lib/main.dart` | Add `_MetronomeCard` + `_generateSineWav` helper |
