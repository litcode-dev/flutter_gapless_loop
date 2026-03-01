import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_gapless_loop/flutter_gapless_loop.dart';

void main() {
  test('LoopAudioPlayer can be instantiated', () {
    final player = LoopAudioPlayer();
    expect(player, isNotNull);
    player.dispose();
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
