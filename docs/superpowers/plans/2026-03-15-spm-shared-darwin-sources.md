# SPM + Shared Darwin Sources Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Consolidate duplicated iOS/macOS Swift sources into `darwin/Classes/`, add a `darwin/Package.swift` SPM manifest, and wire both podspecs and `pubspec.yaml` to the new location — eliminating ~1700 lines of duplicated code while preserving CocoaPods builds.

**Architecture:** All five Swift source files move to `darwin/Classes/`. Three files are platform-agnostic and are copied as-is. `LoopAudioEngine.swift` uses a full `#if os(iOS)` / `#else` / `#endif` split. `FlutterGaplessLoopPlugin.swift` is ~99% shared with three targeted platform guards (imports, `messengerBridge` extension, `detachFromEngine`). Both podspecs update their `source_files` path; `pubspec.yaml` adds `sharedDarwinSource: true`.

**Tech Stack:** Swift 5.9, Swift Package Manager (`swift-tools-version: 5.9`), CocoaPods, Flutter plugin tooling (≥ 3.24).

---

## File Map

| Action | Path | Purpose |
|--------|------|---------|
| Create dir | `darwin/Classes/` | New shared source location |
| Create | `darwin/Classes/CrossfadeEngine.swift` | Identical copy from iOS |
| Create | `darwin/Classes/BpmDetector.swift` | Copied from macOS (no guards needed) |
| Create | `darwin/Classes/MetronomeEngine.swift` | Copied from macOS (no guards needed) |
| Create | `darwin/Classes/LoopAudioEngine.swift` | iOS impl under `#if os(iOS)`, macOS under `#else` |
| Create | `darwin/Classes/FlutterGaplessLoopPlugin.swift` | macOS base + 3 targeted iOS guards |
| Create | `darwin/Package.swift` | SPM manifest for both platforms |
| Modify | `ios/flutter_gapless_loop.podspec` | `source_files` → `../darwin/Classes/**/*` |
| Modify | `macos/flutter_gapless_loop.podspec` | `source_files` → `../darwin/Classes/**/*` |
| Modify | `pubspec.yaml` | `sharedDarwinSource: true`, flutter `>=3.24.0` |
| Delete | `ios/Classes/` | Replaced by `darwin/Classes/` |
| Delete | `macos/Classes/` | Replaced by `darwin/Classes/` |

---

## Chunk 1: Create darwin/Classes/ and Package.swift

Create the shared directory and populate the three platform-agnostic source files plus the SPM manifest.

### Task 1: Record test baseline

**Files:** none (read-only verification)

- [ ] **Step 1: Run Android tests**

```bash
cd example/android && ./gradlew :flutter_gapless_loop:test
```
Expected: `BUILD SUCCESSFUL`

- [ ] **Step 2: Run Dart tests**

```bash
# From repo root
flutter test --no-pub 2>&1 | tail -3
```
Expected: output ending with something like `+61 -5: Some tests failed.` — note the exact counts. The 5 pre-existing failures are unrelated to this migration; they must not increase.

---

### Task 2: Create darwin/Classes/ directory

**Files:**
- Create dir: `darwin/Classes/`

- [ ] **Step 1: Create the directory**

```bash
mkdir -p darwin/Classes
```

- [ ] **Step 2: Confirm it exists**

```bash
ls darwin/
```
Expected: `Classes`

---

### Task 3: Copy CrossfadeEngine.swift (identical on both platforms)

**Files:**
- Create: `darwin/Classes/CrossfadeEngine.swift`

- [ ] **Step 1: Copy from iOS (they are byte-for-byte identical)**

```bash
cp ios/Classes/CrossfadeEngine.swift darwin/Classes/CrossfadeEngine.swift
```

- [ ] **Step 2: Verify the copy is identical to the macOS version**

```bash
diff darwin/Classes/CrossfadeEngine.swift macos/Classes/CrossfadeEngine.swift && echo "IDENTICAL"
```
Expected: `IDENTICAL`

---

### Task 4: Copy BpmDetector.swift from macOS

The macOS version has no unnecessary `#if os(iOS)` wrapper and uses the correct `_` for the unused tuple element. It is pure signal-processing math — no platform-specific APIs.

**Files:**
- Create: `darwin/Classes/BpmDetector.swift`

- [ ] **Step 1: Copy from macOS**

```bash
cp macos/Classes/BpmDetector.swift darwin/Classes/BpmDetector.swift
```

- [ ] **Step 2: Verify no platform-specific imports**

```bash
head -5 darwin/Classes/BpmDetector.swift
```
Expected: first few lines are `import AVFoundation`, `import Accelerate`, etc. — no `import Flutter` or `#if os(iOS)`.

---

### Task 5: Copy MetronomeEngine.swift from macOS

The macOS version has no unnecessary `#if os(iOS)` wrapper. Uses only AVFoundation APIs common to both platforms (`AVAudioEngine`, `AVAudioPlayerNode`, `AVAudioPCMBuffer`).

**Files:**
- Create: `darwin/Classes/MetronomeEngine.swift`

- [ ] **Step 1: Copy from macOS**

```bash
cp macos/Classes/MetronomeEngine.swift darwin/Classes/MetronomeEngine.swift
```

- [ ] **Step 2: Verify no platform-specific imports**

```bash
head -5 darwin/Classes/MetronomeEngine.swift
```
Expected: first few lines do not contain `import Flutter`, `import UIKit`, or `#if os(iOS)`.

---

### Task 6: Create darwin/Package.swift

**Files:**
- Create: `darwin/Package.swift`

- [ ] **Step 1: Write the SPM manifest**

Create `darwin/Package.swift` with this exact content:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "flutter_gapless_loop",
    platforms: [
        .iOS("14.0"),
        .macOS("11.0"),
    ],
    products: [
        .library(name: "flutter_gapless_loop", targets: ["flutter_gapless_loop"]),
    ],
    targets: [
        .target(
            name: "flutter_gapless_loop",
            path: "Classes"
        ),
    ]
)
```

- [ ] **Step 2: Verify the file exists**

```bash
cat darwin/Package.swift
```
Expected: content as written above.

> **SPM build-time note:** During `flutter build ios` or `flutter build macos` with SPM enabled, Flutter's tooling generates a local `FlutterFramework` package. If the build fails with `"no such module 'Flutter'"`, add a `FlutterFramework` dependency to this Package.swift:
>
> ```swift
> dependencies: [
>     .package(name: "FlutterFramework", path: "../FlutterFramework"),
> ],
> targets: [
>     .target(
>         name: "flutter_gapless_loop",
>         dependencies: [
>             .product(name: "FlutterFramework", package: "FlutterFramework"),
>         ],
>         path: "Classes"
>     ),
> ]
> ```
>
> A `"no such local package 'FlutterFramework'"` error outside a Flutter build context is expected and harmless.

---

### Task 7: Commit Chunk 1

- [ ] **Step 1: Stage and commit**

```bash
git add darwin/
git commit -m "feat: add darwin/Classes/ with shared Swift sources and Package.swift"
```

---

## Chunk 2: Merged LoopAudioEngine and FlutterGaplessLoopPlugin

These two files have platform-specific code and must be merged using conditional compilation guards.

### Task 8: Create merged LoopAudioEngine.swift

The iOS file (`ios/Classes/LoopAudioEngine.swift`, 960 lines) already wraps its entire content in `#if os(iOS)` … `#endif // os(iOS)`. The macOS file (`macos/Classes/LoopAudioEngine.swift`, 780 lines) has no guard. The merged file places the iOS implementation under `#if os(iOS)` and the macOS implementation under `#else`.

**Files:**
- Create: `darwin/Classes/LoopAudioEngine.swift`

- [ ] **Step 1: Copy the iOS file as base**

```bash
cp ios/Classes/LoopAudioEngine.swift darwin/Classes/LoopAudioEngine.swift
```

The iOS file's last line is `#endif // os(iOS)`. We will replace it with `#else` + macOS content + `#endif`.

- [ ] **Step 2: Remove the closing iOS guard and append the macOS implementation**

```bash
# Remove last line (#endif // os(iOS)) from the copy
head -n -1 darwin/Classes/LoopAudioEngine.swift > /tmp/merge_loop.swift

# Insert #else separator
echo "" >> /tmp/merge_loop.swift
echo "#else" >> /tmp/merge_loop.swift
echo "" >> /tmp/merge_loop.swift

# Append the full macOS implementation
cat macos/Classes/LoopAudioEngine.swift >> /tmp/merge_loop.swift

# Close the conditional block
echo "" >> /tmp/merge_loop.swift
echo "#endif // os(iOS)" >> /tmp/merge_loop.swift

# Replace the working file
mv /tmp/merge_loop.swift darwin/Classes/LoopAudioEngine.swift
```

- [ ] **Step 3: Verify structure — check first and last 5 lines**

```bash
head -3 darwin/Classes/LoopAudioEngine.swift
echo "..."
tail -5 darwin/Classes/LoopAudioEngine.swift
```
Expected:
- First line: `#if os(iOS)`
- Last line: `#endif // os(iOS)`
- Second-to-last lines include `}` (closing macOS class) then the `#endif`

- [ ] **Step 4: Verify the #else separator is present**

```bash
grep -n "^#else$\|^#endif // os(iOS)$" darwin/Classes/LoopAudioEngine.swift
```
Expected: exactly one `#else` line (around line 959) and one `#endif // os(iOS)` line at the end.

- [ ] **Step 5: Verify line count is approximately correct**

```bash
wc -l darwin/Classes/LoopAudioEngine.swift
```
Expected: approximately 1745 lines (960 iOS + 780 macOS + ~5 separator lines).

---

### Task 9: Create merged FlutterGaplessLoopPlugin.swift

Start from the macOS file (538 lines, no outer guard) and apply three targeted edits:
1. Replace the 3 import lines with conditional imports + file-scope `messengerBridge` extension
2. Remove the macOS-specific comment inside `register(with:)` and replace all `registrar.messenger` channel calls with `registrar.messengerBridge`
3. Add the `detachFromEngine` override (iOS-only) between `register(with:)` and `// MARK: - FlutterStreamHandler`

**Files:**
- Create: `darwin/Classes/FlutterGaplessLoopPlugin.swift`

- [ ] **Step 1: Copy macOS file as base**

```bash
cp macos/Classes/FlutterGaplessLoopPlugin.swift darwin/Classes/FlutterGaplessLoopPlugin.swift
```

- [ ] **Step 2: Replace imports with conditional imports + messengerBridge extension**

Use the Edit tool to replace the first three import lines (and the following blank line + MARK comment) with the conditional block. The `old_string` is:

```swift
import FlutterMacOS
import AVFoundation
import os.log

// MARK: - MetronomeStreamHandler
```

The `new_string` is:

```swift
#if os(iOS)
import Flutter
import UIKit
#else
import FlutterMacOS
#endif
import AVFoundation
import os.log

// File-scope — must be outside any class or function body.
#if os(iOS)
private extension FlutterPluginRegistrar {
    var messengerBridge: FlutterBinaryMessenger { messenger() }
}
#else
private extension FlutterPluginRegistrar {
    var messengerBridge: FlutterBinaryMessenger { messenger }
}
#endif

// MARK: - MetronomeStreamHandler
```

- [ ] **Step 3: Remove the macOS-only comment inside register(with:)**

Use the Edit tool. The `old_string` is:

```swift
    public static func register(with registrar: FlutterPluginRegistrar) {
        // On macOS, `registrar.messenger` is a property (not a method call).
        let methodChannel = FlutterMethodChannel(
```

The `new_string` is:

```swift
    public static func register(with registrar: FlutterPluginRegistrar) {
        let methodChannel = FlutterMethodChannel(
```

- [ ] **Step 4: Replace all four `registrar.messenger` channel calls with `registrar.messengerBridge`**

Use the Edit tool with `replace_all: true`. The `old_string` is:

```swift
            binaryMessenger: registrar.messenger
```

The `new_string` is:

```swift
            binaryMessenger: registrar.messengerBridge
```

- [ ] **Step 5: Verify exactly 4 replacements occurred**

```bash
grep -c "registrar.messengerBridge" darwin/Classes/FlutterGaplessLoopPlugin.swift
```
Expected: `4`

```bash
grep -c "registrar.messenger[^B]" darwin/Classes/FlutterGaplessLoopPlugin.swift
```
Expected: `0` (no remaining unguarded `registrar.messenger` calls)

- [ ] **Step 6: Add the iOS-only detachFromEngine override**

Use the Edit tool. The `old_string` is the closing lines of `register(with:)` and the start of the next MARK:

```swift
        metronomeEventChannel.setStreamHandler(instance.metronomeStreamHandler)
    }

    // MARK: - FlutterStreamHandler (loop player)
```

The `new_string` is:

```swift
        metronomeEventChannel.setStreamHandler(instance.metronomeStreamHandler)
    }

    // MARK: - FlutterPlugin Lifecycle

#if os(iOS)
    /// Called when the engine detaches (hot-restart). Resets the one-time session-configuration
    /// guard so the next engine instance can reconfigure AVAudioSession cleanly.
    public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
        engines.values.forEach    { $0.dispose() }
        engines.removeAll()
        metronomes.values.forEach { $0.dispose() }
        metronomes.removeAll()
        LoopAudioEngine.sessionConfigured = false
        logger.info("Plugin detached — session config flag reset")
    }
#endif

    // MARK: - FlutterStreamHandler (loop player)
```

- [ ] **Step 7: Verify detachFromEngine guard exists**

```bash
grep -n "#if os(iOS)\|detachFromEngine\|#endif" darwin/Classes/FlutterGaplessLoopPlugin.swift | head -20
```
Expected: shows `#if os(iOS)` before `detachFromEngine` and a matching `#endif` immediately after the closing `}` of the method.

- [ ] **Step 8: Verify file does NOT start with #if os(iOS) (no outer guard)**

```bash
head -3 darwin/Classes/FlutterGaplessLoopPlugin.swift
```
Expected: first line is `#if os(iOS)` (the imports guard), second line is `import Flutter` — but there is NO single `#if os(iOS)` wrapping the entire file. The first guard is the imports block, not a file-level wrapper.

> **Correction:** Line 1 IS `#if os(iOS)` — that is the imports conditional block. What must NOT exist is the macOS version's entire content being skipped. To be precise: verify that `MetronomeStreamHandler` class definition appears within the first 50 lines (meaning it is not guarded away):

```bash
grep -n "class MetronomeStreamHandler" darwin/Classes/FlutterGaplessLoopPlugin.swift
```
Expected: line number in the range 20–35 (after imports + extension, before the class body).

---

### Task 10: Commit Chunk 2

- [ ] **Step 1: Stage and commit**

```bash
git add darwin/Classes/LoopAudioEngine.swift darwin/Classes/FlutterGaplessLoopPlugin.swift
git commit -m "feat: add merged LoopAudioEngine and FlutterGaplessLoopPlugin with platform guards"
```

---

## Chunk 3: Wire podspecs, pubspec.yaml, delete old directories, verify

### Task 11: Update ios/flutter_gapless_loop.podspec

Change `source_files` to point to the shared darwin directory.

**Files:**
- Modify: `ios/flutter_gapless_loop.podspec`

- [ ] **Step 1: Update source_files**

Use the Edit tool:

`old_string`:
```ruby
  s.source_files = 'Classes/**/*'
```

`new_string`:
```ruby
  s.source_files = '../darwin/Classes/**/*'
```

- [ ] **Step 2: Verify**

```bash
grep "source_files" ios/flutter_gapless_loop.podspec
```
Expected: `s.source_files = '../darwin/Classes/**/*'`

---

### Task 12: Update macos/flutter_gapless_loop.podspec

**Files:**
- Modify: `macos/flutter_gapless_loop.podspec`

- [ ] **Step 1: Update source_files**

Use the Edit tool:

`old_string`:
```ruby
  s.source_files = 'Classes/**/*'
```

`new_string`:
```ruby
  s.source_files = '../darwin/Classes/**/*'
```

- [ ] **Step 2: Verify**

```bash
grep "source_files" macos/flutter_gapless_loop.podspec
```
Expected: `s.source_files = '../darwin/Classes/**/*'`

---

### Task 13: Update pubspec.yaml

Add `sharedDarwinSource: true` to both iOS and macOS platform entries and bump the Flutter minimum constraint.

**Files:**
- Modify: `pubspec.yaml`

- [ ] **Step 1: Bump Flutter minimum and add sharedDarwinSource**

Use the Edit tool:

`old_string`:
```yaml
  flutter: '>=3.3.0'
```

`new_string`:
```yaml
  flutter: '>=3.24.0'
```

- [ ] **Step 2: Add sharedDarwinSource to iOS platform entry**

Use the Edit tool:

`old_string`:
```yaml
      ios:
        pluginClass: FlutterGaplessLoopPlugin
      android:
```

`new_string`:
```yaml
      ios:
        pluginClass: FlutterGaplessLoopPlugin
        sharedDarwinSource: true
      android:
```

- [ ] **Step 3: Add sharedDarwinSource to macOS platform entry**

Use the Edit tool:

`old_string`:
```yaml
      macos:
        pluginClass: FlutterGaplessLoopPlugin
      windows:
```

`new_string`:
```yaml
      macos:
        pluginClass: FlutterGaplessLoopPlugin
        sharedDarwinSource: true
      windows:
```

- [ ] **Step 4: Verify pubspec.yaml**

```bash
grep -A2 "ios:\|macos:" pubspec.yaml | grep -E "pluginClass|sharedDarwinSource|flutter:"
```
Expected: shows `sharedDarwinSource: true` under both `ios:` and `macos:` entries, and the flutter constraint shows `>=3.24.0`.

---

### Task 14: Delete old platform-specific Classes/ directories

Only delete after confirming `darwin/Classes/` has all 5 files.

**Files:**
- Delete: `ios/Classes/`
- Delete: `macos/Classes/`

- [ ] **Step 1: Confirm darwin/Classes/ has all 5 expected Swift files**

```bash
ls darwin/Classes/
```
Expected exactly:
```
BpmDetector.swift
CrossfadeEngine.swift
FlutterGaplessLoopPlugin.swift
LoopAudioEngine.swift
MetronomeEngine.swift
```

- [ ] **Step 2: Delete ios/Classes/**

```bash
git rm -r ios/Classes/
```

- [ ] **Step 3: Delete macos/Classes/**

```bash
git rm -r macos/Classes/
```

- [ ] **Step 4: Verify deleted**

```bash
ls ios/ && echo "---" && ls macos/
```
Expected: only `flutter_gapless_loop.podspec` remains in each directory (no `Classes/` subdirectory).

---

### Task 15: Run flutter pub get

- [ ] **Step 1: Run pub get to validate pubspec changes**

```bash
flutter pub get
```
Expected: exits 0 with no errors. If it complains about `sharedDarwinSource`, verify the exact spelling in `pubspec.yaml` matches `sharedDarwinSource` (camelCase).

---

### Task 16: Verify Android tests still pass

The Android Kotlin sources are untouched. This confirms the migration did not accidentally affect the project structure.

- [ ] **Step 1: Run Android unit tests**

```bash
cd example/android && ./gradlew :flutter_gapless_loop:test
```
Expected: `BUILD SUCCESSFUL`

---

### Task 17: Verify Dart tests unchanged

- [ ] **Step 1: Run Dart tests**

```bash
# From repo root
flutter test --no-pub 2>&1 | tail -3
```
Expected: same pass/fail counts as the baseline recorded in Task 1. The 5 pre-existing failures must not increase.

---

### Task 18: Verify CocoaPods build

- [ ] **Step 1: Run flutter pub get in example app**

```bash
cd example && flutter pub get
```

- [ ] **Step 2: Run pod install for iOS**

```bash
cd example/ios && pod install --repo-update 2>&1 | tail -10
```
Expected: no errors. Pod `flutter_gapless_loop` should resolve to sources from `../darwin/Classes/`. If CocoaPods cannot find sources, check that the relative path `../darwin/Classes/**/*` is correct from `ios/`.

- [ ] **Step 3: Run pod install for macOS**

```bash
cd example/macos && pod install --repo-update 2>&1 | tail -10
```
Expected: no errors.

---

### Task 19: Final commit

- [ ] **Step 1: Stage all remaining changes and commit**

```bash
# From repo root
git add ios/flutter_gapless_loop.podspec macos/flutter_gapless_loop.podspec pubspec.yaml
git status
git commit -m "feat: wire darwin/ shared sources to podspecs and pubspec, drop ios/Classes and macos/Classes"
```

---

## Post-migration: SPM Smoke Test (optional, requires Flutter ≥ 3.24)

If SPM testing is available, verify the SPM path works end-to-end.

- [ ] **Enable SPM in Flutter config**

```bash
flutter config --enable-swift-package-manager
```

- [ ] **Build the example app for iOS**

```bash
cd example && flutter build ios --no-codesign 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED. If `"no such module 'Flutter'"` appears, add the `FlutterFramework` dependency to `darwin/Package.swift` as documented in Task 6.

- [ ] **Build the example app for macOS**

```bash
cd example && flutter build macos 2>&1 | tail -20
```
Expected: BUILD SUCCEEDED.

- [ ] **Restore CocoaPods as default (if desired)**

```bash
flutter config --no-enable-swift-package-manager
```

---

## Spec Reference

`docs/superpowers/specs/2026-03-15-spm-shared-darwin-sources-design.md`
