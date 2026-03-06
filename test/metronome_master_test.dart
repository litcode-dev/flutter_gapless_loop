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
      const MethodChannel('flutter_gapless_loop/metronome'),
      (call) async {
        calls.add(call);
        return null;
      },
    );
    // Reset master state between tests (uses @visibleForTesting helper).
    MetronomeMaster.resetForTesting();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('flutter_gapless_loop/metronome'), null);
  });

  group('MetronomePlayer.setVolume', () {
    test('sends localVolume × masterVolume (1.0 default) to native', () async {
      final m = MetronomePlayer();
      await m.setVolume(0.8);
      expect(calls.last.method, 'setVolume');
      final args = calls.last.arguments as Map;
      expect(args['volume'], closeTo(0.8, 0.001));
      expect(args['playerId'], equals(m.playerId));
    });

    test('multiplies by master volume when master != 1.0', () async {
      await MetronomeMaster.setVolume(0.5);
      calls.clear();
      final m = MetronomePlayer();
      await m.setVolume(0.8);
      final args = calls.last.arguments as Map;
      expect(args['volume'], closeTo(0.4, 0.001)); // 0.8 × 0.5
    });

    test('clamps effective volume to 1.0', () async {
      final m = MetronomePlayer();
      await m.setVolume(1.1); // clamped to 1.0
      final args = calls.last.arguments as Map;
      expect(args['volume'], closeTo(1.0, 0.001));
    });

    test('throws StateError after dispose', () async {
      final m = MetronomePlayer();
      await m.dispose();
      expect(() => m.setVolume(0.5), throwsStateError);
    });
  });

  group('MetronomePlayer.setPan', () {
    test('sends localPan + masterPan (0.0 default) to native', () async {
      final m = MetronomePlayer();
      await m.setPan(0.6);
      expect(calls.last.method, 'setPan');
      final args = calls.last.arguments as Map;
      expect(args['pan'], closeTo(0.6, 0.001));
      expect(args['playerId'], equals(m.playerId));
    });

    test('adds master pan offset', () async {
      await MetronomeMaster.setPan(0.3);
      calls.clear();
      final m = MetronomePlayer();
      await m.setPan(0.5);
      final args = calls.last.arguments as Map;
      expect(args['pan'], closeTo(0.8, 0.001)); // 0.5 + 0.3
    });

    test('clamps effective pan to 1.0', () async {
      await MetronomeMaster.setPan(0.5);
      calls.clear();
      final m = MetronomePlayer();
      await m.setPan(0.8); // 0.8 + 0.5 = 1.3 → clamped to 1.0
      final args = calls.last.arguments as Map;
      expect(args['pan'], closeTo(1.0, 0.001));
    });

    test('clamps effective pan to -1.0', () async {
      await MetronomeMaster.setPan(-0.5);
      calls.clear();
      final m = MetronomePlayer();
      await m.setPan(-0.8); // -0.8 + -0.5 = -1.3 → clamped to -1.0
      final args = calls.last.arguments as Map;
      expect(args['pan'], closeTo(-1.0, 0.001));
    });

    test('throws StateError after dispose', () async {
      final m = MetronomePlayer();
      await m.dispose();
      expect(() => m.setPan(0.5), throwsStateError);
    });
  });

  group('MetronomeMaster.setVolume', () {
    test('re-applies effective volume to all live instances', () async {
      final m1 = MetronomePlayer();
      final m2 = MetronomePlayer();
      await m1.setVolume(0.8);
      await m2.setVolume(0.6);
      calls.clear();

      await MetronomeMaster.setVolume(0.5);

      final volumeCalls = calls.where((c) => c.method == 'setVolume').toList();
      expect(volumeCalls, hasLength(2));
      final vols =
          volumeCalls.map((c) => c.arguments['volume'] as double).toSet();
      expect(vols, containsAll([closeTo(0.4, 0.001), closeTo(0.3, 0.001)]));
    });

    test('skips disposed instances', () async {
      MetronomePlayer(); // live instance in registry, not otherwise used
      final m2 = MetronomePlayer();
      await m2.dispose();
      calls.clear();

      await MetronomeMaster.setVolume(0.5);

      final volumeCalls = calls.where((c) => c.method == 'setVolume').toList();
      expect(volumeCalls, hasLength(1));
    });

    test('exposes current value via getter', () async {
      await MetronomeMaster.setVolume(0.7);
      expect(MetronomeMaster.volume, closeTo(0.7, 0.001));
    });
  });

  group('MetronomeMaster.setPan', () {
    test('re-applies effective pan to all live instances', () async {
      final m1 = MetronomePlayer();
      final m2 = MetronomePlayer();
      await m1.setPan(0.4);
      await m2.setPan(-0.2);
      calls.clear();

      await MetronomeMaster.setPan(0.2);

      final panCalls = calls.where((c) => c.method == 'setPan').toList();
      expect(panCalls, hasLength(2));
      final pans =
          panCalls.map((c) => c.arguments['pan'] as double).toSet();
      expect(pans, containsAll([closeTo(0.6, 0.001), closeTo(0.0, 0.001)]));
    });

    test('exposes current value via getter', () async {
      await MetronomeMaster.setPan(-0.3);
      expect(MetronomeMaster.pan, closeTo(-0.3, 0.001));
    });
  });

  group('MetronomeMaster.reset', () {
    test('restores defaults and re-applies to all instances', () async {
      await MetronomeMaster.setVolume(0.5);
      await MetronomeMaster.setPan(0.4);
      final m = MetronomePlayer();
      await m.setVolume(0.8);
      await m.setPan(0.3);
      calls.clear();

      await MetronomeMaster.reset();

      expect(MetronomeMaster.volume, 1.0);
      expect(MetronomeMaster.pan, 0.0);
      // effective volume = 0.8 × 1.0 = 0.8; effective pan = 0.3 + 0.0 = 0.3
      final vCall = calls.firstWhere((c) => c.method == 'setVolume');
      expect(vCall.arguments['volume'], closeTo(0.8, 0.001));
      final pCall = calls.firstWhere((c) => c.method == 'setPan');
      expect(pCall.arguments['pan'], closeTo(0.3, 0.001));
    });
  });
}
