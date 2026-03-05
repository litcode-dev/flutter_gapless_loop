import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_gapless_loop/flutter_gapless_loop.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

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
    test('calls loadFromFile with path ending in .wav for .wav URL', () async {
      final client = MockClient((_) async =>
          http.Response.bytes(stubBytes, 200));
      final player = LoopAudioPlayer();
      await player.loadFromUrl(
        Uri.parse('https://example.com/loop.wav'),
        httpClient: client,
      );

      expect(methodCalls, hasLength(1));
      expect(methodCalls.first.method, equals('load'));
      final path = methodCalls.first.arguments['path'] as String;
      expect(path, endsWith('.wav'));
    });

    test('calls loadFromFile with path ending in .mp3 for .mp3 URL', () async {
      final client = MockClient((_) async =>
          http.Response.bytes(stubBytes, 200));
      final player = LoopAudioPlayer();
      await player.loadFromUrl(
        Uri.parse('https://example.com/track.mp3'),
        httpClient: client,
      );

      final path = methodCalls.first.arguments['path'] as String;
      expect(path, endsWith('.mp3'));
    });

    test('throws Exception on non-2xx HTTP response', () async {
      final client = MockClient((_) async => http.Response('Not Found', 404));
      final player = LoopAudioPlayer();

      await expectLater(
        () => player.loadFromUrl(
          Uri.parse('https://example.com/missing.wav'),
          httpClient: client,
        ),
        throwsA(isA<Exception>().having(
          (e) => e.toString(),
          'message',
          contains('404'),
        )),
      );
      expect(methodCalls, isEmpty,
          reason: 'loadFromFile must not be called on HTTP error');
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
