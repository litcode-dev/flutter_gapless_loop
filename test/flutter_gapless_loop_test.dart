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
}
