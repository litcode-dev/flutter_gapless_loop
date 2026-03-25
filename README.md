# flutter_gapless_loop

A Flutter plugin for true sample-accurate gapless audio looping on iOS, Android, macOS, and Windows. Zero-gap, zero-click loop playback for music production apps, with BPM and time signature detection, a built-in sample-accurate metronome, pitch-preserving speed control, and stereo panning.

## Features

- Sample-accurate looping with no audible gap or click at the loop boundary
- **Play-once mode** — `play({bool loop = true})`: pass `loop: false` to play through once, then emit `PlayerState.stopped`
- Configurable loop region (start and end points in seconds)
- **A-B loop points** — bookmark playback positions as loop boundaries on the fly
- Optional crossfade between loop iterations (equal-power)
- **3-band EQ** — low shelf, peak, high shelf (±12 dB each); iOS, macOS, Android, Windows
- **Cutoff filter** — low-pass or high-pass biquad with configurable frequency and resonance; iOS, macOS, Android, Windows
- **Reverb** — 7 built-in room presets with wet/dry mix; iOS, macOS
- **Compressor** — dynamic range compression with threshold, makeup gain, attack, release; iOS, macOS
- **Pitch shift** — ±24 semitones, independent of playback rate; iOS, macOS
- **Volume fades** — native 100 Hz fade ramps (`fadeTo`, `fadeIn`, `fadeOut`); iOS, macOS
- **Effects preset** — snapshot and restore the full DSP chain atomically
- Automatic BPM/tempo detection after every load
- Automatic time signature detection (beats per bar + bar timestamps)
- Real-time amplitude metering via `amplitudeStream` (RMS + peak, ~20 Hz)
- **FFT spectrum analyser** — 256 normalised magnitude bins at ~20 Hz; iOS, macOS
- Load audio from an asset, a file path, raw bytes, or a URL
- **Export to file** — render the current audio with all DSP applied to WAV; iOS, macOS
- **Now Playing info** — iOS lock screen / Control Center integration
- **Count-in** — start playback after N bars of the running metronome
- Built-in `MetronomePlayer` — sample-accurate click track with accent, runs simultaneously with the loop player
- Per-instance volume and pan on both `LoopAudioPlayer` and `MetronomePlayer`
- `LoopAudioMaster` — static group-bus fader for all live `LoopAudioPlayer` instances
- `MetronomeMaster` — static group-bus fader for all live `MetronomePlayer` instances
- Pitch-preserving playback rate control (time-stretching)
- Stereo pan control
- Volume control
- Seek support
- State and error streams for reactive UI
- Audio route change events (e.g. headphones unplugged)

## Platform support

| Platform | Support | Engine |
|----------|---------|--------|
| iOS      | ✅      | AVAudioEngine + AVAudioUnitTimePitch (iOS 14.0+) |
| Android  | ✅      | AudioTrack (API 21+) |
| macOS    | ✅      | AVAudioEngine + AVAudioUnitTimePitch (macOS 11.0+) |
| Windows  | ✅      | XAudio2 2.9 + MediaFoundation (Windows 10+) |
| Linux    | ✅      | miniaudio 0.11.21 (PipeWire / PulseAudio / ALSA) + libcurl (Ubuntu 20.04+) |

## Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  flutter_gapless_loop: ^0.0.9
```

Then run:

```sh
flutter pub get
```

### Swift Package Manager

On Flutter 3.27+, Swift Package Manager is used automatically for iOS and macOS — no extra steps required. CocoaPods is supported as a fallback for apps that require it.

## Quick start

```dart
import 'package:flutter_gapless_loop/flutter_gapless_loop.dart';

final player = LoopAudioPlayer();

// Load and play
await player.load('assets/loop.wav');
await player.play();

// Dispose when done
await player.dispose();
```

---

## Multiple instances

You can create any number of `LoopAudioPlayer` or `MetronomePlayer` instances and run them concurrently — each is fully independent with no cross-talk:

```dart
final bass   = LoopAudioPlayer();
final drums  = LoopAudioPlayer();
final metro1 = MetronomePlayer();
final metro2 = MetronomePlayer();

await bass.loadFromFile('/path/to/bass.wav');
await drums.loadFromFile('/path/to/drums.wav');
await bass.play();
await drums.play();

await metro1.start(bpm: 120, beatsPerBar: 4, click: click, accent: accent);
await metro2.start(bpm: 90,  beatsPerBar: 3, click: click, accent: accent);

// Each player's event streams are isolated
bass.stateStream.listen((s)  => print('bass: $s'));
drums.bpmStream.listen((r)   => print('drums bpm: ${r.bpm}'));
metro1.beatStream.listen((b) => print('metro1 beat: $b'));
metro2.beatStream.listen((b) => print('metro2 beat: $b'));

// Independent lifecycle — disposing one does not affect the others
await bass.dispose();
await metro1.dispose();
```

---

## LoopAudioPlayer

### Loading audio

**From a Flutter asset** (recommended — works in release builds):

```dart
await player.load('assets/loop.wav');
```

**From an absolute file system path** (e.g. from a file picker):

```dart
await player.loadFromFile('/path/to/loop.wav');
```

**From raw bytes** (e.g. downloaded or generated in memory):

```dart
final Uint8List bytes = await someSource.fetchBytes();
await player.loadFromBytes(bytes);                         // defaults to .wav
await player.loadFromBytes(bytes, extension: 'mp3');       // explicit format hint
```

**From a URL** (downloaded natively, then loaded):

```dart
await player.loadFromUrl(Uri.parse('https://example.com/loop.wav'));
```

The download uses the platform networking stack — `URLSession` on iOS and `HttpURLConnection` on Android. No third-party HTTP package is required.

All four methods decode on a background thread. Subscribe to `stateStream` to know when the file is ready.

### Playback control

```dart
await player.play();              // start looping from the beginning (default)
await player.play(loop: false);   // play once, then emit PlayerState.stopped
await player.pause();             // pause (preserves position)
await player.resume();            // resume from the paused position
await player.stop();              // stop and reset position
```

### Volume

```dart
await player.setVolume(0.8); // 0.0 (silent) → 1.0 (full volume)
```

Values outside `[0.0, 1.0]` are silently clamped.

### Stereo pan

```dart
await player.setPan(-1.0); // full left
await player.setPan(0.0);  // centre (default)
await player.setPan(1.0);  // full right
```

Values outside `[-1.0, 1.0]` are silently clamped. Takes effect immediately and persists across loads.

### Playback rate (pitch-preserving speed)

```dart
await player.setPlaybackRate(1.0);  // normal speed (default)
await player.setPlaybackRate(2.0);  // double speed
await player.setPlaybackRate(0.5);  // half speed
```

- Uses `AVAudioUnitTimePitch` on iOS and `PlaybackParams.setSpeed` on Android (API 23+; no-op on older devices).
- Values outside `[0.25, 4.0]` are clamped.
- Takes effect immediately and persists across loads.

### Loop region

Restrict looping to a sub-section of the file:

```dart
await player.setLoopRegion(1.5, 8.0); // loop between 1.5s and 8.0s
await player.play();
```

Both `start` and `end` are in seconds. `start` must be `>= 0` and `end` must be greater than `start`.

Call `setLoopRegion` before or after `play()`. Clear by loading a new file.

### Crossfade

Add a smooth crossfade at the loop boundary:

```dart
await player.setCrossfadeDuration(0.3); // 300 ms equal-power crossfade
await player.play();
```

Set to `0.0` (default) to disable crossfade and use the lowest-latency loop path. The crossfade duration must be less than half the loop region length.

> **Web:** Crossfade is not supported on the web platform. Calling `setCrossfadeDuration` with a non-zero value throws `UnsupportedError`.

### Seek

```dart
await player.seek(3.5); // seek to 3.5 seconds
```

Seeking while playing triggers a brief reschedule on the native side. The next loop boundary will restart from the loop region start, not the seek position.

### Duration and position

```dart
final duration = await player.duration;         // returns Duration
final position = await player.currentPosition;  // returns double (seconds)
```

`duration` returns `Duration.zero` if no file is loaded. `currentPosition` returns `0.0` if not playing.

### State stream

```dart
player.stateStream.listen((PlayerState state) {
  switch (state) {
    case PlayerState.loading: print('Loading…');
    case PlayerState.ready:   print('Ready');
    case PlayerState.playing: print('Playing');
    case PlayerState.paused:  print('Paused');
    case PlayerState.stopped: print('Stopped');
    case PlayerState.error:   print('Error — check errorStream');
    case PlayerState.idle:    print('Idle');
  }
});
```

### Error stream

```dart
player.errorStream.listen((String message) {
  print('Error: $message');
});
```

Errors also set `stateStream` to `PlayerState.error`.

### Audio route changes

Pause automatically when headphones are unplugged:

```dart
player.routeChangeStream.listen((RouteChangeEvent event) {
  if (event.reason == RouteChangeReason.headphonesUnplugged) {
    player.pause();
  }
});
```

### BPM detection

After every successful load, the plugin analyses the audio on a background thread and emits a `BpmResult` on `bpmStream`. This fires once per load, shortly after `stateStream` emits `PlayerState.ready`.

```dart
player.bpmStream.listen((BpmResult result) {
  print('BPM: ${result.bpm.toStringAsFixed(1)}');
  print('Confidence: ${result.confidence.toStringAsFixed(2)}');
  print('Beat timestamps: ${result.beats}');
});
```

`bpm` is `0.0` if the audio is shorter than 2 seconds or completely silent.

**Using detected BPM to drive playback rate:**

```dart
double detectedBpm = 0;
double targetBpm   = 0;

player.bpmStream.listen((r) {
  detectedBpm = r.bpm;
  targetBpm   = r.bpm; // initialise to detected value
});

// When the user changes the target BPM:
void setTargetBpm(double bpm) {
  targetBpm = bpm;
  if (detectedBpm > 0) {
    player.setPlaybackRate(targetBpm / detectedBpm);
  }
}
```

### Amplitude stream

Subscribe to `amplitudeStream` to receive real-time audio level data while the player is playing. Events fire approximately 20 times per second. The stream is silent (no events) when playback is paused or stopped.

```dart
player.amplitudeStream.listen((AmplitudeEvent event) {
  print('RMS: ${event.rms.toStringAsFixed(3)}');   // smooth level — good for VU meters
  print('Peak: ${event.peak.toStringAsFixed(3)}'); // instantaneous peak — good for peak-hold
});
```

Both `rms` and `peak` are in `[0.0, 1.0]` where `0.0` is silence and `1.0` is full scale.

**VU meter widget example:**

```dart
StreamBuilder<AmplitudeEvent>(
  stream: player.amplitudeStream,
  builder: (context, snapshot) {
    final level = snapshot.data?.rms ?? 0.0;
    return LinearProgressIndicator(value: level);
  },
)
```

### Time signature detection

`BpmResult` also includes the detected time signature. This is emitted on the same `bpmStream` call, at no extra cost.

```dart
player.bpmStream.listen((BpmResult result) {
  if (result.bpm == 0) return; // detection skipped

  print('${result.bpm.toStringAsFixed(1)} BPM');

  if (result.beatsPerBar > 0) {
    print('Time signature: ${result.beatsPerBar}/4');
    print('Bar count: ${result.bars.length}');
    print('Bar timestamps (s): ${result.bars}');
  }
});
```

`beatsPerBar` is `0` when confidence is too low (< 0.3) to make a reliable meter estimate. The detector evaluates candidates `{2, 3, 4, 6, 7}` with a Gaussian prior favouring 4/4.

**Using detected time signature to pre-configure the metronome:**

```dart
player.bpmStream.listen((BpmResult r) async {
  if (r.bpm > 0 && r.beatsPerBar > 0) {
    await metronome.start(
      bpm: r.bpm,
      beatsPerBar: r.beatsPerBar,
      click: clickBytes,
      accent: accentBytes,
    );
  }
});
```

---

## MetronomePlayer

`MetronomePlayer` runs a sample-accurate click track independently from `LoopAudioPlayer`. Both can play at the same time. The metronome pre-generates a single-bar PCM buffer (accent on beat 0, click on beats 1…N-1) and loops it via the hardware scheduler.

You supply the click and accent sounds as raw audio bytes (`Uint8List`). Any format supported by the platform decoder is accepted (WAV, MP3, AAC, FLAC, etc.).

### Basic usage

```dart
import 'package:flutter_gapless_loop/flutter_gapless_loop.dart';

final metronome = MetronomePlayer();

// Load your click/accent audio bytes (e.g. from assets or generated)
final clickBytes  = (await rootBundle.load('assets/click.wav')).buffer.asUint8List();
final accentBytes = (await rootBundle.load('assets/accent.wav')).buffer.asUint8List();

// Start at 120 BPM in 4/4
await metronome.start(
  bpm: 120.0,
  beatsPerBar: 4,
  click: clickBytes,
  accent: accentBytes,
);

// Stop
await metronome.stop();

// Dispose when done
await metronome.dispose();
```

### Beat stream

Subscribe to `beatStream` to animate a UI beat indicator. The stream emits the current beat index on each tick: `0` = downbeat (accent), `1`…`N-1` = regular beats. This is a UI hint only — it is not used for audio scheduling and has ±5 ms jitter.

```dart
metronome.beatStream.listen((int beat) {
  setState(() => _currentBeat = beat);
});
```

### Changing tempo or time signature without stopping

```dart
await metronome.setBpm(140.0);       // new tempo — bar buffer is regenerated
await metronome.setBeatsPerBar(3);   // change to 3/4 — bar buffer is regenerated
```

Both methods are no-ops if the metronome has not been started yet. The bar buffer is rebuilt immediately and playback resumes from beat 0.

### Time signatures

`beatsPerBar` accepts any value in `[1, 16]`. You can use it to represent simple and compound meters:

| Meter | `beatsPerBar` | `bpm` interpretation |
|-------|-------------|----------------------|
| 4/4   | `4`         | quarter note = BPM   |
| 3/4   | `3`         | quarter note = BPM   |
| 2/4   | `2`         | quarter note = BPM   |
| 6/8   | `6`         | eighth note = BPM    |
| 5/8   | `5`         | eighth note = BPM    |
| 7/8   | `7`         | eighth note = BPM    |
| 12/8  | `12`        | eighth note = BPM    |

> **Note on compound meter:** The current API places an accent only on beat 0. In 6/8 the conventional accent falls on both beat 0 and beat 3. If you need per-beat accent patterns, use two separate `MetronomePlayer` instances — one with `beatsPerBar: 2` (dotted-quarter pulse) for the accents and one with `beatsPerBar: 6` for the subdivisions — or generate a custom bar buffer and use `loadFromBytes`.

**Example — 6/8 at dotted-quarter = 80 BPM:**

```dart
// BPM is expressed as the eighth-note pulse rate
await metronome.start(
  bpm: 240,        // 80 dotted-quarter × 3 eighth-notes = 240 eighth-notes per minute
  beatsPerBar: 6,
  click: clickBytes,
  accent: accentBytes,
);
```

### Validation

| Parameter | Valid range | Exception |
|-----------|------------|-----------|
| `bpm` | `(0, 400]` | `ArgumentError` |
| `beatsPerBar` | `[1, 16]` | `ArgumentError` |

All methods throw `StateError` if called after `dispose()`.

---

## API reference

### `LoopAudioPlayer`

| Method / Getter | Description |
|----------------|-------------|
| `load(String assetPath)` | Load from a Flutter asset key (e.g. `'assets/loop.wav'`). |
| `loadFromFile(String filePath)` | Load from an absolute file system path. |
| `loadFromBytes(Uint8List bytes, {String extension})` | Load from raw audio bytes. `extension` defaults to `'wav'`. |
| `loadFromUrl(Uri uri)` | Download from an `http`/`https` URL natively and load. Throws `PlatformException` on non-2xx response or decode failure. |
| `play({bool loop = true})` | Start playback. `loop: true` (default) = gapless loop; `loop: false` = play once then stop. |
| `pause()` | Pause; preserves position. |
| `resume()` | Resume from paused position. |
| `stop()` | Stop and reset position. |
| `playAfterCountIn(MetronomePlayer, BpmResult, {int bars})` | Wait `bars` (default 1) complete bars of the running metronome, then call `play()`. |
| `fadeTo(double targetVolume, Duration duration)` | Smooth native volume ramp to `targetVolume`. iOS, macOS. |
| `fadeIn(Duration duration)` | Shorthand for `fadeTo(1.0, duration)`. iOS, macOS. |
| `fadeOut(Duration duration)` | Shorthand for `fadeTo(0.0, duration)`. iOS, macOS. |
| `setLoopRegion(double start, double end)` | Loop only the region between `start` and `end` (seconds). |
| `saveLoopPointA()` | Bookmark current position as loop region start. |
| `saveLoopPointB()` | Bookmark current position as loop region end. |
| `applyLoopPoints()` | Call `setLoopRegion` with the saved A-B points. |
| `clearLoopPoints()` | Clear A and B bookmarks. |
| `loopPoints` | `LoopPoints` — current A-B state (synchronous getter). |
| `setCrossfadeDuration(double seconds)` | Crossfade duration at loop boundary. `0.0` = disabled. |
| `setVolume(double volume)` | Instance volume in `[0.0, 1.0]`. Effective volume = `localVolume × LoopAudioMaster.volume`. Values clamped. |
| `setPan(double pan)` | Instance pan in `[-1.0, 1.0]`. Effective pan = `clamp(localPan + LoopAudioMaster.pan, -1, 1)`. Values clamped. |
| `setPlaybackRate(double rate)` | Speed multiplier in `[0.25, 4.0]`, pitch-preserving. |
| `setPitch(double semitones)` | Pitch shift ±24 semitones, independent of rate. iOS, macOS. |
| `seek(double seconds)` | Seek to position in seconds. |
| `setEq(EqSettings settings)` | 3-band biquad EQ. iOS, macOS, Android, Windows. |
| `resetEq()` | Restore all EQ bands to 0 dB. iOS, macOS, Android, Windows. |
| `setCutoffFilter(CutoffFilterSettings settings)` | Low-pass or high-pass biquad filter. iOS, macOS, Android, Windows. |
| `resetCutoffFilter()` | Bypass the cutoff filter. iOS, macOS, Android, Windows. |
| `setReverb(ReverbPreset preset, {double wetMix})` | Apply room reverb (7 presets). iOS, macOS. |
| `setCompressor(CompressorSettings settings)` | Dynamic range compression. iOS, macOS. |
| `applyEffectsPreset(EffectsPreset preset)` | Atomically apply a bundle of EQ + reverb + compressor + cutoff. |
| `enableSpectrum()` | Start FFT analysis; begin emitting on `spectrumStream`. iOS, macOS. |
| `disableSpectrum()` | Stop FFT analysis. iOS, macOS. |
| `exportToFile(String path, {ExportFormat format})` | Render audio with active DSP to a WAV file. iOS, macOS. |
| `setNowPlayingInfo(NowPlayingInfo info)` | Populate iOS lock screen / Control Center. iOS. |
| `duration` | `Future<Duration>` — total length of loaded file. |
| `currentPosition` | `Future<double>` — current playback position in seconds (exact, from native engine). |
| `lastKnownPosition` | `double` — last position recorded synchronously by `seek()` or `stop()`. Slightly stale but allocation-free; suitable for non-critical UI reads. |
| `isDisposed` | `bool` — `true` after `dispose()` has been called. |
| `stateStream` | `Stream<PlayerState>` — state changes from native layer. |
| `errorStream` | `Stream<String>` — error messages from native layer. |
| `routeChangeStream` | `Stream<RouteChangeEvent>` — audio route changes. |
| `bpmStream` | `Stream<BpmResult>` — BPM + time signature analysis result after each load. |
| `amplitudeStream` | `Stream<AmplitudeEvent>` — RMS and peak amplitude at ~20 Hz while playing. |
| `spectrumStream` | `Stream<SpectrumData>` — 256-bin FFT magnitudes at ~20 Hz. Requires `enableSpectrum()`. iOS, macOS. |
| `dispose()` | Release all native resources. Instance unusable after this. |

### `LoopAudioMaster`

`LoopAudioMaster` is a static class that applies master volume and pan across all live `LoopAudioPlayer` instances. Per-instance relative levels are preserved.

```dart
await LoopAudioMaster.setVolume(0.5); // all instances scaled by 0.5
await LoopAudioMaster.setPan(0.2);    // all instances shifted right by 0.2
await LoopAudioMaster.reset();        // restore volume=1.0, pan=0.0
```

| Member | Description |
|--------|-------------|
| `volume` | Current master volume getter (default `1.0`) |
| `pan` | Current master pan getter (default `0.0`) |
| `setVolume(double volume)` | Scales all live instances: `effectiveVolume = localVolume × masterVolume` |
| `setPan(double pan)` | Shifts all live instances: `effectivePan = clamp(localPan + masterPan, -1, 1)` |
| `reset()` | Restores `volume=1.0` / `pan=0.0` and re-applies to all instances |

### `MetronomePlayer`

| Method / Getter | Description |
|----------------|-------------|
| `start({required double bpm, required int beatsPerBar, required Uint8List click, required Uint8List accent, String extension})` | Decode click/accent bytes, generate bar buffer, and start looping. `extension` defaults to `'wav'`. |
| `stop()` | Stop the metronome immediately. |
| `setBpm(double bpm)` | Update tempo; regenerates bar buffer. No-op if not started. |
| `setBeatsPerBar(int beatsPerBar)` | Update time signature; regenerates bar buffer. No-op if not started. |
| `setVolume(double volume)` | Instance volume in `[0.0, 1.0]`. Effective volume = `localVolume × MetronomeMaster.volume`. |
| `setPan(double pan)` | Instance pan in `[-1.0, 1.0]`. Effective pan = `clamp(localPan + MetronomeMaster.pan, -1, 1)`. |
| `beatStream` | `Stream<int>` — beat index (0 = downbeat, 1…N-1 = click). UI hint; ±5 ms jitter. |
| `dispose()` | Release all native resources. Instance unusable after this. |

### `MetronomeMaster`

`MetronomeMaster` is a static class that applies master volume and pan across all live `MetronomePlayer` instances. Per-instance relative levels are preserved.

```dart
await MetronomeMaster.setVolume(0.5); // all instances scaled by 0.5
await MetronomeMaster.setPan(0.2);    // all instances shifted right by 0.2
await MetronomeMaster.reset();        // restore volume=1.0, pan=0.0
```

| Member | Description |
|--------|-------------|
| `volume` | Current master volume getter (default `1.0`) |
| `pan` | Current master pan getter (default `0.0`) |
| `setVolume(double volume)` | Scales all live instances: `effectiveVolume = localVolume × masterVolume` |
| `setPan(double pan)` | Shifts all live instances: `effectivePan = clamp(localPan + masterPan, -1, 1)` |
| `reset()` | Restores `volume=1.0` / `pan=0.0` and re-applies to all instances |

### `PlayerState`

| Value | Description |
|-------|-------------|
| `idle` | No file loaded. Initial state. |
| `loading` | File is being read and decoded. |
| `ready` | File loaded; engine ready to play. |
| `playing` | Audio is actively looping. |
| `paused` | Paused; can resume without reloading. |
| `stopped` | Stopped; position reset. |
| `error` | Unrecoverable error; check `errorStream`. |

### `BpmResult`

| Field | Type | Description |
|-------|------|-------------|
| `bpm` | `double` | Estimated tempo in BPM. `0.0` if detection was skipped. |
| `confidence` | `double` | Detection confidence in `[0.0, 1.0]`. Values above `0.5` are reliable. |
| `beats` | `List<double>` | Beat timestamps in seconds from the start of the file. |
| `beatsPerBar` | `int` | Detected beats per bar (time signature numerator). `0` if confidence < 0.3. |
| `bars` | `List<double>` | Bar start timestamps in seconds. Empty if `beatsPerBar` is `0`. |

### `AmplitudeEvent`

| Field | Type | Description |
|-------|------|-------------|
| `rms` | `double` | Root-mean-square level of the current audio buffer. In `[0.0, 1.0]`. Smooth; good for VU meters. |
| `peak` | `double` | Peak sample magnitude of the current audio buffer. In `[0.0, 1.0]`. Reacts faster than `rms`; good for peak-hold indicators. |

### `RouteChangeEvent` / `RouteChangeReason`

| Reason | Description |
|--------|-------------|
| `headphonesUnplugged` | Audio output device (e.g. headphones) was removed. |
| `categoryChange` | AVAudioSession category changed (iOS only). |
| `unknown` | Other route change reason. |

---

## DSP effects

### 3-band EQ

Available on iOS, macOS, Android, and Windows. Three biquad filters are applied in series to every audio chunk: low shelf at 80 Hz, peaking at 1 kHz, and high shelf at 10 kHz. Changes take effect immediately without reloading the file.

```dart
await player.setEq(EqSettings(
  lowGainDb:  3.0,   // boost bass +3 dB
  midGainDb: -2.0,   // cut mid -2 dB
  highGainDb: 4.0,   // boost highs +4 dB
));

await player.resetEq(); // restore all bands to 0 dB
```

### Cutoff filter

Available on iOS, macOS, Android, and Windows. Applied after the EQ in the signal chain.

```dart
// Low-pass at 8 kHz (roll off the highs)
await player.setCutoffFilter(CutoffFilterSettings(
  type:      FilterType.lowPass,
  cutoffHz:  8000.0,
  resonance: 0.707,  // Butterworth (no peak)
));

// High-pass at 200 Hz (remove low rumble)
await player.setCutoffFilter(CutoffFilterSettings(
  type:     FilterType.highPass,
  cutoffHz: 200.0,
));

await player.resetCutoffFilter(); // bypass
```

### Reverb (iOS, macOS)

```dart
await player.setReverb(ReverbPreset.mediumHall, wetMix: 0.4);
```

Available presets: `smallRoom`, `mediumRoom`, `largeRoom`, `mediumHall`, `largeHall`, `plate`, `cathedral`. `wetMix` ranges from `0.0` (dry) to `1.0` (fully wet), default `0.3`.

### Compressor (iOS, macOS)

```dart
await player.setCompressor(CompressorSettings(
  threshold:  -18.0,  // start compressing at −18 dB
  makeupGain:  4.0,   // add 4 dB of make-up gain
  attackMs:    5.0,
  releaseMs:   80.0,
));
```

### Pitch shift (iOS, macOS)

Shifts pitch by semitones without affecting speed. Independent of `setPlaybackRate`.

```dart
await player.setPitch(-2.0);  // down 2 semitones
await player.setPitch(0.0);   // natural pitch (default)
await player.setPitch(7.0);   // up a perfect fifth
```

### Volume fades (iOS, macOS)

```dart
await player.fadeIn(const Duration(seconds: 2));          // fade in over 2 s
await player.fadeOut(const Duration(milliseconds: 500));  // fade out over 500 ms
await player.fadeTo(0.6, const Duration(seconds: 1));     // ramp to 60 % over 1 s
```

Fades are processed natively at 100 Hz for smooth, click-free transitions.

### Effects preset

Atomically apply a bundle of EQ + reverb + compressor + cutoff in one call. Useful for saving and restoring a full DSP configuration.

```dart
const myPreset = EffectsPreset(
  eq:           EqSettings(lowGainDb: 2, midGainDb: 0, highGainDb: 3),
  reverb:       ReverbPreset.smallRoom,
  reverbWetMix: 0.2,
  compressor:   CompressorSettings(threshold: -20, makeupGain: 3),
  cutoff:       CutoffFilterSettings(type: FilterType.lowPass, cutoffHz: 12000),
);

await player.applyEffectsPreset(myPreset);
```

---

## A-B loop points

Bookmark the current playback position as a loop region boundary without stopping. Useful for real-time loop trimming.

```dart
// While the track is playing…
await player.saveLoopPointA(); // mark loop start at current position
// …later…
await player.saveLoopPointB(); // mark loop end at current position

await player.applyLoopPoints(); // equivalent to setLoopRegion(a, b)

// Check the saved positions
final pts = player.loopPoints;
print('A: ${pts.pointA}, B: ${pts.pointB}, complete: ${pts.isComplete}');

await player.clearLoopPoints(); // reset
```

---

## Count-in

Start playback automatically after a specified number of bars of a running `MetronomePlayer`:

```dart
// Start the metro first
await metronome.start(bpm: 120, beatsPerBar: 4, click: clickBytes, accent: accentBytes);

// Waits 1 bar (default), then calls play()
await player.playAfterCountIn(metronome, bpmResult);

// Wait 2 bars before starting
await player.playAfterCountIn(metronome, bpmResult, bars: 2);
```

---

## Spectrum analyser (iOS, macOS)

```dart
await player.enableSpectrum();

player.spectrumStream.listen((SpectrumData data) {
  // data.magnitudes: Float32List of 256 normalised [0, 1] bins, low → high frequency
  final peak = data.magnitudes.reduce(math.max);
  print('Peak bin: $peak');
});

await player.disableSpectrum();
```

---

## Export to file (iOS, macOS)

Render the loaded audio with all active DSP (EQ, reverb, compressor, cutoff) to a WAV file on disk:

```dart
await player.exportToFile(
  '/path/to/output.wav',
  format: ExportFormat.wav16bit,  // or ExportFormat.wav32bit (default)
);
```

---

## Now Playing info (iOS)

Populate the iOS lock screen and Control Center media strip:

```dart
await player.setNowPlayingInfo(NowPlayingInfo(
  title:    'My Loop',
  artist:   'Artist Name',
  duration: await player.duration,
));
```

---

## Implementation notes

### Native engines

| Feature | iOS / macOS | Android | Windows |
|---------|-------------|---------|---------|
| Loop player | `AVAudioPlayerNode.scheduleBuffer(.loops)` | `AudioTrack MODE_STREAM` | `IXAudio2SourceVoice` + `XAUDIO2_LOOP_INFINITE` |
| Metronome | `AVAudioPlayerNode.scheduleBuffer(.loops)` on dedicated engine | `AudioTrack MODE_STATIC` + `setLoopPoints` | XAudio2 `XAUDIO2_LOOP_INFINITE` + `std::chrono` timer |
| Audio decode | `AVAudioFile` | `MediaCodec` async callback + pre-allocated PCM buffer | `IMFSourceReader` (MediaFoundation) |
| URL loading | `URLSession.shared.dataTask` | `HttpURLConnection` on `Dispatchers.IO` | `URLDownloadToFileW` (background thread) |
| Time pitch | `AVAudioUnitTimePitch` | `PlaybackParams.setSpeed` (API 23+) | `SetFrequencyRatio` (speed + pitch) |
| BPM detection | `DispatchWorkItem` on `.utility` queue | `Dispatchers.Default` coroutine | `std::thread` (detached) |
| Pan | `AVAudioMixerNode.pan` | Equal-power formula → `setStereoVolume` | `SetOutputMatrix` (equal-power) |

### Click prevention

A 5 ms linear micro-fade is applied to both ends of every loop buffer at load time. This eliminates audible clicks at the loop boundary and at metronome restarts with zero runtime cost.

### Threading

- **iOS / macOS:** All engine state mutations run on a dedicated serial `audioQueue` (`DispatchQueue`, `.userInteractive`). Flutter method results and event sink calls are dispatched back to `DispatchQueue.main`.
- **Android:** Coroutine scope uses `Dispatchers.Main + SupervisorJob()`. IO-bound work (file decode) suspends on `Dispatchers.IO`. All `EventChannel.EventSink` calls are posted through a `Handler(Looper.getMainLooper())`.
- **Windows:** Engine callbacks from background threads are marshalled to the Flutter platform thread via `PostMessage` + a `TopLevelWindowProcDelegate` that drains a mutex-protected callback queue.

---

## Important notes

- **Multiple instances are supported.** You can create any number of `LoopAudioPlayer` or `MetronomePlayer` instances and they will run concurrently without cross-talk. Each instance is independently tracked by the native layer via a unique player ID.
- **`LoopAudioPlayer` and `MetronomePlayer` are independent.** They use separate method and event channels and can run simultaneously without interfering with each other.
- **Call `dispose()`** when a player is no longer needed to release native resources promptly. If `dispose()` is never called, a `Finalizer` will release native resources when the Dart object is garbage-collected, but explicit disposal is still recommended.
- All methods throw `PlatformException` if the native engine returns an error (e.g. file not found, unsupported format).
- **Playback rate on Android** uses `PlaybackParams` (API 23+). On devices running Android 5 or 6, `setPlaybackRate` has no effect.
- **Crossfade** must be shorter than half the loop region. Very short loop regions with a long crossfade may behave unexpectedly.
- **Minimum Flutter version:** 3.27.0 (required for Swift Package Manager as the default build system).
- **Minimum iOS version:** 14.0 (required by `os.log.Logger`).
- **Minimum macOS version:** 11.0 (required by `os.log.Logger`).
- **Minimum Linux:** Ubuntu 20.04+ (glibc 2.31+). `libcurl` must be installed (`sudo apt install libcurl4-openssl-dev` for development; it ships by default on most desktop distros).
- **`loadFromUrl`** uses the platform networking stack (`URLSession` on iOS/macOS, `HttpURLConnection` on Android, `URLDownloadToFileW` on Windows). No additional packages are required.

## License

MIT — see [LICENSE](LICENSE).
