import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_gapless_loop/flutter_gapless_loop.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final stubBytes = Uint8List(100);

  late List<MethodCall> methodCalls;

  setUp(() {
    methodCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('flutter_gapless_loop'),
      (MethodCall call) async {
        methodCalls.add(call);
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('flutter_gapless_loop'),
      null,
    );
  });

  group('loadFromBytes', () {
    test('calls loadFromFile with a path ending in .wav by default', () async {
      final player = LoopAudioPlayer();
      await player.loadFromBytes(stubBytes);

      expect(methodCalls, hasLength(1));
      expect(methodCalls.first.method, equals('load'));
      final path = methodCalls.first.arguments['path'] as String;
      expect(path, endsWith('.wav'));
    });

    test('uses custom extension when provided', () async {
      final player = LoopAudioPlayer();
      await player.loadFromBytes(stubBytes, extension: 'mp3');

      expect(methodCalls.first.arguments['path'] as String, endsWith('.mp3'));
    });

    test('temp file is deleted after load', () async {
      final player = LoopAudioPlayer();
      String? tempPath;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('flutter_gapless_loop'),
        (MethodCall call) async {
          if (call.method == 'load') {
            tempPath = call.arguments['path'] as String;
          }
          return null;
        },
      );

      await player.loadFromBytes(stubBytes);

      expect(tempPath, isNotNull);
      final file = File(tempPath!);
      expect(await file.exists(), isFalse,
          reason: 'Temp file should be deleted after load');
    });

    test('throws StateError when called after dispose', () async {
      final player = LoopAudioPlayer();
      await player.dispose();
      expect(() => player.loadFromBytes(stubBytes), throwsStateError);
    });
  });

  group('loadFromUrl', () {
    test('invokes loadUrl with the URI string', () async {
      final player = LoopAudioPlayer();
      await player.loadFromUrl(Uri.parse('https://example.com/loop.wav'));

      expect(methodCalls, hasLength(1));
      expect(methodCalls.first.method, equals('loadUrl'));
      expect(methodCalls.first.arguments['url'],
          equals('https://example.com/loop.wav'));
    });

    test('throws StateError when called after dispose', () async {
      final player = LoopAudioPlayer();
      await player.dispose();
      expect(
        () => player.loadFromUrl(Uri.parse('https://example.com/loop.wav')),
        throwsStateError,
      );
    });
  });
}
