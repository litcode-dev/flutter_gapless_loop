import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_gapless_loop/flutter_gapless_loop.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<MethodCall> calls;
  late List<MethodCall> metroCalls;

  setUp(() {
    calls = [];
    metroCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('flutter_gapless_loop'),
      (call) async {
        calls.add(call);
        return null;
      },
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('flutter_gapless_loop/metronome'),
      (call) async {
        metroCalls.add(call);
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('flutter_gapless_loop'), null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('flutter_gapless_loop/metronome'), null);
  });

  group('LoopAudioPlayer multi-instance', () {
    test('two instances get different playerIds', () {
      final p1 = LoopAudioPlayer();
      final p2 = LoopAudioPlayer();
      expect(p1.playerId, isNot(equals(p2.playerId)));
    });

    test('play() includes playerId in args', () async {
      final p1 = LoopAudioPlayer();
      await p1.play();
      expect(calls.first.arguments['playerId'], equals(p1.playerId));
    });

    test('loadFromFile() includes playerId in args', () async {
      final p1 = LoopAudioPlayer();
      await p1.loadFromFile('/tmp/test.wav');
      expect(calls.first.arguments['playerId'], equals(p1.playerId));
    });

    test('dispose() includes playerId in args', () async {
      final p1 = LoopAudioPlayer();
      await p1.dispose();
      expect(calls.first.arguments['playerId'], equals(p1.playerId));
    });

    test('two instances send different playerIds', () async {
      final p1 = LoopAudioPlayer();
      final p2 = LoopAudioPlayer();
      await p1.play();
      await p2.play();
      final id1 = calls[0].arguments['playerId'] as String;
      final id2 = calls[1].arguments['playerId'] as String;
      expect(id1, isNot(equals(id2)));
    });
  });

  group('MetronomePlayer multi-instance', () {
    final stubBytes = Uint8List(4);

    test('two MetronomePlayer instances get different playerIds', () {
      final m1 = MetronomePlayer();
      final m2 = MetronomePlayer();
      expect(m1.playerId, isNot(equals(m2.playerId)));
    });

    test('start() includes playerId in args', () async {
      final m1 = MetronomePlayer();
      await m1.start(
          bpm: 120, beatsPerBar: 4, click: stubBytes, accent: stubBytes);
      expect(metroCalls.first.arguments['playerId'], equals(m1.playerId));
    });

    test('stop() includes playerId in args', () async {
      final m1 = MetronomePlayer();
      await m1.stop();
      expect(metroCalls.first.arguments['playerId'], equals(m1.playerId));
    });

    test('dispose() includes playerId in args', () async {
      final m1 = MetronomePlayer();
      await m1.dispose();
      expect(metroCalls.first.arguments['playerId'], equals(m1.playerId));
    });

    test('two MetronomePlayer instances send different playerIds', () async {
      final m1 = MetronomePlayer();
      final m2 = MetronomePlayer();
      await m1.stop();
      await m2.stop();
      final id1 = metroCalls[0].arguments['playerId'] as String;
      final id2 = metroCalls[1].arguments['playerId'] as String;
      expect(id1, isNot(equals(id2)));
    });
  });
}
