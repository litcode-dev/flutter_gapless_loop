# SPM pub.dev Score Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move Swift sources from `darwin/Classes/` to `darwin/Sources/flutter_gapless_loop/` and update all references so pana recognises SPM support and the pub.dev score for iOS and macOS SPM shows green.

**Architecture:** Three mechanical file changes — a directory rename, a one-line edit to `darwin/Package.swift`, and source-path + version updates in three podspecs. No Swift code changes. No Dart changes. No other platforms affected.

**Tech Stack:** Swift Package Manager (`Package.swift`), CocoaPods (`.podspec`), Flutter plugin conventions.

---

## File Map

| File | Change |
|------|--------|
| `darwin/Classes/` (directory) | Rename to `darwin/Sources/flutter_gapless_loop/` |
| `darwin/Package.swift` | Update `path:` from `"Classes"` to `"Sources/flutter_gapless_loop"` |
| `ios/flutter_gapless_loop.podspec` | Update `s.source_files`, bump `s.version` to `0.0.9` |
| `macos/flutter_gapless_loop.podspec` | Update `s.source_files`, bump `s.version` to `0.0.9` |
| `darwin/flutter_gapless_loop.podspec` | Update `s.source_files`, bump `s.version` to `0.0.9` |

---

### Task 1: Rename source directory and update Package.swift

**Context:** pana (pub.dev's scoring tool) checks for a `Sources/{plugin_name}/` directory. The Swift sources are currently in `darwin/Classes/`. Moving them to `darwin/Sources/flutter_gapless_loop/` and updating `darwin/Package.swift` to match is the core of the fix.

**Files:**
- Rename: `darwin/Classes/` → `darwin/Sources/flutter_gapless_loop/`
- Modify: `darwin/Package.swift`

- [ ] **Step 1: Rename the directory**

  From the repo root:

  ```bash
  mkdir -p darwin/Sources
  git mv darwin/Classes darwin/Sources/flutter_gapless_loop
  ```

  Verify the move:

  ```bash
  ls darwin/Sources/flutter_gapless_loop/
  ```

  Expected output (order may vary):

  ```
  BpmDetector.swift
  CrossfadeEngine.swift
  FlutterGaplessLoopPlugin.swift
  LoopAudioEngine.swift
  MetronomeEngine.swift
  ```

- [ ] **Step 2: Confirm `darwin/Classes/` is gone**

  ```bash
  ls darwin/
  ```

  Expected: `Classes/` no longer appears. You should see `Sources/`, `Package.swift`, `flutter_gapless_loop.podspec`.

- [ ] **Step 3: Update `darwin/Package.swift`**

  Current content of `darwin/Package.swift`:

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

  Change `path: "Classes"` to `path: "Sources/flutter_gapless_loop"`. The file after the edit:

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

- [ ] **Step 4: Verify SPM resolves the new path**

  ```bash
  swift package --package-path darwin clean && swift package --package-path darwin build
  ```

  Expected: build completes with no errors. You will see output like:

  ```
  Build complete!
  ```

  If it fails with "no targets found" or "invalid manifest", double-check that the path in `Package.swift` exactly matches the directory name created in Step 1.

- [ ] **Step 5: Commit**

  ```bash
  git add darwin/Sources/ darwin/Package.swift
  git commit -m "refactor: move Swift sources to SPM-standard layout (Sources/flutter_gapless_loop)"
  ```

---

### Task 2: Update all three podspecs

**Context:** CocoaPods uses `s.source_files` to find Swift sources. All three podspecs still reference the old `Classes/` path. After the directory rename in Task 1, CocoaPods builds will fail until these are updated. The three podspecs are also stale at version `0.0.7`; `pubspec.yaml` is already at `0.0.9`. Bring them in sync.

**Background on version gap:** `0.0.8` was a Dart/Swift bug-fix release that did not touch the podspecs. The podspecs are now updated directly to `0.0.9` to match `pubspec.yaml`.

**Files:**
- Modify: `ios/flutter_gapless_loop.podspec`
- Modify: `macos/flutter_gapless_loop.podspec`
- Modify: `darwin/flutter_gapless_loop.podspec`

- [ ] **Step 1: Update `ios/flutter_gapless_loop.podspec`**

  Find these two lines (around lines 7 and 18):

  ```ruby
  s.version          = '0.0.7'
  ```
  ```ruby
  s.source_files = '../darwin/Classes/**/*'
  ```

  Change them to:

  ```ruby
  s.version          = '0.0.9'
  ```
  ```ruby
  s.source_files = '../darwin/Sources/flutter_gapless_loop/**/*'
  ```

  No other lines in the file change.

- [ ] **Step 2: Update `macos/flutter_gapless_loop.podspec`**

  Find these two lines (around lines 7 and 18):

  ```ruby
  s.version          = '0.0.7'
  ```
  ```ruby
  s.source_files = '../darwin/Classes/**/*'
  ```

  Change them to:

  ```ruby
  s.version          = '0.0.9'
  ```
  ```ruby
  s.source_files = '../darwin/Sources/flutter_gapless_loop/**/*'
  ```

- [ ] **Step 3: Update `darwin/flutter_gapless_loop.podspec`**

  Find these two lines (around lines 7 and 18):

  ```ruby
  s.version          = '0.0.7'
  ```
  ```ruby
  s.source_files = 'Classes/**/*'
  ```

  Change them to:

  ```ruby
  s.version          = '0.0.9'
  ```
  ```ruby
  s.source_files = 'Sources/flutter_gapless_loop/**/*'
  ```

  Note: the `darwin/` podspec uses a relative path without `../` because it is located inside `darwin/` itself.

- [ ] **Step 4: Lint all three podspecs**

  Run from the repo root:

  ```bash
  pod lib lint ios/flutter_gapless_loop.podspec --allow-warnings
  pod lib lint macos/flutter_gapless_loop.podspec --allow-warnings
  pod lib lint darwin/flutter_gapless_loop.podspec --allow-warnings
  ```

  Each should complete with:

  ```
  flutter_gapless_loop passed validation.
  ```

  If any lint fails with "source files not found", verify the `s.source_files` path matches the actual directory name from Task 1 exactly (case-sensitive: `Sources/flutter_gapless_loop`, not `sources/` or `flutter-gapless-loop`).

- [ ] **Step 5: Commit**

  ```bash
  git add ios/flutter_gapless_loop.podspec macos/flutter_gapless_loop.podspec darwin/flutter_gapless_loop.podspec
  git commit -m "chore: update podspecs to Sources/flutter_gapless_loop path, bump to 0.0.9"
  ```

---

### Task 3: Verify end-to-end build

**Context:** Confirm the combined changes (directory rename + Package.swift + podspecs) produce a working plugin build on both iOS and macOS before publishing.

**Files:** No changes — verification only.

- [ ] **Step 1: Run the example app on iOS Simulator**

  ```bash
  cd example
  flutter run -d "iPhone 16"
  ```

  Expected: app launches, audio loads and loops without errors in the terminal. If Flutter falls back to CocoaPods (older Flutter), confirm no `pod install` errors about missing source files.

- [ ] **Step 2: Run the example app on macOS**

  ```bash
  cd example
  flutter run -d macos
  ```

  Expected: app launches on macOS, audio works. Flutter 3.27+ will use SPM; confirm the build output shows SPM resolution, not CocoaPods.

- [ ] **Step 3: Update CHANGELOG.md**

  Add a note to the top of `CHANGELOG.md` under the `## 0.0.9` section:

  ```markdown
  * **Swift sources moved to SPM-standard layout.** `darwin/Classes/` renamed to `darwin/Sources/flutter_gapless_loop/` to satisfy pana's SPM directory check, fixing the pub.dev "Package does not support Swift Package Manager" score for iOS and macOS. All three podspecs updated accordingly and bumped to `0.0.9`.
  ```

- [ ] **Step 4: Commit**

  ```bash
  git add CHANGELOG.md
  git commit -m "docs: record SPM layout fix in CHANGELOG"
  ```
