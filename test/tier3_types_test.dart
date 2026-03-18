import 'package:flutter/services.dart';
import 'package:flutter_gapless_loop/flutter_gapless_loop.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;

  setUp(() {
    LoopAudioMaster.resetForTesting();
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('flutter_gapless_loop'),
      (call) async {
        calls.add(call);
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('flutter_gapless_loop'), null);
  });

  // ── AmplitudeEvent ──────────────────────────────────────────────────────────

  group('AmplitudeEvent', () {
    test('fromMap parses rms and peak', () {
      final e = AmplitudeEvent.fromMap({'rms': 0.42, 'peak': 0.78});
      expect(e.rms, closeTo(0.42, 0.001));
      expect(e.peak, closeTo(0.78, 0.001));
    });

    test('fromMap clamps values above 1.0', () {
      final e = AmplitudeEvent.fromMap({'rms': 1.5, 'peak': 2.0});
      expect(e.rms, 1.0);
      expect(e.peak, 1.0);
    });

    test('fromMap clamps values below 0.0', () {
      final e = AmplitudeEvent.fromMap({'rms': -0.1, 'peak': -1.0});
      expect(e.rms, 0.0);
      expect(e.peak, 0.0);
    });

    test('fromMap defaults missing fields to 0', () {
      final e = AmplitudeEvent.fromMap({});
      expect(e.rms, 0.0);
      expect(e.peak, 0.0);
    });
  });

  // ── EqSettings ─────────────────────────────────────────────────────────────

  group('EqSettings', () {
    test('flat constant has all bands at 0 dB', () {
      expect(EqSettings.flat.bass, 0.0);
      expect(EqSettings.flat.mid, 0.0);
      expect(EqSettings.flat.treble, 0.0);
    });

    test('toMap round-trips correctly', () {
      const eq = EqSettings(bass: 6.0, mid: -3.0, treble: 9.0);
      final map = eq.toMap();
      expect(map['bass'], 6.0);
      expect(map['mid'], -3.0);
      expect(map['treble'], 9.0);
    });

    test('setEq sends correct args to native', () async {
      final p = LoopAudioPlayer();
      const eq = EqSettings(bass: 4.0, mid: -2.0, treble: 8.0);
      await p.setEq(eq);

      expect(calls.last.method, 'setEq');
      final args = calls.last.arguments as Map;
      expect(args['bass'], 4.0);
      expect(args['mid'], -2.0);
      expect(args['treble'], 8.0);
      expect(args['playerId'], p.playerId);
    });

    test('resetEq sends flat EQ', () async {
      final p = LoopAudioPlayer();
      await p.resetEq();

      expect(calls.last.method, 'setEq');
      final args = calls.last.arguments as Map;
      expect(args['bass'], 0.0);
      expect(args['mid'], 0.0);
      expect(args['treble'], 0.0);
    });
  });

  // ── CompressorSettings ─────────────────────────────────────────────────────

  group('CompressorSettings', () {
    test('toMap includes all fields', () {
      const s = CompressorSettings(
        enabled: true,
        thresholdDb: -18.0,
        makeupGainDb: 3.0,
        attackMs: 5.0,
        releaseMs: 200.0,
      );
      final map = s.toMap();
      expect(map['enabled'], true);
      expect(map['thresholdDb'], -18.0);
      expect(map['makeupGainDb'], 3.0);
      expect(map['attackMs'], 5.0);
      expect(map['releaseMs'], 200.0);
    });

    test('setCompressor sends correct args to native', () async {
      final p = LoopAudioPlayer();
      const s = CompressorSettings(enabled: true, thresholdDb: -12.0);
      await p.setCompressor(s);

      expect(calls.last.method, 'setCompressor');
      final args = calls.last.arguments as Map;
      expect(args['enabled'], true);
      expect(args['thresholdDb'], -12.0);
      expect(args['playerId'], p.playerId);
    });
  });

  // ── ReverbPreset ────────────────────────────────────────────────────────────

  group('ReverbPreset', () {
    test('all expected presets exist', () {
      expect(ReverbPreset.values, containsAll([
        ReverbPreset.none,
        ReverbPreset.smallRoom,
        ReverbPreset.mediumRoom,
        ReverbPreset.largeRoom,
        ReverbPreset.mediumHall,
        ReverbPreset.largeHall,
        ReverbPreset.plate,
        ReverbPreset.cathedral,
      ]));
    });

    test('setReverb sends preset name and wetMix to native', () async {
      final p = LoopAudioPlayer();
      await p.setReverb(ReverbPreset.largeHall, wetMix: 0.6);

      expect(calls.last.method, 'setReverb');
      final args = calls.last.arguments as Map;
      expect(args['preset'], 'largeHall');
      expect(args['wetMix'], closeTo(0.6, 0.001));
      expect(args['playerId'], p.playerId);
    });

    test('setReverb clamps wetMix to [0, 1]', () async {
      final p = LoopAudioPlayer();
      await p.setReverb(ReverbPreset.plate, wetMix: 1.5);

      final args = calls.last.arguments as Map;
      expect(args['wetMix'], closeTo(1.0, 0.001));
    });
  });

  // ── SpectrumData ────────────────────────────────────────────────────────────

  group('SpectrumData', () {
    test('fromMap parses binCount, sampleRate, and magnitudes', () {
      final raw = List.generate(256, (i) => i / 256.0);
      final data = SpectrumData.fromMap({
        'binCount': 256,
        'sampleRate': 44100.0,
        'magnitudes': raw,
      });
      expect(data.binCount, 256);
      expect(data.sampleRate, 44100.0);
      expect(data.magnitudes, hasLength(256));
      expect(data.magnitudes.first, closeTo(0.0, 0.001));
      expect(data.magnitudes.last, closeTo(255 / 256.0, 0.001));
    });

    test('frequencyForBin computes correct Hz', () {
      final data = SpectrumData(
          binCount: 256, sampleRate: 44100.0, magnitudes: []);
      // bin 1 → 1 × 44100 / (256 × 2) ≈ 86.1 Hz
      expect(data.frequencyForBin(1), closeTo(44100.0 / 512.0, 0.1));
      // bin 0 → DC (0 Hz)
      expect(data.frequencyForBin(0), 0.0);
    });

    test('fromMap clamps magnitudes above 1.0', () {
      final data = SpectrumData.fromMap({
        'binCount': 2,
        'sampleRate': 48000.0,
        'magnitudes': [1.5, 0.5],
      });
      expect(data.magnitudes[0], 1.0);
      expect(data.magnitudes[1], 0.5);
    });
  });

  // ── EffectsPreset ───────────────────────────────────────────────────────────

  group('EffectsPreset', () {
    test('bypass preset has no effects active', () {
      const p = EffectsPreset.bypass;
      expect(p.eq, EqSettings.flat);
      expect(p.reverbPreset, ReverbPreset.none);
      expect(p.reverbWetMix, 0.0);
      expect(p.compressor.enabled, false);
    });

    test('captureEffectsPreset round-trips through applyEffectsPreset', () async {
      final player = LoopAudioPlayer();
      // Set some non-default state
      await player.setEq(const EqSettings(bass: 3.0, mid: -1.0, treble: 2.0));
      await player.setReverb(ReverbPreset.smallRoom, wetMix: 0.3);
      await player.setCompressor(
          const CompressorSettings(enabled: true, thresholdDb: -15.0));
      calls.clear();

      final preset = player.captureEffectsPreset();
      expect(preset.eq.bass, 3.0);
      expect(preset.reverbPreset, ReverbPreset.smallRoom);
      expect(preset.reverbWetMix, closeTo(0.3, 0.001));
      expect(preset.compressor.enabled, true);

      // Applying back should send 3 method calls (setEq, setReverb, setCompressor)
      await player.applyEffectsPreset(preset);
      final methods = calls.map((c) => c.method).toSet();
      expect(methods, containsAll(['setEq', 'setReverb', 'setCompressor']));
    });
  });

  // ── A-B Loop Points ─────────────────────────────────────────────────────────

  group('A-B loop points', () {
    setUp(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('flutter_gapless_loop'),
        (call) async {
          calls.add(call);
          if (call.method == 'getCurrentPosition') return 5.0;
          return null;
        },
      );
    });

    test('recallABLoop calls setLoopRegion with saved points', () async {
      final player = LoopAudioPlayer();
      await player.saveLoopPointA(); // position = 5.0
      // Override to return a different position for B
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('flutter_gapless_loop'),
        (call) async {
          calls.add(call);
          if (call.method == 'getCurrentPosition') return 10.0;
          return null;
        },
      );
      await player.saveLoopPointB(); // position = 10.0
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('flutter_gapless_loop'),
        (call) async { calls.add(call); return null; },
      );

      await player.recallABLoop();

      expect(calls.last.method, 'setLoopRegion');
      final args = calls.last.arguments as Map;
      expect(args['start'], closeTo(5.0, 0.001));
      expect(args['end'], closeTo(10.0, 0.001));
    });

    test('recallABLoop does nothing when A >= B', () async {
      final player = LoopAudioPlayer();
      // Both positions return 5.0 — A == B, so no-op
      await player.saveLoopPointA();
      await player.saveLoopPointB();
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('flutter_gapless_loop'),
        (call) async { calls.add(call); return null; },
      );

      await player.recallABLoop();

      expect(calls, isEmpty);
    });
  });

  // ── reanalyzeBpm ────────────────────────────────────────────────────────────

  group('reanalyzeBpm', () {
    test('sends reanalyzeBpm method with playerId', () async {
      final player = LoopAudioPlayer();
      await player.reanalyzeBpm();

      expect(calls.last.method, 'reanalyzeBpm');
      expect(calls.last.arguments['playerId'], player.playerId);
    });

    test('throws StateError after dispose', () async {
      final player = LoopAudioPlayer();
      await player.dispose();
      expect(() => player.reanalyzeBpm(), throwsStateError);
    });
  });

  // ── WaveformData ────────────────────────────────────────────────────────────

  group('WaveformData', () {
    test('fromMap parses resolution and peaks', () {
      final data = WaveformData.fromMap({
        'resolution': 4,
        'peaks': [0.1, 0.5, 0.9, 0.3],
      });
      expect(data.resolution, 4);
      expect(data.peaks, hasLength(4));
      expect(data.peaks[1], closeTo(0.5, 0.001));
    });

    test('fromMap clamps peaks above 1.0', () {
      final data = WaveformData.fromMap({
        'resolution': 2,
        'peaks': [1.5, 0.3],
      });
      expect(data.peaks[0], 1.0);
    });

    test('fromMap infers resolution from peaks length when missing', () {
      final data = WaveformData.fromMap({
        'peaks': [0.1, 0.2, 0.3],
      });
      expect(data.resolution, 3);
    });
  });

  // ── SilenceInfo ─────────────────────────────────────────────────────────────

  group('SilenceInfo', () {
    test('fromMap parses start and end', () {
      final info = SilenceInfo.fromMap({'start': 0.5, 'end': 3.2});
      expect(info.start, closeTo(0.5, 0.001));
      expect(info.end, closeTo(3.2, 0.001));
    });

    test('duration getter returns end - start', () {
      const info = SilenceInfo(start: 1.0, end: 4.0);
      expect(info.duration, closeTo(3.0, 0.001));
    });
  });

  // ── LoudnessInfo ────────────────────────────────────────────────────────────

  group('LoudnessInfo', () {
    test('fromMap parses lufs', () {
      final info = LoudnessInfo.fromMap({'lufs': -14.5});
      expect(info.lufs, closeTo(-14.5, 0.001));
    });

    test('fromMap defaults to -100 when missing', () {
      final info = LoudnessInfo.fromMap({});
      expect(info.lufs, closeTo(-100.0, 0.001));
    });
  });

  // ── Seek helpers ────────────────────────────────────────────────────────────

  group('seekToNearestBeat', () {
    late LoopAudioPlayer player;

    setUp(() {
      player = LoopAudioPlayer();
    });

    final bpmResult = BpmResult(
      bpm: 120.0,
      confidence: 0.9,
      beats: [0.0, 0.5, 1.0, 1.5, 2.0],
    );

    test('seeks to the closest beat', () async {
      await player.seekToNearestBeat(0.3, bpmResult);
      expect(calls.last.method, 'seek');
      expect(calls.last.arguments['position'], closeTo(0.5, 0.001));
    });

    test('seeks to exact beat when position matches', () async {
      await player.seekToNearestBeat(1.0, bpmResult);
      expect(calls.last.arguments['position'], closeTo(1.0, 0.001));
    });

    test('does nothing if beats is empty', () async {
      final empty = BpmResult(bpm: 0.0, confidence: 0.0, beats: []);
      await player.seekToNearestBeat(1.0, empty);
      expect(calls.where((c) => c.method == 'seek'), isEmpty);
    });
  });

  group('seekToBeat', () {
    late LoopAudioPlayer player;
    setUp(() => player = LoopAudioPlayer());

    final bpmResult = BpmResult(
      bpm: 120.0,
      confidence: 0.9,
      beats: [0.0, 0.5, 1.0, 1.5],
    );

    test('seeks to correct beat index', () async {
      await player.seekToBeat(2, bpmResult);
      expect(calls.last.arguments['position'], closeTo(1.0, 0.001));
    });

    test('clamps out-of-range index to last beat', () async {
      await player.seekToBeat(99, bpmResult);
      expect(calls.last.arguments['position'], closeTo(1.5, 0.001));
    });

    test('clamps negative index to 0', () async {
      await player.seekToBeat(-1, bpmResult);
      expect(calls.last.arguments['position'], closeTo(0.0, 0.001));
    });
  });

  group('seekToBar', () {
    late LoopAudioPlayer player;
    setUp(() => player = LoopAudioPlayer());

    final bpmResult = BpmResult(
      bpm: 120.0,
      confidence: 0.9,
      beats: [],
      beatsPerBar: 4,
      bars: [0.0, 2.0, 4.0, 6.0],
    );

    test('seeks to correct bar start', () async {
      await player.seekToBar(2, bpmResult);
      expect(calls.last.arguments['position'], closeTo(4.0, 0.001));
    });

    test('clamps bar index to valid range', () async {
      await player.seekToBar(100, bpmResult);
      expect(calls.last.arguments['position'], closeTo(6.0, 0.001));
    });

    test('does nothing if bars is empty', () async {
      final noBars = BpmResult(bpm: 120.0, confidence: 0.9, beats: []);
      await player.seekToBar(0, noBars);
      expect(calls.where((c) => c.method == 'seek'), isEmpty);
    });
  });

  // ── BpmResult with beatsPerBar / bars ───────────────────────────────────────

  group('BpmResult with beatsPerBar and bars', () {
    test('fromMap parses beatsPerBar and bars', () {
      final result = BpmResult.fromMap({
        'bpm': 120.0,
        'confidence': 0.85,
        'beats': [0.0, 0.5, 1.0, 1.5],
        'beatsPerBar': 4,
        'bars': [0.0, 2.0],
      });
      expect(result.beatsPerBar, 4);
      expect(result.bars, [0.0, 2.0]);
    });

    test('fromMap defaults beatsPerBar to 0 and bars to empty', () {
      final result = BpmResult.fromMap({
        'bpm': 120.0,
        'confidence': 0.9,
        'beats': <Object?>[],
      });
      expect(result.beatsPerBar, 0);
      expect(result.bars, isEmpty);
    });
  });

  // ── setLoopRegion validation ────────────────────────────────────────────────

  group('setLoopRegion validation', () {
    test('throws ArgumentError when start < 0', () async {
      final player = LoopAudioPlayer();
      await expectLater(
        () => player.setLoopRegion(-0.1, 5.0),
        throwsArgumentError,
      );
    });

    test('throws ArgumentError when end <= start', () async {
      final player = LoopAudioPlayer();
      await expectLater(
        () => player.setLoopRegion(5.0, 5.0),
        throwsArgumentError,
      );
      await expectLater(
        () => player.setLoopRegion(5.0, 4.0),
        throwsArgumentError,
      );
    });

    test('sends correct args to native when valid', () async {
      final player = LoopAudioPlayer();
      await player.setLoopRegion(1.0, 5.0);
      expect(calls.last.method, 'setLoopRegion');
      final args = calls.last.arguments as Map;
      expect(args['start'], 1.0);
      expect(args['end'], 5.0);
    });
  });

  // ── exportToFile ────────────────────────────────────────────────────────────

  group('exportToFile', () {
    test('sends outputPath and playerId to native', () async {
      final player = LoopAudioPlayer();
      await player.exportToFile('/tmp/out.wav');

      expect(calls.last.method, 'exportToFile');
      final args = calls.last.arguments as Map;
      expect(args['outputPath'], '/tmp/out.wav');
      expect(args['playerId'], player.playerId);
    });

    test('throws StateError after dispose', () async {
      final player = LoopAudioPlayer();
      await player.dispose();
      expect(() => player.exportToFile('/tmp/out.wav'), throwsStateError);
    });
  });
}
