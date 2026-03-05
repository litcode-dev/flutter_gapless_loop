# Native URL Loading Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Move HTTP download logic from Dart into the native iOS and Android layers so `loadFromUrl` uses platform networking (URLSession / HttpURLConnection) with zero third-party Dart dependencies.

**Architecture:** Dart calls `invokeMethod('loadUrl', {'url': '...'})`. Each native plugin downloads the URL to a temp file using the platform HTTP client, then reuses the existing `loadFile` path. Temp file is deleted after `loadFile` returns (success or failure). The Dart method loses its `fetcher` injector and becomes a plain one-liner.

**Tech Stack:** Swift `URLSession` (iOS), Kotlin `HttpURLConnection` + coroutines (Android), Flutter `MethodChannel`.

---

### Task 1: iOS — add `loadUrl` case to `FlutterGaplessLoopPlugin.swift`

**Files:**
- Modify: `ios/Classes/FlutterGaplessLoopPlugin.swift` — add `case "loadUrl":` before the `default:` case (around line 336)

**Step 1: Write the implementation**

Insert immediately before `default:` in the `switch call.method` block:

```swift
// MARK: Load from HTTP/HTTPS URL
case "loadUrl":
    guard let urlString = args?["url"] as? String,
          let remoteURL = URL(string: urlString) else {
        DispatchQueue.main.async { result(FlutterError(
            code: "INVALID_ARGS",
            message: "'url' is required and must be a valid URL",
            details: nil
        )) }
        return
    }
    let task = URLSession.shared.dataTask(with: remoteURL) { [weak self] data, response, error in
        guard let self else { return }
        if let error {
            DispatchQueue.main.async { result(FlutterError(
                code: "DOWNLOAD_FAILED",
                message: error.localizedDescription,
                details: nil
            )) }
            return
        }
        if let http = response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            DispatchQueue.main.async { result(FlutterError(
                code: "DOWNLOAD_FAILED",
                message: "HTTP \(http.statusCode): \(urlString)",
                details: nil
            )) }
            return
        }
        guard let data else {
            DispatchQueue.main.async { result(FlutterError(
                code: "DOWNLOAD_FAILED",
                message: "No data received from \(urlString)",
                details: nil
            )) }
            return
        }
        // Infer file extension from URL path; fall back to "wav".
        let ext = remoteURL.pathExtension.isEmpty ? "wav" : remoteURL.pathExtension
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("flutter_gapless_\(Int(Date().timeIntervalSince1970*1000)).\(ext)")
        do {
            try data.write(to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }
            try eng.loadFile(url: tmp)
            DispatchQueue.main.async { result(nil) }
        } catch {
            self.logger.error("loadUrl failed: \(error.localizedDescription)")
            DispatchQueue.main.async { result(FlutterError(
                code: "LOAD_FAILED",
                message: error.localizedDescription,
                details: nil
            )) }
        }
    }
    task.resume()
```

**Step 2: Build check (iOS)**

```bash
cd example && flutter build ios --simulator --no-codesign 2>&1 | tail -20
```
Expected: exits 0, no Swift compile errors.

**Step 3: Commit**

```bash
git add ios/Classes/FlutterGaplessLoopPlugin.swift
git commit -m "feat(ios): add native loadUrl via URLSession"
```

---

### Task 2: Android — add `loadUrl` case to `FlutterGaplessLoopPlugin.kt`

**Files:**
- Modify: `android/src/main/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPlugin.kt` — add `"loadUrl"` branch inside `when (call.method)` (after the `"loadAsset"` block, before `"play"`)

**Step 1: Add import** (top of file, if not already present)

`java.net.HttpURLConnection` and `java.net.URL` are already in `java.net.*` — no explicit import needed in Kotlin.

Also add (if not present):
```kotlin
import kotlinx.coroutines.withContext
```
This is already used transitively — check if it needs adding at top.

**Step 2: Write the implementation**

Insert after the `"loadAsset" ->` block, before `"play"`:

```kotlin
// ── Load from HTTP/HTTPS URL ──────────────────────────────────────
"loadUrl" -> {
    val urlString = call.argument<String>("url")
        ?: return result.error("INVALID_ARGS", "'url' is required", null)

    pluginScope.launch {
        val tempFile = withContext(Dispatchers.IO) {
            val url = java.net.URL(urlString)
            val conn = url.openConnection() as HttpURLConnection
            try {
                conn.connectTimeout = 15_000
                conn.readTimeout    = 30_000
                conn.connect()
                val status = conn.responseCode
                if (status !in 200..299) {
                    throw LoopAudioException(
                        LoopEngineError.DecodeFailed("HTTP $status: $urlString")
                    )
                }
                val ext = urlString.substringAfterLast('.', "wav")
                    .substringBefore('?')   // strip query params from extension
                    .take(10)               // sanity-cap
                    .ifEmpty { "wav" }
                val tmp = java.io.File(
                    binding?.applicationContext?.cacheDir,
                    "flutter_gapless_${System.currentTimeMillis()}.$ext"
                )
                conn.inputStream.use { input ->
                    tmp.outputStream().use { output -> input.copyTo(output) }
                }
                tmp
            } finally {
                conn.disconnect()
            }
        }
        try {
            eng.loadFile(tempFile.absolutePath)
            result.success(null)
        } catch (e: LoopAudioException) {
            result.error("LOAD_FAILED", e.message, null)
        } catch (e: Exception) {
            result.error("LOAD_FAILED", e.message, null)
        } finally {
            tempFile.delete()
        }
    }
}
```

Note: `binding` is already in scope as `pluginBinding`. Replace `binding` with `pluginBinding` if the compiler complains.

**Step 3: Build check (Android)**

```bash
cd example && flutter build apk --debug 2>&1 | tail -20
```
Expected: exits 0, no Kotlin compile errors.

**Step 4: Run existing Android unit tests**

```bash
cd android && ./gradlew test 2>&1 | tail -30
```
Expected: all 38 tests pass.

**Step 5: Commit**

```bash
git add android/src/main/kotlin/com/fluttergaplessloop/FlutterGaplessLoopPlugin.kt
git commit -m "feat(android): add native loadUrl via HttpURLConnection"
```

---

### Task 3: Dart — simplify `loadFromUrl` and remove `fetcher` injector

**Files:**
- Modify: `lib/src/loop_audio_player.dart` — replace `loadFromUrl` + `_defaultFetch` with a simple channel call

**Step 1: Remove `_defaultFetch` static method entirely**

Delete lines (search for `static Future<Uint8List> _defaultFetch`):
```swift
  static Future<Uint8List> _defaultFetch(Uri uri) async {
    final client = HttpClient();
    try {
      ...
    } finally {
      client.close();
    }
  }
```

**Step 2: Replace `loadFromUrl` method body**

Old:
```dart
  Future<void> loadFromUrl(Uri uri,
      {Future<Uint8List> Function(Uri)? fetcher}) async {
    _checkNotDisposed();
    final bytes = await (fetcher ?? _defaultFetch)(uri);
    final segments = uri.pathSegments;
    final lastSegment = segments.isNotEmpty ? segments.last : '';
    final dotIndex = lastSegment.lastIndexOf('.');
    final ext = (dotIndex >= 0 && dotIndex < lastSegment.length - 1)
        ? lastSegment.substring(dotIndex + 1)
        : 'wav';
    await _loadFromBytesWithExtension(bytes, ext);
  }
```

New:
```dart
  /// Loads audio from an HTTP or HTTPS [uri].
  ///
  /// The download is performed natively (URLSession on iOS,
  /// HttpURLConnection on Android) — no Dart HTTP client is used.
  /// The temporary file is deleted by the native layer after load.
  ///
  /// Throws [PlatformException] on download failure (non-2xx) or decode error.
  Future<void> loadFromUrl(Uri uri) async {
    _checkNotDisposed();
    await _channel.invokeMethod<void>('loadUrl', {'url': uri.toString()});
  }
```

**Step 3: Remove `dart:io` import if it's only needed for `HttpClient`**

Check the top of `loop_audio_player.dart`. `dart:io` is also used by `_loadFromBytesWithExtension` (uses `File`, `Directory`). Keep it — do NOT remove.

**Step 4: Verify the file compiles**

```bash
dart analyze lib/src/loop_audio_player.dart
```
Expected: No issues found.

**Step 5: Commit**

```bash
git add lib/src/loop_audio_player.dart
git commit -m "feat(dart): loadFromUrl delegates to native loadUrl channel method"
```

---

### Task 4: Update tests — replace `loadFromUrl` group with channel-mock test

**Files:**
- Modify: `test/load_from_url_bytes_test.dart`

**Context:** The old tests injected a `fetcher` lambda to avoid real HTTP. Now that networking is native, we can only unit-test the Dart side: that `loadFromUrl` calls `invokeMethod('loadUrl', {'url': ...})` with the right arguments. The 404/error path is now tested by native (integration) tests, not Dart unit tests.

**Step 1: Replace the entire `loadFromUrl` group**

Delete the old group and replace with:

```dart
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
```

**Step 2: Run tests**

```bash
flutter test test/load_from_url_bytes_test.dart
```
Expected: `All tests passed!`

**Step 3: Commit**

```bash
git add test/load_from_url_bytes_test.dart
git commit -m "test: update loadFromUrl tests to match native channel delegation"
```

---

### Task 5: Update MEMORY.md

**Files:**
- Modify: `/Users/litecode/.claude/projects/-Users-litecode-Documents-Projects-Flutter-flutter-gapless-loop/memory/MEMORY.md`

Update the `URL/Bytes Loading` section to reflect the new architecture:

```markdown
## URL/Bytes Loading
- `loadFromBytes(Uint8List, {extension})` — pure Dart via temp file.
- `loadFromUrl(Uri)` — delegates to native `loadUrl` channel method.
  - iOS: `URLSession.shared.dataTask` downloads to temp file → `loadFile`.
  - Android: `HttpURLConnection` on `Dispatchers.IO` downloads to `cacheDir` temp file → `loadFile`.
  - No Dart HTTP client or `http` package. No injectable fetcher.
```

Remove the `http: ^1.2.0` reference from the `Key Files` / dependency notes.

**Step 1: Edit the memory file**

Find the `## URL/Bytes Loading` section and replace it as shown above.

**Step 2: Verify the file looks right**

```bash
grep -A 6 "URL/Bytes" /Users/litecode/.claude/projects/-Users-litecode-Documents-Projects-Flutter-flutter-gapless-loop/memory/MEMORY.md
```

**Step 3: No commit needed** — memory files are not in the repo.
