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
      expect(args['playerId'], startsWith('metro_'));
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
        () => player.start(
            bpm: 0.0, beatsPerBar: 4, click: stubBytes, accent: stubBytes),
        throwsArgumentError,
      );
      expect(
        () => player.start(
            bpm: -10.0, beatsPerBar: 4, click: stubBytes, accent: stubBytes),
        throwsArgumentError,
      );
    });

    test('throws ArgumentError for bpm > 400', () {
      final player = MetronomePlayer();
      expect(
        () => player.start(
            bpm: 401.0, beatsPerBar: 4, click: stubBytes, accent: stubBytes),
        throwsArgumentError,
      );
    });

    test('throws ArgumentError for beatsPerBar < 1', () {
      final player = MetronomePlayer();
      expect(
        () => player.start(
            bpm: 120.0, beatsPerBar: 0, click: stubBytes, accent: stubBytes),
        throwsArgumentError,
      );
    });

    test('throws ArgumentError for beatsPerBar > 16', () {
      final player = MetronomePlayer();
      expect(
        () => player.start(
            bpm: 120.0, beatsPerBar: 17, click: stubBytes, accent: stubBytes),
        throwsArgumentError,
      );
    });
  });

  group('setBpm', () {
    test('sends correct payload', () async {
      final player = MetronomePlayer();
      await player.setBpm(140.0);
      expect(calls.first.method, 'setBpm');
      final args = calls.first.arguments as Map;
      expect(args['bpm'], 140.0);
      expect(args['playerId'], startsWith('metro_'));
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
      final args = calls.first.arguments as Map;
      expect(args['beatsPerBar'], 3);
      expect(args['playerId'], startsWith('metro_'));
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
        () => player.start(
            bpm: 120.0, beatsPerBar: 4, click: stubBytes, accent: stubBytes),
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
