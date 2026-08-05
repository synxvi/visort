<div align="center">

# SORTR

**Keyboard-Driven Image & Album Organizer** — Desktop + Android

Browse photos one by one, sort them into folders with a single keypress. Nothing moves until you confirm.

[**中文文档**](README_zh.md)

[![Flutter](https://img.shields.io/badge/Flutter-3.44%2B-blue)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.12%2B-0175C2)](https://dart.dev)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

</div>

---

## Why SORTR?

Hundreds of photos piling up in one folder? SORTR lets you sort them as fast as you can react — eyes on the image, one key per decision. A few minutes to archive hundreds of photos into the right places.

**Core principle: every operation is staged first, executed only on confirmation.** No accidental deletes, no accidental moves.

## Platforms

| Platform | Status | Highlights |
|---|---|---|
| **Windows desktop** | Stable · feature-complete | Keyboard-driven sorting, window-state persistence |
| **Android** | Active development | MediaStore album browser + sorter; the album/gallery experience is the current focus |

The codebase is the **Flutter app** in [`sortr_flutter/`](sortr_flutter/), a verified port of a prior Python/Flask implementation (since removed).

## Features

- **Keyboard First** — Move / delete / skip with single keys (Windows); tap targets (Android)
- **Staged Execution** — Every move/delete queues in memory; nothing touches the filesystem until you hit Run
- **Album Browser** (Android) — Keyset-paginated MediaStore gallery, live ContentObserver refresh, fullscreen viewer
- **Two Sort Modes** (Android) — Move into an existing album, or into custom sub-folders
- **Review Before Run** — Full stats of pending operations before execution
- **Bilingual UI** — Chinese / English, auto-saved
- **Conflict Handling** — Auto-appends numeric suffix on name collision
- **No Code Generation** — Hand-written immutable models throughout

## Quick Start (Flutter)

Requires [Flutter ≥ 3.44](https://flutter.dev) (Dart ≥ 3.12).

```bash
git clone https://github.com/synxvi/visort.git
cd visort/sortr_flutter
flutter pub get
flutter run -d windows        # Windows desktop
flutter run -d android        # Android device/emulator
```

Build:

```bash
flutter build windows --release   # → build/windows/x64/runner/Release/
flutter build apk --release       # → build/app/outputs/flutter-apk/
```

> Android release builds currently sign with debug keys (no production keystore yet).

## Workflow

```
Setup → Sort → Review → Run
```

1. **Setup** — Pick a source (album on Android, directory on Windows), set target folders
2. **Sort** — Decide per image: move to a folder, move to root, delete, or skip
3. **Review** — Inspect staged operations with stats
4. **Run** — Confirm to apply all at once

## Supported Formats

18 formats: JPG · PNG · GIF · BMP · WEBP · TIFF · TIF · SVG · ICO · HEIC · HEIF · RAW · CR2 · NEF · ARW · DNG · AVIF

## Tech Stack

| Layer | Technology |
|---|---|
| UI / logic | Flutter (Dart ≥ 3.12), Riverpod ^2.6.1 |
| Android native | Kotlin + MediaStore (MethodChannel + EventChannel + ContentObserver) |
| Windows native | CMake runner (C++17) |
| Tests | `flutter_test`, 52 unit cases |
| State | Staged in memory, no DB |

## Documentation

- [`AGENTS.md`](AGENTS.md) — authoritative architecture & development guide
- [`docs/ANDROID_ROADMAP.md`](docs/ANDROID_ROADMAP.md) — Android port decisions (A0–A4, SAF→MediaStore, v2 album)
- [`sortr_flutter/README.md`](sortr_flutter/README.md) — Flutter app quick-start

## License

[MIT License](LICENSE)
