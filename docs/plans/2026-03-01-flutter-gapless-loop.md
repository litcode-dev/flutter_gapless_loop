# flutter_gapless_loop Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a production-ready Flutter iOS plugin that achieves true sample-accurate gapless audio looping using AVAudioEngine.

**Architecture:** AVAudioEngine + two AVAudioPlayerNodes (nodeA always active, nodeB only when crossfade > 0), connected through a mixer to the output. Four auto-selected modes (A–D) based on whether a loop region and/or crossfade are configured. Micro-fades applied once at load time for click prevention. The default mode (A) uses `scheduleBuffer(_:at:options: .loops)` which loops inside the hardware render thread — no callbacks, no gaps.

**Tech Stack:** Swift 5+, AVFoundation (AVAudioEngine, AVAudioPlayerNode, AVAudioPCMBuffer), Flutter method channel + event channel, Dart streams, file_picker (example app only).

---

## File Map

| # | File | Action |
|---|------|--------|
| 1 | `ios/Classes/LoopAudioEngine.swift` | **Create** |
| 2 | `ios/Classes/CrossfadeEngine.swift` | **Create** |
| 3 | `ios/Classes/FlutterGaplessLoopPlugin.swift` | **Replace** scaffold |
| 4 | `lib/flutter_gapless_loop.dart` | **Replace** scaffold |
| 5 | `lib/src/loop_audio_player.dart` | **Create** |
| 6 | `lib/src/loop_audio_state.dart` | **Create** |
| 7 | `example/lib/main.dart` | **Replace** scaffold |
| 8 | `ios/flutter_gapless_loop.podspec` | **Update** metadata |
| 9 | `pubspec.yaml` | **Update** (no new deps; plugin-only) |
| 10 | `example/pubspec.yaml` | **Update** (add file_picker) |

---

## Task 1: `lib/src/loop_audio_state.dart`

**Files:**
- Create: `lib/src/loop_audio_state.dart`

Defines all shared enums and value types used by both the public API and the platform bridge.

```dart
/// Playback state of the [LoopAudioPlayer].
enum PlayerState { idle, loading, ready, playing, paused, stopped, error }

/// Describes why audio route changed.
enum RouteChangeReason { headphonesUnplugged, categoryChange, unknown }

/// An audio route change event from the native layer.
class RouteChangeEvent {
  final RouteChangeReason reason;
  const RouteChangeEvent(this.reason);
}
```

No tests needed for pure data types. Commit after writing.

---

## Task 2: `lib/src/loop_audio_player.dart`

**Files:**
- Create: `lib/src/loop_audio_player.dart`

Full Dart player implementation using a `MethodChannel` for commands and an `EventChannel` for state/error/route events. All public methods are `Future<void>` calls to the native layer. State is exposed as `Stream<PlayerState>`.

Key details:
- Channel name: `"flutter_gapless_loop"`
- Event channel name: `"flutter_gapless_loop/events"`
- `load(String assetPath)` — resolves asset key via `rootBundle`, passes absolute path
- `loadFromFile(String filePath)` — passes path directly
- `stateStream` — filters event channel for `type == "stateChange"`
- `errorStream` — filters for `type == "error"`
- `routeChangeStream` — filters for `type == "routeChange"`
- `duration` getter — calls `getDuration` method, returns `Duration`
- `currentPosition` getter — calls `getCurrentPosition`, returns `double` seconds
- All method calls wrapped in `try/catch`, re-throw as descriptive exceptions
- `dispose()` calls native `dispose` then closes the event subscription

```dart
import 'dart:async';
import 'package:flutter/services.dart';
import 'loop_audio_state.dart';

class LoopAudioPlayer {
  static const _channel = MethodChannel('flutter_gapless_loop');
  static const _eventChannel = EventChannel('flutter_gapless_loop/events');

  late final Stream<Map<Object?, Object?>> _events;
  StreamSubscription<dynamic>? _eventSub;

  LoopAudioPlayer() {
    _events = _eventChannel
        .receiveBroadcastStream()
        .cast<Map<Object?, Object?>>();
  }

  Stream<PlayerState> get stateStream => _events
      .where((e) => e['type'] == 'stateChange')
      .map((e) => _parseState(e['state'] as String? ?? 'idle'));

  Stream<String> get errorStream => _events
      .where((e) => e['type'] == 'error')
      .map((e) => e['message'] as String? ?? 'Unknown error');

  Stream<RouteChangeEvent> get routeChangeStream => _events
      .where((e) => e['type'] == 'routeChange')
      .map((e) => RouteChangeEvent(_parseReason(e['reason'] as String? ?? '')));

  Future<void> load(String assetPath) async {
    // Resolve the asset path to an absolute file path
    final key = AssetManifest.defaultBundle != null ? assetPath : assetPath;
    await _channel.invokeMethod<void>('load', {'path': assetPath});
  }

  Future<void> loadFromFile(String filePath) async {
    await _channel.invokeMethod<void>('load', {'path': filePath});
  }

  Future<void> play() => _channel.invokeMethod<void>('play');
  Future<void> pause() => _channel.invokeMethod<void>('pause');
  Future<void> resume() => _channel.invokeMethod<void>('resume');
  Future<void> stop() => _channel.invokeMethod<void>('stop');

  Future<void> setLoopRegion(double start, double end) =>
      _channel.invokeMethod<void>('setLoopRegion', {'start': start, 'end': end});

  Future<void> setCrossfadeDuration(double seconds) =>
      _channel.invokeMethod<void>('setCrossfadeDuration', {'duration': seconds});

  Future<void> setVolume(double volume) =>
      _channel.invokeMethod<void>('setVolume', {'volume': volume});

  Future<void> seek(double seconds) =>
      _channel.invokeMethod<void>('seek', {'position': seconds});

  Future<Duration> get duration async {
    final secs = await _channel.invokeMethod<double>('getDuration') ?? 0.0;
    return Duration(milliseconds: (secs * 1000).round());
  }

  Future<double> get currentPosition async =>
      await _channel.invokeMethod<double>('getCurrentPosition') ?? 0.0;

  Future<void> dispose() async {
    await _eventSub?.cancel();
    await _channel.invokeMethod<void>('dispose');
  }

  PlayerState _parseState(String s) {
    switch (s) {
      case 'loading': return PlayerState.loading;
      case 'ready':   return PlayerState.ready;
      case 'playing': return PlayerState.playing;
      case 'paused':  return PlayerState.paused;
      case 'stopped': return PlayerState.stopped;
      case 'error':   return PlayerState.error;
      default:        return PlayerState.idle;
    }
  }

  RouteChangeReason _parseReason(String r) {
    switch (r) {
      case 'headphonesUnplugged': return RouteChangeReason.headphonesUnplugged;
      case 'categoryChange':      return RouteChangeReason.categoryChange;
      default:                    return RouteChangeReason.unknown;
    }
  }
}
```

**Commit after writing.**

---

## Task 3: `lib/flutter_gapless_loop.dart`

**Files:**
- Modify: `lib/flutter_gapless_loop.dart` (replace scaffold entirely)

This is the public-facing barrel file. Export `LoopAudioPlayer`, `PlayerState`, `RouteChangeEvent`, `RouteChangeReason`.

```dart
/// Flutter plugin for true sample-accurate gapless audio looping on iOS.
///
/// Primary entry point is [LoopAudioPlayer].
library flutter_gapless_loop;

export 'src/loop_audio_player.dart';
export 'src/loop_audio_state.dart';
```

Delete the old scaffold imports (`flutter_gapless_loop_platform_interface.dart`, `flutter_gapless_loop_method_channel.dart`). Those files can be deleted or left — they will no longer be imported.

**Commit after writing.**

---

## Task 4: `pubspec.yaml` + `example/pubspec.yaml`

**Files:**
- Modify: `pubspec.yaml`
- Modify: `example/pubspec.yaml`

`pubspec.yaml` changes:
- Update description to real description
- Add homepage and repository fields
- No new runtime dependencies needed (plugin uses platform channels only)
- Remove the android platform entry from the flutter.plugin section (iOS only)

`example/pubspec.yaml` changes:
- Add `file_picker: ^8.0.0` to dependencies

**Commit after writing both.**

---

## Task 5: `ios/flutter_gapless_loop.podspec`

**Files:**
- Modify: `ios/flutter_gapless_loop.podspec`

Changes:
- Real summary and description
- `s.platform = :ios, '12.0'` (spec says 12.0+)
- Add `s.frameworks = 'AVFoundation'`
- Keep `s.swift_version = '5.0'`

**Commit after writing.**

---

## Task 6: `ios/Classes/LoopAudioEngine.swift`

**Files:**
- Create: `ios/Classes/LoopAudioEngine.swift`

This is the most complex file. Complete implementation of the audio engine.

### Internal state machine

```
EngineState: idle → loading → ready → playing ↔ paused → stopped → idle
                                              └──────────────────────→ error
```

### PlaybackMode (internal enum)

```swift
private enum PlaybackMode {
    case modeA  // full file, no crossfade (.loops on nodeA)
    case modeB  // loop region, no crossfade (.loops on nodeA with sub-buffer)
    case modeC  // full file, crossfade enabled
    case modeD  // loop region + crossfade
}
```

### Properties

```swift
// Engine infrastructure
private let engine = AVAudioEngine()
private let nodeA = AVAudioPlayerNode()
private let nodeB = AVAudioPlayerNode()   // only connected when crossfade > 0
private let mixerNode = AVAudioMixerNode()

// Serial queue — ALL engine operations on this queue
private let audioQueue = DispatchQueue(label: "com.fluttergaplessloop.audioqueue", qos: .userInteractive)

// Buffer hierarchy
private var originalBuffer: AVAudioPCMBuffer?   // full file, micro-fade applied
private var loopBuffer: AVAudioPCMBuffer?        // sub-buffer for loop region
private var crossfadeBuffer: AVAudioPCMBuffer?  // tail portion for crossfade

// Configuration
private var crossfadeDuration: TimeInterval = 0.0
private var loopStart: TimeInterval = 0.0
private var loopEnd: TimeInterval = 0.0
private var fileDuration: TimeInterval = 0.0

// Current mode
private var playbackMode: PlaybackMode = .modeA

// State
private var _state: EngineState = .idle
```

### `loadFile(url:)` implementation steps

1. Set state to `.loading`
2. Open `AVAudioFile(forReading: url)`
3. Allocate `AVAudioPCMBuffer` for full file: `AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))`
4. `try file.read(into: buffer)`
5. Run micro-fade on buffer in-place (see below)
6. Assign to `originalBuffer`
7. Store `fileDuration = Double(file.length) / file.processingFormat.sampleRate`
8. Store `loopStart = 0.0`, `loopEnd = fileDuration`
9. Setup engine if not running (connect nodes, start engine)
10. Set state to `.ready`

### Micro-fade implementation (exact)

```swift
private func applyMicroFade(to buffer: AVAudioPCMBuffer) {
    let format = buffer.format
    let channelCount = Int(format.channelCount)
    let totalFrames = Int(buffer.frameLength)
    // 5ms at the buffer's own sample rate
    let fadeLengthFrames = min(Int(format.sampleRate * 0.005), totalFrames / 2)

    guard let channelData = buffer.floatChannelData else { return }

    for ch in 0..<channelCount {
        let data = channelData[ch]
        // Fade in: first fadeLengthFrames
        for i in 0..<fadeLengthFrames {
            let gain = Float(i) / Float(fadeLengthFrames)
            data[i] *= gain
        }
        // Fade out: last fadeLengthFrames
        for i in 0..<fadeLengthFrames {
            let gain = Float(i) / Float(fadeLengthFrames)
            data[totalFrames - 1 - i] *= gain
        }
    }
}
```

### Engine graph setup (called once)

```swift
private func setupEngineIfNeeded() throws {
    guard !engine.isRunning else { return }

    engine.attach(nodeA)
    engine.attach(mixerNode)

    let format = originalBuffer!.format
    engine.connect(nodeA, to: mixerNode, format: format)
    engine.connect(mixerNode, to: engine.mainMixerNode, format: format)

    // nodeB is only attached/connected when crossfadeDuration > 0
    // (done lazily in setupCrossfade())

    try engine.start()
}
```

### `play()` — mode selection

```swift
func play() {
    audioQueue.async { [weak self] in
        guard let self, self._state == .ready || self._state == .stopped else { return }
        self.scheduleForCurrentMode()
        self.nodeA.play()
        self.setState(.playing)
    }
}

private func scheduleForCurrentMode() {
    switch playbackMode {
    case .modeA:
        guard let buf = originalBuffer else { return }
        nodeA.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
    case .modeB:
        guard let buf = loopBuffer else { return }
        nodeA.scheduleBuffer(buf, at: nil, options: .loops, completionHandler: nil)
    case .modeC:
        scheduleCrossfade(buffer: originalBuffer!)
    case .modeD:
        scheduleCrossfade(buffer: loopBuffer!)
    }
}
```

### `setLoopRegion(start:end:)` — extract sub-buffer

```swift
func setLoopRegion(start: TimeInterval, end: TimeInterval) throws {
    // Validate
    guard start >= 0, end > start, end <= fileDuration else {
        throw LoopEngineError.invalidLoopRegion(start: start, end: end)
    }
    // Store
    loopStart = start
    loopEnd = end
    // Extract sub-buffer
    let subBuffer = try extractSubBuffer(from: originalBuffer!, start: start, end: end)
    applyMicroFade(to: subBuffer)
    alignToZeroCrossings(buffer: subBuffer)
    loopBuffer = subBuffer
    // Update mode
    playbackMode = crossfadeDuration > 0 ? .modeD : .modeB
    // Reschedule if playing
    if _state == .playing {
        nodeA.stop()
        scheduleForCurrentMode()
        nodeA.play()
    }
}
```

### Sub-buffer extraction (pointer arithmetic)

```swift
private func extractSubBuffer(from source: AVAudioPCMBuffer, start: TimeInterval, end: TimeInterval) throws -> AVAudioPCMBuffer {
    let sampleRate = source.format.sampleRate
    let startFrame = AVAudioFrameCount(start * sampleRate)
    let endFrame   = AVAudioFrameCount(end   * sampleRate)
    let frameCount = endFrame - startFrame

    guard frameCount > 0,
          let sub = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: frameCount),
          let srcData = source.floatChannelData,
          let dstData = sub.floatChannelData else {
        throw LoopEngineError.bufferReadFailed
    }

    let channelCount = Int(source.format.channelCount)
    for ch in 0..<channelCount {
        // Pointer arithmetic: advance source pointer by startFrame
        let src = srcData[ch].advanced(by: Int(startFrame))
        let dst = dstData[ch]
        dst.initialize(from: src, count: Int(frameCount))
    }
    sub.frameLength = frameCount
    return sub
}
```

### Zero-crossing alignment

```swift
private func alignToZeroCrossings(buffer: AVAudioPCMBuffer) {
    // Scan first 10ms for first zero-crossing (sign change), then last 10ms
    let sampleRate = buffer.format.sampleRate
    let windowFrames = Int(sampleRate * 0.010)  // 10ms window
    let totalFrames  = Int(buffer.frameLength)
    guard let data = buffer.floatChannelData else { return }
    let ch0 = data[0]

    // Find zero crossing near start
    var fadeStart = 0
    for i in 1..<min(windowFrames, totalFrames) {
        if ch0[i - 1] <= 0 && ch0[i] >= 0 {
            fadeStart = i
            break
        }
    }

    // Find zero crossing near end
    var fadeEnd = totalFrames - 1
    for i in stride(from: totalFrames - 1, through: max(totalFrames - windowFrames, 1), by: -1) {
        if ch0[i] <= 0 && ch0[i - 1] >= 0 {
            fadeEnd = i
            break
        }
    }

    // If no zero-crossing found within window, micro-fade has already been applied — nothing to do.
    // If found, zero out samples before startZC and after endZC for a clean join
    let channelCount = Int(buffer.format.channelCount)
    for ch in 0..<channelCount {
        let d = data[ch]
        for i in 0..<fadeStart { d[i] = 0 }
        for i in fadeEnd..<totalFrames { d[i] = 0 }
    }
}
```

### `setCrossfadeDuration(_:)`

```swift
func setCrossfadeDuration(_ duration: TimeInterval) {
    audioQueue.async { [weak self] in
        guard let self else { return }
        self.crossfadeDuration = duration
        if duration > 0 {
            // Attach nodeB if not already attached
            if !self.engine.attachedNodes.contains(self.nodeB) {
                self.engine.attach(self.nodeB)
                let format = self.originalBuffer!.format
                self.engine.connect(self.nodeB, to: self.mixerNode, format: format)
            }
            self.playbackMode = self.loopBuffer != nil ? .modeD : .modeC
        } else {
            self.playbackMode = self.loopBuffer != nil ? .modeB : .modeA
        }
    }
}
```

### Crossfade scheduling (Modes C and D)

Pre-build crossfade ramp arrays at `setCrossfadeDuration()` call time (not at play time). During playback use a completion callback to know when to start nodeB fade-in and nodeA fade-out.

Equal-power: `fadeOut[i] = cos(t * π/2)`, `fadeIn[i] = sin(t * π/2)` where `t = i / rampLength`.

**Implementation note:** For Modes C and D, use a timer-free approach: schedule the primary buffer with `.loops`, and separately schedule a short crossfade buffer on nodeB timed to the loop boundary using `AVAudioTime`. Compute the loop boundary time from `nodeA.lastRenderTime` and the buffer frame count.

### `pause()`, `resume()`, `stop()`

```swift
func pause() {
    audioQueue.async { [weak self] in
        guard let self, self._state == .playing else { return }
        self.nodeA.pause()
        self.nodeB.pause()
        self.setState(.paused)
    }
}

func resume() {
    audioQueue.async { [weak self] in
        guard let self, self._state == .paused else { return }
        self.nodeA.play()
        if self.crossfadeDuration > 0 { self.nodeB.play() }
        self.setState(.playing)
    }
}

func stop() {
    audioQueue.async { [weak self] in
        guard let self else { return }
        self.nodeA.stop()
        self.nodeB.stop()
        self.setState(.stopped)
    }
}
```

### `seek(to:)` — note: only valid in Modes A and B (.loops)

In modes with `.loops`, seeking requires stopping the node, rescheduling from the new offset, then replaying. Extract a sub-buffer from `seekPosition` to end, schedule with `.loops` — this isn't perfect but is the only approach without CADisplayLink timers. Document this limitation clearly.

```swift
func seek(to time: TimeInterval) throws {
    guard time >= 0, time < fileDuration else {
        throw LoopEngineError.seekOutOfBounds(requested: time, duration: fileDuration)
    }
    audioQueue.async { [weak self] in
        guard let self else { return }
        let wasPlaying = self._state == .playing
        self.nodeA.stop()
        // Reschedule from seek position — full loop still from loopStart/loopEnd
        // Seek only sets the start position for the current playthrough;
        // next loop iteration will start from loopStart normally.
        let activeBuffer = self.loopBuffer ?? self.originalBuffer!
        let sampleRate = activeBuffer.format.sampleRate
        let seekFrame = AVAudioFramePosition(time * sampleRate)
        let frameLength = Int(activeBuffer.frameLength)
        let clampedSeek = min(Int(seekFrame), frameLength - 1)
        // Schedule remaining frames to end first, then reschedule with .loops
        if let remaining = try? self.extractSubBuffer(from: activeBuffer, start: time, end: self.loopEnd) {
            self.nodeA.scheduleBuffer(remaining, at: nil, options: [], completionHandler: { [weak self] in
                guard let self else { return }
                self.audioQueue.async {
                    self.nodeA.scheduleBuffer(activeBuffer, at: nil, options: .loops, completionHandler: nil)
                }
            })
        }
        if wasPlaying { self.nodeA.play() }
    }
}
```

### Audio Session + Interruption handling

```swift
private func configureAudioSession() throws {
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, mode: .default)
    try session.setActive(true)

    NotificationCenter.default.addObserver(
        self,
        selector: #selector(handleInterruption(_:)),
        name: AVAudioSession.interruptionNotification,
        object: session
    )
    NotificationCenter.default.addObserver(
        self,
        selector: #selector(handleRouteChange(_:)),
        name: AVAudioSession.routeChangeNotification,
        object: session
    )
}

@objc private func handleInterruption(_ notification: Notification) {
    guard let info = notification.userInfo,
          let typeValue = info[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: typeValue) else { return }

    audioQueue.async { [weak self] in
        guard let self else { return }
        switch type {
        case .began:
            if self._state == .playing {
                self.nodeA.pause()
                self.nodeB.pause()
                self.setState(.paused)
            }
        case .ended:
            if let optValue = info[AVAudioSessionInterruptionOptionKey] as? UInt {
                let opts = AVAudioSession.InterruptionOptions(rawValue: optValue)
                if opts.contains(.shouldResume), self._state == .paused {
                    try? self.engine.start()
                    self.nodeA.play()
                    if self.crossfadeDuration > 0 { self.nodeB.play() }
                    self.setState(.playing)
                }
            }
        @unknown default: break
        }
    }
}

@objc private func handleRouteChange(_ notification: Notification) {
    guard let info = notification.userInfo,
          let reasonValue = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
          let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else { return }

    audioQueue.async { [weak self] in
        guard let self else { return }
        if reason == .oldDeviceUnavailable {
            self.nodeA.pause()
            self.nodeB.pause()
            self.setState(.paused)
            DispatchQueue.main.async { [weak self] in
                self?.onRouteChange?("headphonesUnplugged")
            }
        }
    }
}
```

### `currentTime` computed property

```swift
var currentTime: TimeInterval {
    guard let nodeTime = nodeA.lastRenderTime,
          let playerTime = nodeA.playerTime(forNodeTime: nodeTime),
          let buf = loopBuffer ?? originalBuffer else { return 0 }
    let sampleRate = buf.format.sampleRate
    let frame = playerTime.sampleTime
    // Wrap to loop region
    let loopFrames = Int64(buf.frameLength)
    let wrappedFrame = frame % loopFrames
    return loopStart + Double(wrappedFrame) / sampleRate
}
```

### `dispose()`

```swift
func dispose() {
    audioQueue.async { [weak self] in
        guard let self else { return }
        self.nodeA.stop()
        self.nodeB.stop()
        self.engine.stop()
        NotificationCenter.default.removeObserver(self)
        self.originalBuffer = nil
        self.loopBuffer = nil
        self.crossfadeBuffer = nil
        self.setState(.idle)
    }
}
```

### os_log usage

```swift
import os.log
private let logger = Logger(subsystem: "com.fluttergaplessloop", category: "LoopAudioEngine")
// Use: logger.debug("..."), logger.error("..."), logger.info("...")
```

**No print() anywhere.**

**Commit after writing.**

---

## Task 7: `ios/Classes/CrossfadeEngine.swift`

**Files:**
- Create: `ios/Classes/CrossfadeEngine.swift`

A focused helper that owns the equal-power crossfade ramp math. Used by `LoopAudioEngine` when in Mode C or D.

```swift
/// Pre-computed equal-power crossfade ramps.
/// All properties are read-only after initialization.
public struct CrossfadeRamp {
    /// Fade-out gain values: cos(t * π/2) where t goes from 0→1
    public let fadeOut: [Float]
    /// Fade-in gain values: sin(t * π/2) where t goes from 0→1
    public let fadeIn: [Float]
    /// Number of frames in the ramp
    public let frameCount: Int

    /// Build ramps for the given duration and sample rate.
    /// - Parameters:
    ///   - duration: Crossfade duration in seconds (> 0)
    ///   - sampleRate: Audio sample rate in Hz
    public init(duration: TimeInterval, sampleRate: Double) {
        let frames = Int(duration * sampleRate)
        var out = [Float](repeating: 0, count: frames)
        var in_ = [Float](repeating: 0, count: frames)
        for i in 0..<frames {
            let t = Float(i) / Float(frames)
            out[i] = Foundation.cos(t * .pi / 2)
            in_[i] = Foundation.sin(t * .pi / 2)
        }
        self.fadeOut = out
        self.fadeIn  = in_
        self.frameCount = frames
    }
}

/// Applies pre-computed crossfade ramps to two PCM buffers in-place.
public enum CrossfadeEngine {

    /// Apply fadeOut ramp to the tail of `primary` and fadeIn ramp to the head of `secondary`.
    /// Both buffers must have the same format and at least `ramp.frameCount` frames.
    public static func apply(
        ramp: CrossfadeRamp,
        primary: AVAudioPCMBuffer,
        secondary: AVAudioPCMBuffer
    ) {
        let channelCount = Int(primary.format.channelCount)
        let frames = min(ramp.frameCount, Int(primary.frameLength), Int(secondary.frameLength))
        let primaryLen = Int(primary.frameLength)

        guard let pData = primary.floatChannelData,
              let sData = secondary.floatChannelData else { return }

        for ch in 0..<channelCount {
            let p = pData[ch]
            let s = sData[ch]
            for i in 0..<frames {
                // Apply fade-out to tail of primary
                p[primaryLen - frames + i] *= ramp.fadeOut[i]
                // Apply fade-in to head of secondary
                s[i] *= ramp.fadeIn[i]
            }
        }
    }
}
```

**Commit after writing.**

---

## Task 8: `ios/Classes/FlutterGaplessLoopPlugin.swift`

**Files:**
- Modify: `ios/Classes/FlutterGaplessLoopPlugin.swift` (replace scaffold)

Responsibilities:
1. Register both `FlutterMethodChannel` and `FlutterEventChannel`
2. Instantiate `LoopAudioEngine` and wire up its callbacks to the event channel sink
3. Route all method channel calls to the engine
4. Return `FlutterError` for engine errors, `FlutterMethodNotImplemented` for unknown methods
5. All result callbacks dispatched on `DispatchQueue.main`

```swift
import Flutter
import UIKit
import AVFoundation
import os.log

public class FlutterGaplessLoopPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    private var engine: LoopAudioEngine?
    private var eventSink: FlutterEventSink?
    private let logger = Logger(subsystem: "com.fluttergaplessloop", category: "Plugin")

    public static func register(with registrar: FlutterPluginRegistrar) {
        let methodChannel = FlutterMethodChannel(
            name: "flutter_gapless_loop",
            binaryMessenger: registrar.messenger()
        )
        let eventChannel = FlutterEventChannel(
            name: "flutter_gapless_loop/events",
            binaryMessenger: registrar.messenger()
        )

        let instance = FlutterGaplessLoopPlugin()
        registrar.addMethodCallDelegate(instance, channel: methodChannel)
        eventChannel.setStreamHandler(instance)
    }

    // MARK: - FlutterStreamHandler

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        setupEngine()
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }

    // MARK: - Engine Setup

    private func setupEngine() {
        let eng = LoopAudioEngine()
        eng.onStateChange = { [weak self] state in
            DispatchQueue.main.async {
                self?.eventSink?(["type": "stateChange", "state": state.rawValue])
            }
        }
        eng.onError = { [weak self] error in
            DispatchQueue.main.async {
                self?.eventSink?(["type": "error", "message": error.localizedDescription])
            }
        }
        eng.onRouteChange = { [weak self] reason in
            DispatchQueue.main.async {
                self?.eventSink?(["type": "routeChange", "reason": reason])
            }
        }
        self.engine = eng
    }

    // MARK: - Method Channel

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let eng = engine else {
            result(FlutterError(code: "ENGINE_NOT_READY", message: "Engine not initialized", details: nil))
            return
        }

        let args = call.arguments as? [String: Any]

        switch call.method {
        case "load":
            guard let path = args?["path"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "path required", details: nil))
                return
            }
            let url = URL(fileURLWithPath: path)
            do {
                try eng.loadFile(url: url)
                DispatchQueue.main.async { result(nil) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "LOAD_FAILED", message: error.localizedDescription, details: nil))
                }
            }

        case "play":
            eng.play()
            DispatchQueue.main.async { result(nil) }

        case "pause":
            eng.pause()
            DispatchQueue.main.async { result(nil) }

        case "resume":
            eng.resume()
            DispatchQueue.main.async { result(nil) }

        case "stop":
            eng.stop()
            DispatchQueue.main.async { result(nil) }

        case "setLoopRegion":
            guard let start = args?["start"] as? Double,
                  let end   = args?["end"]   as? Double else {
                result(FlutterError(code: "INVALID_ARGS", message: "start and end required", details: nil))
                return
            }
            do {
                try eng.setLoopRegion(start: start, end: end)
                DispatchQueue.main.async { result(nil) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "INVALID_REGION", message: error.localizedDescription, details: nil))
                }
            }

        case "setCrossfadeDuration":
            guard let dur = args?["duration"] as? Double else {
                result(FlutterError(code: "INVALID_ARGS", message: "duration required", details: nil))
                return
            }
            eng.setCrossfadeDuration(dur)
            DispatchQueue.main.async { result(nil) }

        case "setVolume":
            guard let vol = args?["volume"] as? Double else {
                result(FlutterError(code: "INVALID_ARGS", message: "volume required", details: nil))
                return
            }
            eng.setVolume(Float(vol))
            DispatchQueue.main.async { result(nil) }

        case "seek":
            guard let pos = args?["position"] as? Double else {
                result(FlutterError(code: "INVALID_ARGS", message: "position required", details: nil))
                return
            }
            do {
                try eng.seek(to: pos)
                DispatchQueue.main.async { result(nil) }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "SEEK_FAILED", message: error.localizedDescription, details: nil))
                }
            }

        case "getDuration":
            DispatchQueue.main.async { result(eng.duration) }

        case "getCurrentPosition":
            DispatchQueue.main.async { result(eng.currentTime) }

        case "dispose":
            eng.dispose()
            self.engine = nil
            DispatchQueue.main.async { result(nil) }

        default:
            result(FlutterMethodNotImplemented)
        }
    }
}
```

**Note:** `EngineState` needs a `rawValue: String` for the event payload. Update `EngineState` enum to be `String` backed:

```swift
public enum EngineState: String {
    case idle, loading, ready, playing, paused, stopped, error
}
```

**Commit after writing.**

---

## Task 9: `example/lib/main.dart`

**Files:**
- Modify: `example/lib/main.dart` (replace scaffold)

Full example app demonstrating all plugin features. Uses `file_picker` for WAV file selection.

UI Layout:
```
AppBar: "Gapless Loop Demo"
Body (Column, scrollable):
  ┌─────────────────────────────────┐
  │ [Pick WAV File]  state: idle    │
  ├─────────────────────────────────┤
  │ ████████░░░░░░░░  0.0s / 4.2s  │  ← LinearProgressIndicator
  ├─────────────────────────────────┤
  │  [▶ Play]  [⏸ Pause]  [■ Stop] │
  ├─────────────────────────────────┤
  │ Loop Start: 0.0s  ─────●───    │
  │ Loop End:   4.2s  ───────●─    │
  ├─────────────────────────────────┤
  │ Crossfade: 0ms    ●────────    │
  ├─────────────────────────────────┤
  │ Volume: 1.0       ──────────●  │
  └─────────────────────────────────┘
```

Controls disabled when state is `idle` or `loading`.
Errors shown via `ScaffoldMessenger.of(context).showSnackBar(...)`.

Position update: use `Timer.periodic(Duration(milliseconds: 200), ...)` to poll `player.currentPosition` while playing.

**Commit after writing.**

---

## Task 10: Final verification

**Steps:**
1. Run `flutter analyze` in project root — must show zero issues
2. Run `flutter analyze` in `example/` — must show zero issues
3. In `example/ios/`: run `pod install` — must succeed with no warnings about missing frameworks
4. Confirm `ios/Classes/` contains exactly: `FlutterGaplessLoopPlugin.swift`, `LoopAudioEngine.swift`, `CrossfadeEngine.swift`
5. Confirm `lib/src/` contains: `loop_audio_player.dart`, `loop_audio_state.dart`
6. Confirm `lib/flutter_gapless_loop.dart` exports both src files

**Commit:** `feat: complete flutter_gapless_loop iOS plugin implementation`

---

## Technical Explanation Notes (to include as comments in code)

After all files are generated, add a `docs/ARCHITECTURE.md` with:

1. **Why AVPlayer fails at sample-accuracy** — AVPlayer uses a decode-ahead buffer queue and the `seek()` API operates on presentation timestamps, not sample frames. The decoder pipeline introduces 20–200ms of latency. Loop boundaries require a seek + rebuffer cycle which takes multiple frames to settle.

2. **Why `.loops` is truly gapless** — `AVAudioPlayerNode.scheduleBuffer(_:at:options: .loops)` registers the buffer with the render tree at the `AVAudioEngine` level. The hardware render callback (running at 256-frame blocks at 44100Hz = 5.8ms per block) sees the loop flag and wraps `sampleTime` to 0 at the end of the buffer within the same render cycle. No Objective-C message passing, no thread handoff, no scheduler latency.

3. **Why the micro-fade is inaudible** — 5ms @ 44100Hz = 220 samples. Human auditory temporal resolution for click detection is ~1ms. A linear ramp over 220 samples is well below the auditory integration window for tonal content. The fade trades an inaudible amplitude taper for elimination of a full-amplitude discontinuity at the loop boundary.

4. **Sub-buffer extraction** — `floatChannelData` returns a pointer-to-pointer. Advancing the inner pointer by `startFrame` elements and `memcpy`-ing `frameCount` floats is O(n) in frame count, allocation is O(1). Zero-crossing alignment scans ±10ms around the boundary for the nearest zero-amplitude crossing to minimize discontinuity energy.

5. **Equal-power crossfade math** — `cos²(θ) + sin²(θ) = 1` guarantees that the sum of the two node signals at every point in the crossfade equals exactly 1.0 in power terms. This prevents the perceived "dip" in loudness that linear crossfades cause at the midpoint.

6. **Mode selection state machine** — The engine starts in Mode A. Calling `setLoopRegion()` transitions to Mode B (or D if crossfade is active). Calling `setCrossfadeDuration(> 0)` transitions to Mode C (or D if loop region is set). Calling `setCrossfadeDuration(0)` transitions back to A or B. The mode is evaluated at every `scheduleForCurrentMode()` call.
