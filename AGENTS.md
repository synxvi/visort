# Repository Guidelines

> Guidance for AI assistants working in this repo. **The Flutter app in `sortr_flutter/` is the sole codebase** (Windows desktop + Android). The legacy Python/Flask implementation (`app.py`, `index.html`, PyInstaller) has been removed; the Flutter app is a verified port of that prior implementation.

⚠️ **Doc currency:** `CLAUDE.md` redirects here. `readme.md` / `README_zh.md` cover the Flutter app. The current architecture docs are this file and `docs/ANDROID_ROADMAP.md`. Trust this file and the code otherwise.

## Project Overview

**SORTR** is a keyboard-driven desktop + mobile image organizer. It scans directories recursively, presents images one-by-one, and lets users sort each into configurable folders via single-key shortcuts. **Core invariant: all operations are staged in memory and only executed when the user explicitly confirms "Run"** — no file moves or deletes happen until then.

Workflow: **Setup → Sort → Review → Results**. Android adds a Gallery/Album browser for MediaStore albums.

- **Flutter app** (`sortr_flutter/`) targeting **Windows desktop** (feature-complete) and **Android**. It is a verified port of a prior Python/Flask implementation (v1.2.0, since removed). The Android port (milestones A0–A4 + the SAF→MediaStore pivot) is delivered and validated on real hardware; the **album/gallery experience is the current development focus** (v2, `docs/ANDROID_ROADMAP.md` §7) — core album architecture (keyset cursor pagination, ContentObserver live refresh, injectable `MediaStoreChannel`, `GalleryController` unit tests) is in place and features continue to iterate.

## Architecture & Data Flow

### Workflow & navigation (Flutter)
Plain Flutter `Navigator` named routes (no `go_router`) defined in `sortr_flutter/lib/ui/router.dart`:

```
setup(/) ──Start/scan──▶ sort ──Review──▶ review ──Run──▶ results ──Continue──▶ setup
   │
   └─(Android)─▶ gallery ──tap album──▶ album(bucketId/bucketName)
```

- `setup` route **platform-forks**: `SetupScreenAndroid` vs `SetupScreen`.
- `sort` screen guards empty session (pops back to setup).
- `safDemo` route (legacy SAF PoC) has been **removed** in v2 — SAF code is fully gone.

### State management — Riverpod ^2.6.1
A single **hand-created `ProviderContainer`** is built in `main()` (so config loads synchronously before `runApp`), then injected via `UncontrolledProviderScope` — **not** the standard `ProviderScope` widget.

Provider styles are deliberately mixed:

| Provider | Type | State | File |
|---|---|---|---|
| `configProvider` | `StateProvider` | `AppConfig` | `core/i18n/i18n.dart` |
| `profilesServiceProvider` | `Provider` (singleton) | `ProfilesService` | `core/i18n/i18n.dart` |
| `currentLanguageProvider` | `Provider` (derived) | `String` | `core/i18n/i18n.dart` |
| `sessionControllerProvider` | `NotifierProvider` | `SessionState` | `features/session/session_controller.dart` |
| `scanControllerProvider` | `StateNotifierProvider` | `ScanState` | `features/scan/scan_controller.dart` |
| `runControllerProvider` | `Provider` (plain class) | `RunController` | `features/run/run_controller.dart` |
| `reviewStatsProvider` | `Provider` (pure derivation) | `ReviewStats` | `features/review/review_controller.dart` |
| `galleryControllerProvider` | `NotifierProvider` | `GalleryState` | `features/gallery/gallery_controller.dart` |
| `fileSystemRepositoryProvider` | `Provider` (platform-forked) | `FileSystemRepository` | `core/fs/fs_provider.dart` |

> Note: global config providers live in `core/i18n/i18n.dart`, **not** in `core/config/`. `SetupController` and `RunController` are plain classes (not Notifiers) — they take `WidgetRef`/deps and mutate other providers.

### Filesystem abstraction
`FileSystemRepository` (`core/fs/file_system_repository.dart`) is the platform-agnostic contract (`pickDirectories`, `scanImages`, `move`/`moveBatch`, `delete`/`deleteBatch`, `readMeta`, `exists`, `joinPath`, `readBytes`). Implementations:

- **`DesktopFileSystem`** (`core/fs/desktop_file_system.dart`) — `dart:io` + `file_picker`; conflict rename appends `_1`/`_2`; cross-device move falls back to copy+delete.
- **`AndroidMediaStoreFileSystem`** (`core/fs/android_mediastore_file_system.dart`) — active Android path, talks to a Kotlin `MediaStore` plugin over the `'sortr/mediastore'` MethodChannel.

> **Two data paths (do not merge).** Classification flows through `FileSystemRepository` → `AndroidMediaStoreFileSystem` (model: `ImageRef`). Album browsing (`GalleryController`) talks to `MediaStoreChannel` **directly** (model: `MsImageInfo`), bypassing the repository — it needs a richer model (dates/size/MIME) than `ImageRef` offers. This is a deliberate long-term split; do not force album into `FileSystemRepository`. See `docs/ANDROID_ROADMAP.md` §7.2. (`AndroidSafFileSystem` was removed in v2 — MediaStore is the sole Android image path; SAF code is gone, not just deprecated.)

`ImageRef { root, relativePath, extension, displayName? }` unifies platforms: on Windows `root`=dir path; on Android `root`=`kImagesAuthority`, `relativePath`=MediaStore `_ID`, `displayName`=real `DISPLAY_NAME`. Use `ref.label` for user-facing names — on Android `ref.name` returns the `_ID` digit, not the filename.

### Non-destructive execution
`RunController.run(session)` returns a `Stream<RunProgress>` (consumed by `ResultsScreen` via `StreamBuilder`): per-file progress events then a terminal `RunResults { moved, deleted, skipped, errors }`. On Android, deletes/moves are **batched** and submitted once each (one system consent dialog).

### Bootstrap (`main.dart`)
`WidgetsFlutterBinding.ensureInitialized()` → **platform-forked init** (explicit `Platform.isXxx` branches):
- **Windows:** `window_manager` setup, min size 900×600, restore prior bounds via `WindowStateService` (persisted to `window_state.json`), debounced resize/move persistence.
- **Android:** edge-to-edge transparent system bars, background `SharedPreferences` preheat.

## Key Directories

```
sortr_flutter/
├─ lib/
│  ├─ main.dart, app.dart          # bootstrap + root MaterialApp
│  ├─ core/
│  │  ├─ config/                   # @immutable models + ProfilesService (persistence/validation)
│  │  ├─ i18n/                     # tr()/t(), strings_en/zh, AND global Riverpod providers
│  │  ├─ theme/                    # buildAppTheme(), AppColors, AppFonts, WithNoise overlay
│  │  ├─ window/                   # WindowStateService (desktop window-bounds persistence)
│  │  └─ fs/                       # FileSystemRepository + desktop/MediaStore impls (SAF removed v2)
│  ├─ features/
│  │  ├─ setup/                    # SetupController (profiles, folders, action-keys)
│  │  ├─ session/                  # SessionController + models (the decision state machine)
│  │  ├─ scan/                     # ScanController (scan → init session)
│  │  ├─ run/                      # RunController (streaming execute)
│  │  ├─ review/                   # reviewStatsProvider (pure derivation)
│  │  └─ gallery/                  # GalleryController (Android album browsing)
│  ├─ ui/
│  │  ├─ router.dart               # named routes (no go_router)
│  │  ├─ screens/                  # setup/sort/review/results/gallery/album + photo_viewer/photo_details_sheet + editors
│  │  └─ adaptive/                 # WindowsKeyboardHandler
│  └─ shared/widgets/             # Kbd/DecisionBadge, toast, ProfileDropdown, SortToggle, LoadingOverlay
├─ android/app/src/main/kotlin/com/sortr/sortr_flutter/
│  └─ mediastore/                  # MediaStore MethodChannel + EventChannel plugin (ContentObserver); registered in MainActivity
├─ windows/                        # CMake desktop runner (C++17, /W4 /WX)
├─ tools/                          # subset_fonts.py (HarmonyOS CJK font subsetter)
└─ test/                           # pure-Dart unit tests (5 files / 52 cases)
# Repo root:
docs/ANDROID_ROADMAP.md   # Flutter Android port decisions (A0–A4)
```

## Development Commands

All Flutter commands run from `sortr_flutter/`:

```bash
flutter pub get                 # resolve deps (run first)
flutter run                     # run on connected device (auto-picks)
flutter run -d windows          # Windows desktop
flutter run -d android          # Android device/emulator
flutter analyze                 # static analysis (flutter_lints, no custom rules)
flutter test                    # run the unit-test suite
flutter build apk --release     # ABI-split APKs (arm64-v8a, armeabi-v7a, universal)
flutter build apk --split-per-abi
flutter build windows --release # Windows .exe bundle
```

Build output: `sortr_flutter/build/` (APKs at `build/app/outputs/flutter-apk/`; Windows exe at `build/windows/x64/runner/Release/sortr_flutter.exe`).

Font subsetting (Android cold-start optimization, run when i18n strings change):

```bash
cd sortr_flutter
pip install fonttools brotli zopfli
python tools/subset_fonts.py           # subsets HarmonyOS Sans SC; idempotent
```

## Code Conventions & Common Patterns

- **No code generation.** No `freezed`, `json_serializable`, `build_runner`, or `riverpod_generator`. All value classes in `core/config/models.dart` and `features/session/session_models.dart` are **hand-written `@immutable`** with manual `copyWith` / `toJson` / `fromJson` / `operator==` / `hashCode` (`Object.hash`, `listEquals`). Match this style for new models — do not introduce codegen for consistency.
- **i18n everywhere.** User-facing strings go through `t(ref, 'key')` (`tr(key)` is contextless). Controllers return **i18n keys** (or `null`) from mutating methods; translate at the call site. `strings_en.dart` / `strings_zh.dart` (~161 keys). Add new keys to both.
- **Theming discipline.** Never hardcode colors/fonts in screens — import `AppColors` / `AppFonts` from `core/theme/`. Dark-only Material 3. Ripple/splash globally disabled (`NoSplash`). `WithNoise` grain overlay wraps the whole app.
- **Platform forking.** Explicit `Platform.isAndroid` / `Platform.isWindows` at FS-provider, route, screen, layout (`ResponsiveBuilder` >800px), keyboard-handler, and image-loader levels. Beyond `FileSystemRepository`, platform differences are branched inline — don't over-abstract.
- **Riverpod consumption.** `ConsumerWidget` / `ConsumerStatefulWidget` + `ref.watch` (rebuild) / `ref.read` (one-shot). `initState` seeds local `TextEditingController`s from `ref.read(configProvider)`.
- **Widget decomposition.** snake_case files, one responsibility per file. Screens split into many small private `_Foo` widgets (e.g. `sort_screen.dart` has `_ImageArea`, `_FullscreenImage`, `_SortPanel`, `_AndroidBottomBar`). Public widgets PascalCase; private helpers `_`-prefixed. `const` constructors pervasive.
- **Defensive ROM workarounds** are common and commented (e.g. `GalleryController.deletePhoto` re-checks `exists()` because some Android ROMs misreport; M3 popup white-flash workarounds in theme + custom `ProfileDropdown`). Preserve these comments.
- **Port provenance comments.** Some files carry a header comment noting the logic was ported from a prior Python implementation (`app.py`, since removed); tests assert behavioral parity with that implementation. This is historical context — preserve but do not extend.

## Important Files

| File | Role |
|---|---|
| `sortr_flutter/lib/main.dart` | Entry; platform-forked init, builds/seeds `ProviderContainer` |
| `sortr_flutter/lib/app.dart` | Root `SortrApp` `MaterialApp`, theme, locale, noise overlay |
| `sortr_flutter/lib/ui/router.dart` | Named routes, setup platform-fork, navigator key |
| `sortr_flutter/lib/features/session/session_controller.dart` | **Core decision state machine** (`decide`/`undo`/`initFromScan`) |
| `sortr_flutter/lib/features/session/session_models.dart` | `SessionState`, `Decision`, `DecisionAction`, `kRootDestKey='__root__'` |
| `sortr_flutter/lib/features/run/run_controller.dart` | Streaming execute (`Stream<RunProgress>`), MediaStore batching |
| `sortr_flutter/lib/core/config/models.dart` | All `@immutable` config models + manual JSON codec |
| `sortr_flutter/lib/core/config/profiles_service.dart` | Persistence (`shared_preferences['sortr_config']`), validation, `computeDestinationFolders` |
| `sortr_flutter/lib/core/i18n/i18n.dart` | `tr`/`t` + **global providers** (`configProvider`, `profilesServiceProvider`, `currentLanguageProvider`) |
| `sortr_flutter/lib/core/fs/file_system_repository.dart` | Platform-agnostic FS contract + `imageExtensions` (18 formats) |
| `sortr_flutter/lib/core/fs/fs_provider.dart` | Platform fork → `AndroidMediaStoreFileSystem` / `DesktopFileSystem` |
| `sortr_flutter/android/.../MainActivity.kt` | Registers the MediaStore plugin (MethodChannel + EventChannel); SAF plugin removed in v2 |
| `docs/ANDROID_ROADMAP.md` | Android port decisions, SAF→MediaStore pivot |

**Supported image formats (18):** `.jpg .jpeg .png .gif .bmp .webp .tiff .tif .svg .ico .heic .heif .raw .cr2 .nef .arw .dng .avif`

## Runtime / Tooling Preferences

- **Flutter ≥ 3.44.0** (Dart ≥ 3.12.0; `pubspec.yaml` lower bound `sdk: ^3.10.4`). Resolved floor from `pubspec.lock`.
- **Android toolchain:** JDK 17, AGP 8.11.1, Kotlin 2.2.20, Gradle 8.14.
- **Windows desktop:** CMake ≥ 3.14, MSVC C++17 (`/W4 /WX` warnings-as-errors).
- **Android package:** `com.sortr.sortr_flutter`. SDK versions use Flutter toolchain defaults (not pinned in `build.gradle.kts`). Impeller enabled.
- **Signing:** ⚠️ Release currently signs with **debug keys** (no production keystore / `key.properties` committed). Works for local `--release` builds; a real keystore is required for Play Store upload.
- **Python (tooling only):** Used solely by `tools/subset_fonts.py` (CJK font subsetting). Python 3.11 + `fonttools`/`brotli`/`zopfli`.

## Testing & QA

**Flutter** — `flutter test` from `sortr_flutter/`. Five files, **52 cases, all pure-Dart unit tests** (no widget/integration/golden tests). Tests guard platform-agnostic logic (config, session state machine, run flow, desktop FS) plus the **album (gallery) controller** (v2):

| Test file | Covers | Cases |
|---|---|---|
| `test/widget_test.dart` | `core/config` — models, JSON round-trip, `normalizeFolderTemplates` validation, `computeDestinationFolders`, profile CRUD (misleadingly named; tests no widgets) | 13 |
| `test/session_controller_test.dart` | `features/session` state machine — `decide`/`undo`/`initFromScan`/bounds (via real `ProviderContainer`) | 15 |
| `test/run_controller_test.dart` | `features/run` — execute flow + progress stream (in-memory `FakeFileSystem`) | 5 |
| `test/fs_desktop_test.dart` | `core/fs/desktop_file_system` — real-IO scan/filter/move/collision-rename/delete | 11 |
| `test/gallery_controller_test.dart` | `features/gallery` — keyset pagination (cursor advance/hasMore), deletePhoto (local remove + bucket count decrement + coverId clear), sort persistence; via `_FakeMediaStoreChannel` injected through `mediaStoreChannelProvider` override | 8 |

- **Framework:** `flutter_test` SDK only. No `mocktail`/`bloc_test` — fakes are hand-written (`FakeFileSystem` implements `FileSystemRepository`; `_FakeMediaStoreChannel` extends `MediaStoreChannel`).
- **Conventions:** `*_test.dart` files, `group()`/`test()` clusters, Chinese descriptive names, `setUp`/`tearDown`. Fixtures inline (1×1 PNG byte array). Controllers needing `PaintingBinding` (e.g. `deletePhoto`→`evictImageCache`) call `TestWidgetsFlutterBinding.ensureInitialized()` at the top of `main()`.
- **Coverage:** not measured/enforced (no lcov/codecov/`--coverage`).
- **Gaps:** all UI (`lib/ui/`, screens, `shared/widgets`, router), `features/setup`/`scan`, `core/i18n`/`theme`/`window`, the `FileSystemRepository` interface, and the `shared_preferences` storage layer are untested. (`features/gallery` logic **is** now covered; only its UI/widget layer remains untested.)

**CI** — `.github/workflows/release.yml` builds the Flutter app for both targets on `v*` tags: Android (split-per-ABI APK) and Windows (zip). There is no `flutter test`/`flutter analyze` step and no coverage gate in CI; those run locally.
