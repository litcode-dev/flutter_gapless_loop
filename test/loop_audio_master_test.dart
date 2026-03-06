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
      (call) async {
        calls.add(call);
        return null;
      },
    );
    // Reset master state between tests (uses @visibleForTesting helper).
    LoopAudioMaster.resetForTesting();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('flutter_gapless_loop'), null);
  });

  group('LoopAudioPlayer.setVolume', () {
    test('sends localVolume × masterVolume (1.0 default) to native', () async {
      final p = LoopAudioPlayer();
      await p.setVolume(0.8);
      expect(calls.last.method, 'setVolume');
      final args = calls.last.arguments as Map;
      expect(args['volume'], closeTo(0.8, 0.001));
      expect(args['playerId'], equals(p.playerId));
    });

    test('multiplies by master volume when master != 1.0', () async {
      await LoopAudioMaster.setVolume(0.5);
      calls.clear();
      final p = LoopAudioPlayer();
      await p.setVolume(0.8);
      final args = calls.last.arguments as Map;
      expect(args['volume'], closeTo(0.4, 0.001)); // 0.8 × 0.5
    });

    test('clamps effective volume to 1.0', () async {
      final p = LoopAudioPlayer();
      await p.setVolume(1.1); // local clamped to 1.0, effective = 1.0 × 1.0
      final args = calls.last.arguments as Map;
      expect(args['volume'], closeTo(1.0, 0.001));
    });

    test('throws StateError after dispose', () async {
      final p = LoopAudioPlayer();
      await p.dispose();
      expect(() => p.setVolume(0.5), throwsStateError);
    });
  });

  group('LoopAudioPlayer.setPan', () {
    test('sends localPan + masterPan (0.0 default) to native', () async {
      final p = LoopAudioPlayer();
      await p.setPan(0.6);
      expect(calls.last.method, 'setPan');
      final args = calls.last.arguments as Map;
      expect(args['pan'], closeTo(0.6, 0.001));
      expect(args['playerId'], equals(p.playerId));
    });

    test('adds master pan offset', () async {
      await LoopAudioMaster.setPan(0.3);
      calls.clear();
      final p = LoopAudioPlayer();
      await p.setPan(0.5);
      final args = calls.last.arguments as Map;
      expect(args['pan'], closeTo(0.8, 0.001)); // 0.5 + 0.3
    });

    test('clamps effective pan to 1.0', () async {
      await LoopAudioMaster.setPan(0.5);
      calls.clear();
      final p = LoopAudioPlayer();
      await p.setPan(0.8); // 0.8 + 0.5 = 1.3 → clamped to 1.0
      final args = calls.last.arguments as Map;
      expect(args['pan'], closeTo(1.0, 0.001));
    });

    test('clamps effective pan to -1.0', () async {
      await LoopAudioMaster.setPan(-0.5);
      calls.clear();
      final p = LoopAudioPlayer();
      await p.setPan(-0.8); // -0.8 + -0.5 = -1.3 → clamped to -1.0
      final args = calls.last.arguments as Map;
      expect(args['pan'], closeTo(-1.0, 0.001));
    });

    test('throws StateError after dispose', () async {
      final p = LoopAudioPlayer();
      await p.dispose();
      expect(() => p.setPan(0.5), throwsStateError);
    });
  });

  group('LoopAudioMaster.setVolume', () {
    test('re-applies effective volume to all live instances', () async {
      final p1 = LoopAudioPlayer();
      final p2 = LoopAudioPlayer();
      await p1.setVolume(0.8);
      await p2.setVolume(0.6);
      calls.clear();

      await LoopAudioMaster.setVolume(0.5);

      final volumeCalls = calls.where((c) => c.method == 'setVolume').toList();
      expect(volumeCalls, hasLength(2));
      final vols =
          volumeCalls.map((c) => c.arguments['volume'] as double).toSet();
      expect(vols, containsAll([closeTo(0.4, 0.001), closeTo(0.3, 0.001)]));
    });

    test('skips disposed instances', () async {
      LoopAudioPlayer(); // live instance in registry, not otherwise used
      final p2 = LoopAudioPlayer();
      await p2.dispose();
      calls.clear();

      await LoopAudioMaster.setVolume(0.5);

      final volumeCalls = calls.where((c) => c.method == 'setVolume').toList();
      expect(volumeCalls, hasLength(1));
    });

    test('exposes current value via getter', () async {
      await LoopAudioMaster.setVolume(0.7);
      expect(LoopAudioMaster.volume, closeTo(0.7, 0.001));
    });
  });

  group('LoopAudioMaster.setPan', () {
    test('re-applies effective pan to all live instances', () async {
      final p1 = LoopAudioPlayer();
      final p2 = LoopAudioPlayer();
      await p1.setPan(0.4);
      await p2.setPan(-0.2);
      calls.clear();

      await LoopAudioMaster.setPan(0.2);

      final panCalls = calls.where((c) => c.method == 'setPan').toList();
      expect(panCalls, hasLength(2));
      final pans = panCalls.map((c) => c.arguments['pan'] as double).toSet();
      expect(pans, containsAll([closeTo(0.6, 0.001), closeTo(0.0, 0.001)]));
    });

    test('exposes current value via getter', () async {
      await LoopAudioMaster.setPan(-0.3);
      expect(LoopAudioMaster.pan, closeTo(-0.3, 0.001));
    });
  });

  group('LoopAudioMaster.reset', () {
    test('restores defaults and re-applies to all instances', () async {
      await LoopAudioMaster.setVolume(0.5);
      await LoopAudioMaster.setPan(0.4);
      final p = LoopAudioPlayer();
      await p.setVolume(0.8);
      await p.setPan(0.3);
      calls.clear();

      await LoopAudioMaster.reset();

      expect(LoopAudioMaster.volume, 1.0);
      expect(LoopAudioMaster.pan, 0.0);
      // effective volume = 0.8 × 1.0 = 0.8; effective pan = 0.3 + 0.0 = 0.3
      final vCall = calls.firstWhere((c) => c.method == 'setVolume');
      expect(vCall.arguments['volume'], closeTo(0.8, 0.001));
      final pCall = calls.firstWhere((c) => c.method == 'setPan');
      expect(pCall.arguments['pan'], closeTo(0.3, 0.001));
    });
  });
}
