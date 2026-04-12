# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

SORTR is a keyboard-driven desktop image organizer. It scans directories recursively, presents images one-by-one, and lets users sort them into configurable folders using keyboard shortcuts. All operations are staged in memory until the user explicitly confirms — no files are moved until "RUN" is clicked.

## Tech Stack

- **Backend**: Flask (Python 3.9+), single file `app.py`
- **Frontend**: Vanilla JS SPA in `index.html` (no build step)
- **Desktop**: pywebview for native window wrapping
- **Packaging**: PyInstaller (`sortr.spec`) produces single-file executables
- **CI/CD**: GitHub Actions (`release.yml`) builds for Windows/macOS/Linux on `v*` tags

## Commands

```bash
# Install dependencies
pip install -r requirements.txt

# Run in development (opens system browser)
python app.py

# Build standalone executable
pyinstaller sortr.spec

# Build and upload release (triggered by git tag v*)
git tag v1.x.x && git push origin v1.x.x
```

No automated test suite exists — testing is manual via scenarios in `QA_TESTING.md`.

## Architecture

### Two-file monolith

The entire application lives in two files:

- **`app.py`** (~938 lines) — Flask backend with all API endpoints and in-memory state
- **`index.html`** (~1085 lines) — Frontend SPA with 4 screens (Setup → Sort → Review → Results)

### State management

All session state lives in a single `session_state` dict in `app.py`. There is no database. State resets on each session. Key fields: `images`, `current_index`, `operations` (staged file moves/deletes), `custom_folders`.

### Non-destructive workflow

Critical design invariant: **only the `/api/run` endpoint modifies the filesystem**. All other endpoints record operations in `session_state["operations"]`. The Review screen shows pending changes before confirmation.

### API endpoints

| Endpoint | Purpose |
|----------|---------|
| `/api/scan` | Recursive directory scan, returns image list |
| `/api/image/<index>` | Serve current image for display |
| `/api/sort` | Record a move/delete/skip operation |
| `/api/undo` | Revert last operation |
| `/api/review` | Return all staged operations |
| `/api/run` | **Execute all staged operations** (filesystem mutation) |
| `/api/folders` | Get/set custom folder templates |
| `/api/status` | Current session state |

### Dual-mode execution

`app.py` detects PyInstaller frozen mode (`sys.frozen`) to resolve `index.html` path. In dev mode it uses `os.path.dirname(__file__)`; when frozen it uses `sys._MEIPASS`.

### Frontend screen flow

Screens are toggled via CSS classes (`.screen.active`). The JS manages a local state object synced with backend via `fetch()` calls. Keyboard handlers are bound globally and dispatch based on current screen.

## Conventions

- UI text is primarily in Chinese (Simplified) with some English
- Image format support: 18+ formats including RAW (CR2, NEF, ARW, DNG), HEIC/HEIF, AVIF
- Port auto-discovery starts at 5050, increments if occupied
- Fallback: if pywebview is unavailable, opens system browser instead
