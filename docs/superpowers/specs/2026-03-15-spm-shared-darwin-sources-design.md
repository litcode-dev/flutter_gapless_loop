# SPM + Shared Darwin Sources

**Date:** 2026-03-15
**Status:** Approved

## Goal

Add Swift Package Manager (SPM) support for the iOS and macOS targets while eliminating the duplicated Swift source files that exist in `ios/Classes/` and `macos/Classes/`. CocoaPods support is preserved.

---

## New Directory Structure

```
darwin/
  Classes/
    CrossfadeEngine.swift          # shared, no platform guards
    BpmDetector.swift              # shared, no platform guards
    MetronomeEngine.swift          # shared, no platform guards
    LoopAudioEngine.swift          # #if os(iOS) ... #else ... #endif
    FlutterGaplessLoopPlugin.swift # shared body, targeted guards
  Package.swift                    # SPM manifest

ios/
  flutter_gapless_loop.podspec    # s.source_files updated to ../darwin/Classes/**/*
  # Classes/ deleted

macos/
  flutter_gapless_loop.podspec    # s.source_files updated to ../darwin/Classes/**/*
  # Classes/ deleted
```

---

## File Merge Strategy

### CrossfadeEngine.swift
Copy the existing file as-is. Both iOS and macOS versions are byte-for-byte identical. No platform guards needed.

### BpmDetector.swift
Use the macOS version with no changes. The iOS version was unnecessarily wrapped in `#if os(iOS)` — it contains only pure signal-processing math with no platform-specific APIs. The differences from the iOS version are: (1) the `#if os(iOS)` wrapper, (2) `ac` vs `_` at the `autocorrelate` call site (macOS `_` is correct since the first return value is unused), and (3) one inline comment present in the iOS version but absent in the macOS version. All three differences are benign; using the macOS version as-is is correct.

### MetronomeEngine.swift
Use the macOS version with no changes. The iOS version was unnecessarily wrapped in `#if os(iOS)` — it uses only AVFoundation APIs (`AVAudioEngine`, `AVAudioPlayerNode`, `AVAudioPCMBuffer`) that are common to both platforms.

### LoopAudioEngine.swift
Keep the full `#if os(iOS)` / `#else` / `#endif` split. The two implementations are fundamentally different:
- **iOS:** AVAudioSession category/active setup, interruption notification handling, route change handling, `sessionConfigured` static flag.
- **macOS:** No AVAudioSession. Registers for `AVAudioEngineConfigurationChange` to handle device changes and restart the engine.

The merged file is the iOS implementation under `#if os(iOS)` followed by the macOS implementation under `#else`.

### FlutterGaplessLoopPlugin.swift
The two plugin files are ~99% identical. The shared body (method routing, engine registry, metronome handler — ~500 lines) lives once. Three targeted guards handle the differences:

**1. Imports**
```swift
#if os(iOS)
import Flutter
import UIKit
#else
import FlutterMacOS
#endif
import AVFoundation
import os.log
```

**2. `registrar.messenger` API difference**

On iOS, `messenger` is a method call (`registrar.messenger()`). On macOS, it is a property (`registrar.messenger`). A file-scope extension (outside any class or function body) normalises the call site to a single property name on both platforms:

```swift
// File-scope — must be outside any class/function body.
#if os(iOS)
private extension FlutterPluginRegistrar {
    var messengerBridge: FlutterBinaryMessenger { messenger() }
}
#else
private extension FlutterPluginRegistrar {
    var messengerBridge: FlutterBinaryMessenger { messenger }
}
#endif
```

All four channel constructors in `register(with:)` use `registrar.messengerBridge`.

**3. `detachFromEngine` (iOS only)**

The iOS plugin overrides `detachFromEngine` to dispose all engines and reset `LoopAudioEngine.sessionConfigured`. The existing macOS plugin has no `detachFromEngine` override. This spec preserves that asymmetry by guarding the override behind `#if os(iOS)`:

```swift
#if os(iOS)
public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    engines.values.forEach    { $0.dispose() }
    engines.removeAll()
    metronomes.values.forEach { $0.dispose() }
    metronomes.removeAll()
    LoopAudioEngine.sessionConfigured = false
    logger.info("Plugin detached — session config flag reset")
}
#endif
```

> **Note:** macOS lacks engine cleanup on hot-restart. This is a pre-existing gap, not introduced by this migration. A follow-up should add a macOS `detachFromEngine` override that calls `engines.values.forEach { $0.dispose() }`, `engines.removeAll()`, and the metronome equivalents (without the `sessionConfigured` reset, which is iOS-only).

---

## darwin/Package.swift

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

The `path` is relative to `darwin/`, so sources are resolved from `darwin/Classes/`. No explicit framework linker settings are needed — AVFoundation is a system framework auto-linked on both platforms.

**Flutter framework dependency:** The plugin's `Package.swift` does NOT declare a dependency on `Flutter` or `FlutterMacOS`. Flutter's build tooling resolves the Flutter framework separately (via generated xcconfig / build settings) and injects the module so that `import Flutter` and `import FlutterMacOS` resolve at compile time. Declaring a local package path dependency on `Flutter`/`FlutterMacOS` in the plugin's own Package.swift would fail outside Flutter's build context because those local package stubs only exist during `flutter build` / `flutter run`. First-party Flutter plugins (e.g. `path_provider`, `url_launcher`) follow the same convention of omitting an explicit Flutter dependency from their Plugin Package.swift.

---

## pubspec.yaml

Add `sharedDarwinSource: true` to both the `ios` and `macos` platform entries:

```yaml
flutter:
  plugin:
    platforms:
      ios:
        pluginClass: FlutterGaplessLoopPlugin
        sharedDarwinSource: true
      android:
        package: com.fluttergaplessloop
        pluginClass: FlutterGaplessLoopPlugin
      macos:
        pluginClass: FlutterGaplessLoopPlugin
        sharedDarwinSource: true
      windows:
        pluginClass: FlutterGaplessLoopPlugin
```

---

## Podspec Changes

Both `ios/flutter_gapless_loop.podspec` and `macos/flutter_gapless_loop.podspec` change one line:

```ruby
# Before
s.source_files = 'Classes/**/*'

# After
s.source_files = '../darwin/Classes/**/*'
```

All other podspec content is unchanged.

---

## Deletion

`ios/Classes/` and `macos/Classes/` directories are deleted in full once `darwin/Classes/` is populated.

---

## Compatibility

- **CocoaPods:** Works unchanged. Both podspecs now reference `../darwin/Classes/**/*`.
- **SPM:** Works when an app enables `flutter config --enable-swift-package-manager`. Flutter's tooling finds `darwin/Package.swift` via the `sharedDarwinSource: true` flag.
- **Android / Windows:** Unaffected.
- **Dart API:** No changes.

---

## Out of Scope

- Any changes to Android, Windows, or Dart sources.
- Any behavioural changes to the audio engines.
- Upgrading minimum platform versions.
