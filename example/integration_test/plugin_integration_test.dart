// Integration tests for flutter_gapless_loop.
//
// These tests must be run on a real iOS device or simulator because they
// exercise AVAudioEngine, which is unavailable in the Flutter unit-test
// harness.
//
// Run with:
//   flutter test integration_test/plugin_integration_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:flutter_gapless_loop/flutter_gapless_loop.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('LoopAudioPlayer instantiation', (WidgetTester tester) async {
    final player = LoopAudioPlayer();
    expect(player, isNotNull);
    await player.dispose();
  });
}
