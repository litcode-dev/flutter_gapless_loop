# URL and Bytes Loading — Design

**Date:** 2026-03-05
**Status:** Approved

## Overview

Add two new loading methods to `LoopAudioPlayer`: `loadFromUrl(Uri)` and `loadFromBytes(Uint8List, {String extension})`. Both funnel into the existing `loadFromFile` path — zero native changes required.

## Architecture

All new logic lives in Dart. Both methods share a private `_writeToTempFile` helper:

```
loadFromUrl(uri)   →  http.get(uri)  →  _writeToTempFile(bytes, ext)  →  loadFromFile(path)
loadFromBytes(bytes, ext)            →  _writeToTempFile(bytes, ext)  →  loadFromFile(path)
```

**Temp file lifecycle:**
- Written to `Directory.systemTemp` as `flutter_gapless_<timestamp>.<ext>`
- Extension is inferred from the URL path for `loadFromUrl`, or from the `extension` parameter for `loadFromBytes`
- Deleted in a `try/finally` block after `loadFromFile` returns (success or failure)
- The engine has already decoded the full buffer into memory before deletion

**New dependency:** `http: ^1.2.0` added to `dependencies` in `pubspec.yaml`.

## API

```dart
/// Loads audio from an HTTP or HTTPS URL.
///
/// Downloads the file in full before playback begins, preserving sample-accurate
/// gapless looping. The temporary file is deleted after load.
///
/// Throws [Exception] if the HTTP response is not 2xx.
/// Throws [PlatformException] on native decode/engine error.
Future<void> loadFromUrl(Uri uri) async

/// Loads audio from raw bytes already in memory (e.g. from http package,
/// file system, or generated audio).
///
/// Bytes are written to a temp file with the given [extension] hint (default
/// 'wav'), loaded, then the temp file is deleted.
///
/// Throws [PlatformException] on native decode/engine error.
Future<void> loadFromBytes(Uint8List bytes, {String extension = 'wav'}) async
```

`loadFromUrl` takes `Uri` (not `String`) for Dart idiom consistency.

## Error Handling

| Scenario | Behaviour |
|----------|-----------|
| HTTP response not 2xx | Throw `Exception('HTTP ${response.statusCode}: $uri')` before writing temp file |
| Disk write fails | Exception propagates; `loadFromFile` never called; engine unchanged |
| `loadFromFile` throws | Temp file deleted in `finally`; exception re-thrown to caller |
| Network error | `http` package exception propagates naturally |

## Testing

Dart unit tests only (no native changes to test):

- `loadFromUrl`: mock `http.Client`; verify `loadFromFile` called with temp path of correct extension
- `loadFromUrl` non-2xx: verify exception thrown, `loadFromFile` not called
- `loadFromBytes`: verify temp file written and deleted, `loadFromFile` called
- `loadFromBytes` custom extension: verify temp file has correct extension

## Files Changed

| File | Change |
|------|--------|
| `pubspec.yaml` | Add `http: ^1.2.0` to `dependencies` |
| `lib/src/loop_audio_player.dart` | Add `loadFromUrl`, `loadFromBytes`, `_writeToTempFile` |
| `lib/flutter_gapless_loop.dart` | Re-export `dart:typed_data` not needed — `Uint8List` comes from `dart:typed_data` which must be imported by caller |
| `test/loop_audio_player_test.dart` | New test file with 4 test cases |

## Non-goals

- Download progress events — not requested
- Cancellation of in-flight downloads — not requested
- Streaming/progressive decode — requires engine architecture changes, out of scope
- Caching downloaded files across loads — out of scope
