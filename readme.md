<div align="center">

# SORTR

**Keyboard-Driven Desktop Image Organizer**

Browse photos one by one, sort them into folders with a single keypress. Nothing moves until you confirm.

[**中文文档**](README_zh.md)

[![Python 3.9+](https://img.shields.io/badge/Python-3.9%2B-blue)](https://www.python.org/)
[![Flask](https://img.shields.io/badge/Flask-3.x-green)](https://flask.palletsprojects.com/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

</div>

---

## Why SORTR?

Hundreds of photos piling up in one folder? SORTR lets you sort them as fast as you can type — left hand on shortcuts, eyes on the image. A few minutes to archive hundreds of photos into the right folders.

**Core principle: all operations are staged first, executed only on confirmation.** No accidental deletes, no accidental moves.

## Features

- **Keyboard First** — Move / delete / skip with single keys, no mouse needed
- **Custom Shortcuts** — Remap folder keys, undo, delete, skip freely
- **Multiple Profiles** — Save and switch between sorting schemes
- **Drag & Reorder** — Drag to rearrange target subdirectories
- **Review Before Run** — Full stats of pending operations before execution
- **Bilingual UI** — Chinese / English toggle, auto-saved
- **Import Subdirectories** — One-click import existing folders as targets
- **Conflict Handling** — Auto-appends numeric suffix on name collision
- **Directory Memory** — Remembers last used source and target directories
- **Single-File Build** — Double-click to run, no installer needed

## Quick Start

### Download

Grab the latest release from [Releases](https://github.com/synxvi/sortr/releases), double-click to run.

### Run from Source

```bash
git clone https://github.com/synxvi/sortr.git
cd sortr
pip install -r requirements.txt
python app.py
```

## Workflow

```
Setup → Sort → Review → Run
```

1. **Setup** — Choose source & target directories, customize folders and shortcuts
2. **Sort** — Browse images one by one:

   | Action | Key |
   |---|---|
   | Move to subfolder | `A` `S` `D` ... |
   | Move to root | `Space` |
   | Delete | `X` (configurable) |
   | Skip | `C` (configurable) |
   | Undo | `Z` (configurable) |

3. **Review** — Inspect staged operations with stats and details
4. **Run** — Confirm to apply all operations at once

## Supported Formats

JPG · PNG · GIF · BMP · WEBP · TIFF · SVG · ICO · HEIC · HEIF · AVIF · CR2 · NEF · ARW · DNG

## Tech Stack

| Layer | Technology |
|---|---|
| Backend | Flask (Python 3.9+) |
| Frontend | Vanilla JS SPA |
| Packaging | PyInstaller |
| Window | pywebview |

## License

[MIT License](LICENSE)
