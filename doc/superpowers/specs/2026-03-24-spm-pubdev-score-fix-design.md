# SPM pub.dev Score Fix — Design Spec

## Problem

pub.dev reports "Package does not support the Swift Package Manager on iOS" and "Package does not support the Swift Package Manager on macOS", resulting in a partial score. The plugin already has `darwin/Package.swift` and `sharedDarwinSource: true` in `pubspec.yaml`, but pana (pub.dev's scoring tool) checks for a `Sources/{plugin_name}/` directory layout — not just `Package.swift` presence. Because Swift sources live in `darwin/Classes/` rather than `darwin/Sources/flutter_gapless_loop/`, pana cannot confirm SPM support.

## Goal

Fix the pub.dev SPM score by moving Swift sources to the Flutter-standard SPM layout (`darwin/Sources/flutter_gapless_loop/`) and updating all references accordingly.

## Scope

- **In scope:** Rename source directory, update `Package.swift` target path, update all three podspecs, bump podspec versions to match `pubspec.yaml`.
- **Out of scope:** Any changes to Swift source files, CMake/Android/Windows/Linux build files, or the Dart layer. `pubspec.yaml` requires no changes — it already has `sharedDarwinSource: true` on both `ios` and `macos` entries and `version: 0.0.9`.

## File Changes

### 1. Rename directory

```
darwin/Classes/  →  darwin/Sources/flutter_gapless_loop/
```

All 5 Swift files move together: `BpmDetector.swift`, `CrossfadeEngine.swift`, `FlutterGaplessLoopPlugin.swift`, `LoopAudioEngine.swift`, `MetronomeEngine.swift`.

### 2. `darwin/Package.swift`

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
            path: "Sources/flutter_gapless_loop"
        ),
    ]
)
```

Only change from current: target `path` value `"Classes"` → `"Sources/flutter_gapless_loop"`. The product name stays as `"flutter_gapless_loop"` (underscores) — Flutter's SPM integration resolves plugins by plugin class name, not SPM product name, so the product name is irrelevant to the pana fix and is left unchanged to avoid any breakage risk.

### 3. `ios/flutter_gapless_loop.podspec`

- `s.source_files`: `'../darwin/Classes/**/*'` → `'../darwin/Sources/flutter_gapless_loop/**/*'`
- `s.version`: `'0.0.7'` → `'0.0.9'`

### 4. `macos/flutter_gapless_loop.podspec`

- `s.source_files`: `'../darwin/Classes/**/*'` → `'../darwin/Sources/flutter_gapless_loop/**/*'`
- `s.version`: `'0.0.7'` → `'0.0.9'`

### 5. `darwin/flutter_gapless_loop.podspec`

- `s.source_files`: `'Classes/**/*'` → `'Sources/flutter_gapless_loop/**/*'`
- `s.version`: `'0.0.7'` → `'0.0.9'`

**Note on version numbers:** All three podspecs are at `0.0.7`. `pubspec.yaml` is already at `0.0.9` (0.0.8 was a Dart/Swift fix release that did not touch the podspec versions). This change brings all three podspecs into sync with `pubspec.yaml` at `0.0.9`.

## Compatibility

- **SPM (Flutter 3.27+):** Uses standard layout; pana recognises SPM support. ✅
- **CocoaPods (fallback):** All three podspecs updated to new path; CocoaPods users who run `pod install` after upgrading will get the new path. ✅
- **Swift sources:** Zero changes — rename only. ✅
- **Other platforms (Android, Windows, Linux, Web):** No changes. ✅

## Testing

1. Run `swift package --package-path darwin clean && swift package --package-path darwin build` — cleans any stale `darwin/.build/` artifacts from the old `Classes/` path, then verifies `Package.swift` resolves the new path cleanly.
2. Run `pod lib lint ios/flutter_gapless_loop.podspec` — should pass.
3. Run `pod lib lint macos/flutter_gapless_loop.podspec` — should pass.
4. Run `pod lib lint darwin/flutter_gapless_loop.podspec` — should pass.
5. Build the `example/` app on iOS Simulator and macOS to confirm SPM resolution works end-to-end.
6. After publishing 0.0.9 to pub.dev, verify the SPM score shows green for both iOS and macOS.
