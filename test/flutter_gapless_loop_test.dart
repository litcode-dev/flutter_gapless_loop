import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gapless_loop/flutter_gapless_loop.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('LoopAudioPlayer can be instantiated', () {
    final player = LoopAudioPlayer();
    expect(player, isNotNull);
    // dispose() makes a platform channel call; in unit tests it will throw
    // MissingPluginException — that's expected and acceptable here.
  });

  test('PlayerState enum has expected values', () {
    expect(PlayerState.values, containsAll([
      PlayerState.idle,
      PlayerState.loading,
      PlayerState.ready,
      PlayerState.playing,
      PlayerState.paused,
      PlayerState.stopped,
      PlayerState.error,
    ]));
  });

  group('BpmResult', () {
    test('fromMap parses bpm, confidence, and beats correctly', () {
      final result = BpmResult.fromMap({
        'bpm': 128.0,
        'confidence': 0.92,
        'beats': [0.23, 0.70, 1.17],
      });
      expect(result.bpm, closeTo(128.0, 0.001));
      expect(result.confidence, closeTo(0.92, 0.001));
      expect(result.beats, [0.23, 0.70, 1.17]);
    });

    test('fromMap handles integer bpm value', () {
      final result = BpmResult.fromMap({
        'bpm': 120,
        'confidence': 0.85,
        'beats': <Object?>[],
      });
      expect(result.bpm, 120.0);
    });

    test('fromMap handles empty beats list', () {
      final result = BpmResult.fromMap({
        'bpm': 0.0,
        'confidence': 0.0,
        'beats': <Object?>[],
      });
      expect(result.beats, isEmpty);
    });
  });
}
