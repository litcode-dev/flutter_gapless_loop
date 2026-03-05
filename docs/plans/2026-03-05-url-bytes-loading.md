# URL and Bytes Loading Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add `loadFromUrl(Uri)` and `loadFromBytes(Uint8List)` to `LoopAudioPlayer` — both funnel into the existing `loadFromFile` method channel call via a temp file, with zero native changes.

**Architecture:** Both methods are pure Dart. A shared private helper `_loadFromBytesWithExtension` writes bytes to `Directory.systemTemp`, calls `loadFromFile`, then deletes the temp file in `finally`. `loadFromUrl` downloads via `http.Client` (injectable for testing) then delegates to the helper. `loadFromBytes` delegates directly.

**Tech Stack:** Dart, `package:http ^1.2.0`, `dart:io`, `dart:typed_data`, Flutter `MethodChannel` mock via `TestDefaultBinaryMessengerBinding`.

---

### Task 1: Add `http` dependency and write failing tests

**Files:**
- Modify: `pubspec.yaml`
- Create: `test/load_from_url_bytes_test.dart`

**Step 1: Add `http` to `pubspec.yaml`**

In `pubspec.yaml`, under `dependencies:`, add after `flutter: sdk: flutter`:

```yaml
dependencies:
  flutter:
    sdk: flutter
  http: ^1.2.0
```

Run:
```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop
flutter pub get
```

Expected: `Resolving dependencies...` completes with no errors.

**Step 2: Create `test/load_from_url_bytes_test.dart` with all failing tests**

```dart
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_gapless_loop/flutter_gapless_loop.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Minimal valid WAV header (44 bytes) + 1 second of silence at 44100 Hz mono 16-bit.
  // Used as stub audio bytes — the native layer is mocked so content doesn't matter.
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
```

Note: `File` is from `dart:io` — add the import at the top of the test file:

```dart
import 'dart:io';
```

Full import block for `test/load_from_url_bytes_test.dart`:

```dart
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_gapless_loop/flutter_gapless_loop.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
```

**Step 3: Run tests to verify they fail**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop
flutter test test/load_from_url_bytes_test.dart 2>&1 | tail -15
```

Expected: compilation error — `loadFromBytes` and `loadFromUrl` not found on `LoopAudioPlayer`.

**Step 4: Commit the failing tests**

```bash
git add pubspec.yaml pubspec.lock test/load_from_url_bytes_test.dart
git commit -m "test: add failing tests for loadFromBytes and loadFromUrl"
```

---

### Task 2: Implement `loadFromBytes` and `_loadFromBytesWithExtension`

**Files:**
- Modify: `lib/src/loop_audio_player.dart`

**Step 1: Add imports at the top of `loop_audio_player.dart`**

The current imports are:
```dart
import 'dart:async';
import 'package:flutter/services.dart';
import 'loop_audio_state.dart';
```

Replace with:
```dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'loop_audio_state.dart';
```

**Step 2: Add `loadFromBytes` and `_loadFromBytesWithExtension` to `LoopAudioPlayer`**

Insert these two methods after `loadFromFile` (after line 100 in the current file):

```dart
  /// Loads audio from raw bytes already in memory (e.g. from `dart:io`, a
  /// network response body, or generated audio data).
  ///
  /// The bytes are written to a temporary file with the given [extension] hint
  /// (default `'wav'`), loaded via the native engine, then the temporary file
  /// is deleted.
  ///
  /// Throws [PlatformException] on native decode or engine error.
  Future<void> loadFromBytes(Uint8List bytes, {String extension = 'wav'}) async {
    _checkNotDisposed();
    await _loadFromBytesWithExtension(bytes, extension);
  }

  /// Writes [bytes] to a temp file with the given [extension], calls
  /// [loadFromFile], then deletes the temp file unconditionally.
  Future<void> _loadFromBytesWithExtension(
      Uint8List bytes, String extension) async {
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final tmp = File(
        '${Directory.systemTemp.path}/flutter_gapless_$timestamp.$extension');
    try {
      await tmp.writeAsBytes(bytes, flush: true);
      await loadFromFile(tmp.path);
    } finally {
      if (await tmp.exists()) await tmp.delete();
    }
  }
```

**Step 3: Run tests — expect `loadFromBytes` tests to pass, `loadFromUrl` tests still failing**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop
flutter test test/load_from_url_bytes_test.dart 2>&1 | grep -E "✓|✗|PASS|FAIL|error"
```

Expected: the 4 `loadFromBytes` tests pass; the 4 `loadFromUrl` tests fail with "method not found".

**Step 4: Commit**

```bash
git add lib/src/loop_audio_player.dart
git commit -m "feat: add loadFromBytes via temp file"
```

---

### Task 3: Implement `loadFromUrl`

**Files:**
- Modify: `lib/src/loop_audio_player.dart`

**Step 1: Add `loadFromUrl` method after `loadFromBytes`**

```dart
  /// Loads audio from an HTTP or HTTPS URL.
  ///
  /// The file is downloaded in full before playback begins, preserving
  /// sample-accurate gapless looping. The temporary file is deleted after load.
  ///
  /// The file extension is inferred from the URL path (e.g. `.wav`, `.mp3`).
  /// Falls back to `'wav'` if the URL has no recognisable extension.
  ///
  /// Throws [Exception] if the HTTP response status is not 2xx.
  /// Throws [PlatformException] on native decode or engine error.
  ///
  /// [httpClient] is optional and intended for testing. When omitted a default
  /// [http.Client] is created and closed after the request completes.
  Future<void> loadFromUrl(Uri uri, {http.Client? httpClient}) async {
    _checkNotDisposed();
    final client = httpClient ?? http.Client();
    try {
      final response = await client.get(uri);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw Exception('HTTP ${response.statusCode}: $uri');
      }
      final segments = uri.pathSegments;
      final lastSegment = segments.isNotEmpty ? segments.last : '';
      final dotIndex = lastSegment.lastIndexOf('.');
      final ext = (dotIndex >= 0 && dotIndex < lastSegment.length - 1)
          ? lastSegment.substring(dotIndex + 1)
          : 'wav';
      await _loadFromBytesWithExtension(response.bodyBytes, ext);
    } finally {
      if (httpClient == null) client.close();
    }
  }
```

**Step 2: Run all tests and verify all pass**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop
flutter test test/load_from_url_bytes_test.dart 2>&1 | grep -E "✓|✗|All tests|PASS|FAIL"
```

Expected: All 8 tests pass.

**Step 3: Run the full test suite to confirm no regressions**

```bash
flutter test 2>&1 | tail -5
```

Expected: All tests pass.

**Step 4: Commit**

```bash
git add lib/src/loop_audio_player.dart
git commit -m "feat: add loadFromUrl via HTTP download to temp file"
```

---

### Task 4: Final verification and analyze

**Step 1: Run `flutter analyze`**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop
flutter analyze lib/
```

Expected: `No issues found!`

**Step 2: Build the iOS example to verify no compilation issues**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop/example
flutter build ios --no-codesign 2>&1 | tail -5
```

Expected: build succeeds.

**Step 3: Commit if any cleanup needed, otherwise done**

```bash
cd /Users/litecode/Documents/Projects/Flutter/flutter_gapless_loop
git log --oneline -5
```

---

## Summary of Changes

| File | Change |
|------|--------|
| `pubspec.yaml` | Add `http: ^1.2.0` to `dependencies` |
| `lib/src/loop_audio_player.dart` | Add imports (`dart:io`, `dart:typed_data`, `http`); add `loadFromBytes`, `loadFromUrl`, `_loadFromBytesWithExtension` |
| `test/load_from_url_bytes_test.dart` | New file: 8 tests covering `loadFromBytes` and `loadFromUrl` |
