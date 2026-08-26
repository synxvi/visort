# Repository Guidelines

> Guidance for AI assistants working in this repo. **The Flutter app in `visort_flutter/` is the sole codebase** (Windows desktop + Android). The legacy Python/Flask implementation (`app.py`, `index.html`, PyInstaller) has been removed; the Flutter app is a verified port of that prior implementation.

⚠️ **Doc currency:** `CLAUDE.md` redirects here. `readme.md` / `README_zh.md` cover the Flutter app. The current architecture docs are this file and `docs/ANDROID_ROADMAP.md`. Trust this file and the code otherwise.

## Project Overview

**VISORT** is a keyboard-driven desktop + mobile image organizer. It scans directories recursively, presents images one-by-one, and lets users sort each into configurable folders via single-key shortcuts. **Core invariant: all operations are staged in memory and only executed when the user explicitly confirms "Run"** — no file moves or deletes happen until then.

Workflow: **Home → Sort → Review → Results**. Android adds a Gallery/Album browser for MediaStore albums.

- **Flutter app** (`visort_flutter/`) targeting **Windows desktop** (feature-complete) and **Android**. It is a verified port of a prior Python/Flask implementation (v1.2.0, since removed). The Android port (milestones A0–A4 + the SAF→MediaStore pivot) is delivered and validated on real hardware; the **album/gallery experience is the current development focus** (v2, `docs/ANDROID_ROADMAP.md` §7) — core album architecture (keyset cursor pagination, ContentObserver live refresh, injectable `MediaStoreChannel`, `GalleryController` unit tests) is in place and features continue to iterate.

## Architecture & Data Flow

### Workflow & navigation (Flutter)
Plain Flutter `Navigator` named routes (no `go_router`) defined in `visort_flutter/lib/ui/router.dart`:

```
home(/) ──Start/scan──▶ sort ──Review──▶ review ──Run──▶ results ──Continue──▶ home
   │
   └─(Android)──tap album tile──▶ album(bucketId/bucketName) ──tap photo──▶ photoViewer
```

- `home` route **platform-forks**: `HomeScreenAndroid` vs `HomeScreen`.
- `sort` screen guards empty session (pops back to home).
- `safDemo` route (legacy SAF PoC) has been **removed** in v2 — SAF code is fully gone.
- `/gallery` route (bucket grid screen) removed with dead-code cleanup 2026-08 — the home screen's bucket tiles push `/album` directly; `GalleryScreen` is gone.

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

> Note: global config providers live in `core/i18n/i18n.dart`, **not** in `core/config/`. `HomeController` and `RunController` are plain classes (not Notifiers) — they take `WidgetRef`/deps and mutate other providers.

### Filesystem abstraction
`FileSystemRepository` (`core/fs/file_system_repository.dart`) is the platform-agnostic contract (`pickDirectories`, `scanImages`, `move`/`moveBatch`, `delete`/`deleteBatch`, `readMeta`, `exists`, `joinPath`, `readBytes`). Implementations:

- **`DesktopFileSystem`** (`core/fs/desktop_file_system.dart`) — `dart:io` + `file_picker`; conflict rename appends `_1`/`_2`; cross-device move falls back to copy+delete.
- **`AndroidMediaStoreFileSystem`** (`core/fs/android_mediastore_file_system.dart`) — active Android path, talks to a Kotlin `MediaStore` plugin over the `'visort/mediastore'` MethodChannel.

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
visort_flutter/
├─ lib/
│  ├─ main.dart, app.dart          # bootstrap + root MaterialApp
│  ├─ core/
│  │  ├─ config/                   # @immutable models + ProfilesService (persistence/validation) + folder_name_validator
│  │  ├─ i18n/                     # tr()/t(), strings_en/zh, AND global Riverpod providers
│  │  ├─ theme/                    # buildAppTheme(), AppColors, AppFonts, WithNoise overlay
│  │  ├─ window/                   # WindowStateService (desktop window-bounds persistence)
│  │  ├─ db/                       # SQLite base + stores (session/gallery-snapshot/hdr-cache/run-log); degraded null-db red line, all tested
│  │  └─ fs/                       # FileSystemRepository + desktop/MediaStore impls + image_loader (decode pipeline) + mediastore_channel/events + wallpaper_channel (SAF removed v2)
│  ├─ features/
│  │  ├─ home/                     # HomeController (profiles, folders, action-keys)
│  │  ├─ session/                  # SessionController + models (the decision state machine)
│  │  ├─ scan/                     # ScanController (scan → init session)
│  │  ├─ run/                      # RunController (streaming execute)
│  │  ├─ review/                   # reviewStatsProvider (pure derivation)
│  │  └─ gallery/                  # GalleryController (Android album browsing)
│  ├─ ui/
│  │  ├─ router.dart               # named routes (no go_router)
│  │  ├─ screens/                  # home/sort/review/results/album + editors (gallery screen removed)
│  │  ├─ ente_viewer/              # photo viewer subsystem ported from Ente Photos (detail_page, zoomable_image, filmstrip, details sheet, wallpaper crop, aves ported slivers) — consumed by album_screen
│  │  └─ adaptive/                 # WindowsKeyboardHandler
│  └─ shared/widgets/             # Kbd/DecisionBadge, toast, ProfileDropdown, SortToggle, confirm_sheet…
├─ packages/photo_view/            # local fork of photo_view (dual-axis edge adjudication patches; ente-aligned 0.15.0) — kept deliberately
├─ android/app/src/main/kotlin/com/synxvi/visort/
│  ├─ mediastore/                  # MediaStore MethodChannel + EventChannel plugin (ContentObserver); registered in MainActivity
│  └─ wallpaper/                   # WallpaperManager channel (setStream)
├─ windows/                        # CMake desktop runner (C++17, /W4 /WX)
├─ tools/                          # subset_fonts.py (CJK font subsetter), generate_icons.py (Android+Windows app icon generator)
└─ test/                           # pure-Dart unit tests (16 files / 114 cases)
# Repo root:
docs/ANDROID_ROADMAP.md   # Flutter Android port decisions (A0–A4)
```

## Development Commands

All Flutter commands run from `visort_flutter/`:

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

Build output: `visort_flutter/build/` (APKs at `build/app/outputs/flutter-apk/`; Windows exe at `build/windows/x64/runner/Release/visort_flutter.exe`).

Font subsetting (Android cold-start optimization, run when i18n strings change):

```bash
cd visort_flutter
pip install fonttools brotli zopfli
python tools/subset_fonts.py           # subsets Noto Sans Mono CJK SC; idempotent
```

App icon generation (run after replacing `assets/icon/visort.png`):

```bash
cd visort_flutter
pip install pillow
python tools/generate_icons.py          # regenerates Android mipmap + adaptive icon + Windows ico; idempotent
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
| `visort_flutter/lib/main.dart` | Entry; platform-forked init, builds/seeds `ProviderContainer` |
| `visort_flutter/lib/app.dart` | Root `VisortApp` `MaterialApp`, theme, locale, noise overlay |
| `visort_flutter/lib/ui/router.dart` | Named routes, home platform-fork, navigator key |
| `visort_flutter/lib/features/session/session_controller.dart` | **Core decision state machine** (`decide`/`undo`/`initFromScan`) |
| `visort_flutter/lib/features/session/session_models.dart` | `SessionState`, `Decision`, `DecisionAction`, `kRootDestKey='__root__'` |
| `visort_flutter/lib/features/run/run_controller.dart` | Streaming execute (`Stream<RunProgress>`), MediaStore batching |
| `visort_flutter/lib/core/config/models.dart` | All `@immutable` config models + manual JSON codec |
| `visort_flutter/lib/core/config/profiles_service.dart` | Persistence (`shared_preferences['visort_config']`), validation, `computeDestinationFolders` |
| `visort_flutter/lib/core/i18n/i18n.dart` | `tr`/`t` + **global providers** (`configProvider`, `profilesServiceProvider`, `currentLanguageProvider`) |
| `visort_flutter/lib/core/fs/file_system_repository.dart` | Platform-agnostic FS contract + `imageExtensions` (18 formats) |
| `visort_flutter/lib/core/fs/fs_provider.dart` | Platform fork → `AndroidMediaStoreFileSystem` / `DesktopFileSystem` |
| `visort_flutter/android/.../MainActivity.kt` | Registers the MediaStore plugin (MethodChannel + EventChannel); SAF plugin removed in v2 |
| `docs/ANDROID_ROADMAP.md` | Android port decisions, SAF→MediaStore pivot |

**Supported image formats (18):** `.jpg .jpeg .png .gif .bmp .webp .tiff .tif .svg .ico .heic .heif .raw .cr2 .nef .arw .dng .avif`

## Runtime / Tooling Preferences

- **Flutter 3.47.1** (pinned in CI; local SDK carries the heroes.dart patch, see `flutter-sdk-patches/`). `pubspec.yaml` lower bound `sdk: ^3.10.4`.
- **Android toolchain:** JDK 17, AGP 9.0.1 (built-in Kotlin — no `kotlin-android` apply), Kotlin 2.3.20, Gradle 9.1.0.
- **Windows desktop:** CMake ≥ 3.14, MSVC C++17 (`/W4 /WX` warnings-as-errors). `BINARY_NAME` is `visort` (exe named `visort.exe`).
- **Android package:** `com.synxvi.visort`. **minSdk pinned to 26** (Bundle-query MediaStore API is 26+; toolchain default 24 crashes Android 7.x). Impeller enabled.
- **Version:** `1.3.0+2` (pubspec; continues the legacy v1.2.x line). per-ABI versionCode offset via `androidComponents.onVariants` (arm64=N*10+1, v7a=N*10+2, universal=N*10).
- **Signing:** release signs via `android/key.properties` (gitignored) pointing at the production keystore; when the file is absent it falls back to debug keys for local runs. CI decodes the `VISORT_KEYSTORE_BASE64`/`VISORT_KEYSTORE_PASSWORD` secrets.
  - **Production keystore:** `/home/synxvi/Dev/keystores/visort-release.keystore` (kept **outside the repo**; back it up offline — losing it means existing users can never upgrade in place).
  - **`android/key.properties` template** (full content, for quick local production builds):
    ```
    storeFile=/home/synxvi/Dev/keystores/visort-release.keystore
    storePassword=EG4Xa6XUj0aIYJ4ldDfgULlX
    keyAlias=visort
    keyPassword=EG4Xa6XUj0aIYJ4ldDfgULlX
    ```
  - **Local build→device speedrun (PJZ110, root, wireless adb):** `flutter build apk --release --split-per-abi` → `adb push build/app/outputs/flutter-apk/app-arm64-v8a-release.apk /data/local/tmp/v.apk` → `adb shell su -c "pm install -r -d /data/local/tmp/v.apk"` (`-d` allows the arm64 versionCode downgrade over an installed v7a build). Plain `adb install -r` only works when the installed build's versionCode ≥ the new APK's.
  - **⚠ Stale-APK trap:** `flutter build` can serve a cached old APK even after `touch`ing sources (Gradle up-to-date misjudge: task finishes in ~1s and the md5 doesn't change). Verify the md5 changed after building; if not, `flutter clean && flutter pub get` and rebuild — a "✓ Built" line is not proof the fix is in the APK.
- **Python (tooling only):** Used by `tools/subset_fonts.py` (CJK font subsetting; `fonttools`/`brotli`/`zopfli`) and `tools/generate_icons.py` (app icon generation; `pillow`). Python 3.11+. Re-run `subset_fonts.py` whenever i18n strings change (font subsets live in `assets/fonts/`, originals in `.font-source/` which is gitignored).

## Testing & QA

**Flutter** — `flutter test` from `visort_flutter/`. **17 files / 119 cases, all pure-Dart unit tests** (plus two `photo_view_*` widget-level tests for the local fork). Coverage map:

| Area | Test files |
|---|---|
| `core/config` | `widget_test.dart` (config models/JSON/profile CRUD), `folder_name_validator_test.dart` |
| `ui/screens (android)` | `subdir_remove_focus_test.dart` (subdir-row removal focus handoff + AnimatedList exit-animation layout health) |
| `features/session` | `session_controller_test.dart` (decide/undo/restore), `session_store_test.dart` (SQLite round-trip + degraded null-db red line) |
| `features/run` | `run_controller_test.dart` (FakeFileSystem) |
| `features/gallery` | `gallery_controller_test.dart` (keyset pagination, batch ops, ContentObserver debounce), `gallery_snapshot_store_test.dart`, `hdr_cache_store_test.dart`, `run_log_store_test.dart` |
| `core/fs` | `fs_desktop_test.dart` (real IO), `service_policy_test.dart` |
| i18n | `i18n_keys_test.dart` (**EN/ZH key-set alignment + `{0}` placeholder-count guardrails**), `group_title_i18n_test.dart` |
| misc | `visort_logo_test.dart` (cold-start entrance animation), `photo_view_double_tap_test.dart`, `photo_view_page_switch_test.dart` |

- **Framework:** `flutter_test` SDK only. No `mocktail`/`bloc_test` — fakes are hand-written (`FakeFileSystem` implements `FileSystemRepository`; `_FakeMediaStoreChannel` extends `MediaStoreChannel`).
- **Conventions:** `*_test.dart` files, `group()`/`test()` clusters, Chinese descriptive names, `setUp`/`tearDown`. Fixtures inline (1×1 PNG byte array). Controllers needing `PaintingBinding` (e.g. `deletePhoto`→`evictImageCache`) call `TestWidgetsFlutterBinding.ensureInitialized()` at the top of `main()`.
- **Coverage:** not measured/enforced (no lcov/codecov/`--coverage`).
- **Gaps:** all UI (`lib/ui/`, screens, `shared/widgets`, router), `features/home`/`scan`, `core/theme`/`window`, and the `FileSystemRepository` interface are untested.

**CI** — `.github/workflows/release.yml` runs a **quality gate** (`flutter analyze --no-fatal-infos --no-fatal-warnings` + `flutter test`, Flutter pinned to 3.47.1) before the two build jobs (Android split-per-ABI APK + Windows zip), then publishes tagged Release assets named `visort-v*-{abi}.apk` / `visort-v*-windows-x64.zip`.
