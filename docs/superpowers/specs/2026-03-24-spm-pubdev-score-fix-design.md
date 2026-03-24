# SPM pub.dev Score Fix — Design Spec

## Problem

pub.dev reports "Package does not support the Swift Package Manager on iOS" and "Package does not support the Swift Package Manager on macOS", resulting in a partial score. The plugin already has `darwin/Package.swift` and `sharedDarwinSource: true` in `pubspec.yaml`, but pana (pub.dev's scoring tool) checks for a `Sources/{plugin_name}/` directory layout — not just `Package.swift` presence. Because Swift sources live in `darwin/Classes/` rather than `darwin/Sources/flutter_gapless_loop/`, pana cannot confirm SPM support.

## Goal

Fix the pub.dev SPM score by moving Swift sources to the Flutter-standard SPM layout (`darwin/Sources/flutter_gapless_loop/`) and updating all references accordingly.

## Scope

- **In scope:** Rename source directory, update `Package.swift`, update both podspecs, bump podspec versions.
- **Out of scope:** Any changes to Swift source files, CMake/Android/Windows/Linux build files, or the Dart layer.

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
        .library(name: "flutter-gapless-loop", targets: ["flutter_gapless_loop"]),
    ],
    targets: [
        .target(
            name: "flutter_gapless_loop",
            path: "Sources/flutter_gapless_loop"
        ),
    ]
)
```

Changes from current:
- Product name: `"flutter_gapless_loop"` → `"flutter-gapless-loop"` (Flutter convention: hyphenated product names)
- Target path: `"Classes"` → `"Sources/flutter_gapless_loop"`

### 3. `ios/flutter_gapless_loop.podspec`

- `s.source_files`: `'../darwin/Classes/**/*'` → `'../darwin/Sources/flutter_gapless_loop/**/*'`
- `s.version`: `'0.0.7'` → `'0.0.9'`

### 4. `darwin/flutter_gapless_loop.podspec`

- `s.source_files`: `'Classes/**/*'` → `'Sources/flutter_gapless_loop/**/*'`
- `s.version`: `'0.0.7'` → `'0.0.9'`

## Compatibility

- **SPM (Flutter 3.27+):** Uses new standard layout; pana recognises SPM support. ✅
- **CocoaPods (fallback):** Both podspecs updated to new path; existing CocoaPods users unaffected. ✅
- **Swift sources:** Zero changes — rename only. ✅
- **Other platforms (Android, Windows, Linux, Web):** No changes. ✅

## Testing

1. Run `pod lib lint ios/flutter_gapless_loop.podspec` — should pass.
2. Run `pod lib lint darwin/flutter_gapless_loop.podspec` — should pass.
3. Build the `example/` app on iOS Simulator and macOS to confirm SPM resolution works.
4. After publishing 0.0.9 to pub.dev, verify the SPM score shows green for both iOS and macOS.
