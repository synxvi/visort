# QA Testing Guide — SORTR Image Organizer

This guide is for QA testers. It explains how to set up the app, run it, and manually verify all key features.

---

## Table of Contents

- [Prerequisites](#prerequisites)
- [Running the App](#running-the-app)
  - [Option A — From Source (Recommended for QA)](#option-a--from-source-recommended-for-qa)
  - [Option B — Pre-built Executable](#option-b--pre-built-executable)
- [Preparing Test Data](#preparing-test-data)
- [Test Scenarios](#test-scenarios)
  - [TC-01 App Launch](#tc-01-app-launch)
  - [TC-02 Scan a Directory](#tc-02-scan-a-directory)
  - [TC-03 Sort — Move Image to a Folder](#tc-03-sort--move-image-to-a-folder)
  - [TC-04 Sort — Delete an Image](#tc-04-sort--delete-an-image)
  - [TC-05 Sort — Skip an Image](#tc-05-sort--skip-an-image)
  - [TC-06 Undo Last Decision](#tc-06-undo-last-decision)
  - [TC-07 Review Screen](#tc-07-review-screen)
  - [TC-08 Apply Changes (RUN)](#tc-08-apply-changes-run)
  - [TC-09 File Collision Handling](#tc-09-file-collision-handling)
  - [TC-10 Customise Folder Templates](#tc-10-customise-folder-templates)
  - [TC-11 Persist Folder Templates Across Restarts](#tc-11-persist-folder-templates-across-restarts)
  - [TC-12 Edge Cases](#tc-12-edge-cases)
- [Keyboard Shortcut Reference](#keyboard-shortcut-reference)
- [Reporting Bugs](#reporting-bugs)

---

## Prerequisites

| Requirement | Version |
|---|---|
| Python | 3.9 or newer |
| pip | bundled with Python |
| Modern browser | Chrome, Firefox, Edge, or Safari |

Check your Python version:

```bash
python --version
```

---

## Running the App

### Option A — From Source (Recommended for QA)

```bash
# 1. Clone the repository
git clone https://github.com/SinghChinmay/sortr-image-organizer-desktop.git
cd sortr-image-organizer-desktop

# 2. Create and activate a virtual environment
python -m venv .venv

# Windows
.venv\Scripts\activate
# macOS / Linux
source .venv/bin/activate

# 3. Install dependencies
pip install -r requirements.txt

# 4. Start the app
python app.py
```

The terminal will print a URL such as:

```
SORTR v1.0.0 — development server on http://127.0.0.1:5050
```

Open that URL in your browser. The app is ready when the **Setup** screen appears.

> **Note:** If port 5050 is already in use, SORTR automatically finds the next available port (5051, 5052, …). Check the terminal output for the exact URL.

### Option B — Pre-built Executable

Download the latest release from the [Releases](../../releases) page.

| Platform | File | How to run |
|---|---|---|
| Windows | `sortr-windows.exe` | Double-click the file |
| macOS | `SORTR.app` | Drag to Applications, then open |
| Linux | `sortr-linux` | `chmod +x sortr-linux && ./sortr-linux` |

The app opens a native desktop window automatically — no browser needed.

---

## Preparing Test Data

Create a temporary folder with a mix of images to use as a source directory during testing:

```
~/sortr-test-images/
├── photo1.jpg
├── photo2.png
├── screenshot.webp
├── subdir/
│   └── nested.jpeg
└── duplicate.jpg        # keep a copy with the same name for collision tests
```

- Include at least **5–10 image files** across a mix of formats (`.jpg`, `.png`, `.webp`, etc.).
- Include at least one **sub-directory** to verify recursive scanning.
- Keep a **backup copy** of the folder before each test run so you can restore the originals.

---

## Test Scenarios

Each scenario lists the steps to perform and what to verify (✅ pass / ❌ fail criteria).

---

### TC-01 App Launch

**Goal:** Verify the app starts and the Setup screen loads correctly.

**Steps:**
1. Run `python app.py` (or open the executable).
2. Open the URL printed in the terminal.

**Expected:**
- ✅ The Setup screen loads without errors.
- ✅ The **Source Directory** and **Destination Parent Directory** fields are visible.
- ✅ A default list of folder types is displayed (Work, Personal, Projects, etc.).
- ✅ No error messages appear on the page or in the terminal.

---

### TC-02 Scan a Directory

**Goal:** Verify that SORTR correctly finds all images recursively.

**Steps:**
1. Enter the path to your test image folder in **Source Directory**.
2. Optionally change the **Destination Parent Directory**.
3. Click **SCAN**.

**Expected:**
- ✅ The Sort screen opens.
- ✅ The image counter shows the correct total (e.g., "Image 1 of 8").
- ✅ The first image is displayed.
- ✅ Images in sub-directories are included in the count.
- ✅ Non-image files (`.txt`, `.pdf`, etc.) are **not** included.

**Negative test:**
- Enter a path to a folder with **no images** → an error message should appear ("No images found in that directory").
- Enter a path that **does not exist** → an error message should appear ("Directory not found").

---

### TC-03 Sort — Move Image to a Folder

**Goal:** Verify that pressing a folder key stages a move decision.

**Steps:**
1. Complete a scan (TC-02).
2. Note which folder key is shown in the panel (e.g., `1` → Work).
3. Press that key on the keyboard.

**Expected:**
- ✅ The app advances to the next image.
- ✅ The progress counter increments by 1.
- ✅ No files are moved on disk yet (verify the source folder still contains the file).

---

### TC-04 Sort — Delete an Image

**Goal:** Verify that pressing `D` stages a delete decision.

**Steps:**
1. Complete a scan (TC-02).
2. Press `D` on the keyboard.

**Expected:**
- ✅ The app advances to the next image.
- ✅ The progress counter increments by 1.
- ✅ The file is **not** deleted from disk yet.

---

### TC-05 Sort — Skip an Image

**Goal:** Verify that pressing `S` stages a skip decision.

**Steps:**
1. Complete a scan (TC-02).
2. Press `S` on the keyboard.

**Expected:**
- ✅ The app advances to the next image.
- ✅ The file remains in its original location after RUN.

---

### TC-06 Undo Last Decision

**Goal:** Verify that pressing `Z` reverses the most recent decision.

**Steps:**
1. Complete a scan (TC-02).
2. Press `1` (or any folder key) to assign the first image to a folder.
3. Press `Z` to undo.

**Expected:**
- ✅ The app steps back to the previous image.
- ✅ The progress counter decrements by 1.
- ✅ Pressing `Z` again at the very first image shows an appropriate message or does nothing.

---

### TC-07 Review Screen

**Goal:** Verify that the Review screen accurately lists all staged decisions.

**Steps:**
1. Complete a scan (TC-02).
2. Make a mix of move, delete, and skip decisions across several images.
3. Click **REVIEW →**.

**Expected:**
- ✅ The Review screen lists every image with its staged action (Move to …, Delete, Skip).
- ✅ Stat cards show the correct totals for moves, deletes, skips, and undecided images.
- ✅ Images with no decision assigned appear in the "Undecided" count.
- ✅ Clicking **← KEEP SORTING** returns to the Sort screen without losing existing decisions.

---

### TC-08 Apply Changes (RUN)

**Goal:** Verify that clicking RUN actually moves and deletes files on disk.

**Steps:**
1. Complete TC-07 (at least one move and one delete staged).
2. On the Review screen, click **▶ RUN — APPLY CHANGES**.

**Expected:**
- ✅ A results screen shows totals: moved, deleted, skipped, errors.
- ✅ Files staged for **move** appear in the correct destination sub-folder.
- ✅ Files staged for **delete** no longer exist anywhere on disk.
- ✅ Files staged for **skip** remain in their original location unchanged.
- ✅ After RUN completes, the app returns to the Setup screen ready for a new scan.

---

### TC-09 File Collision Handling

**Goal:** Verify that SORTR renames files instead of overwriting when a name clash occurs.

**Steps:**
1. Copy two files with **the same filename** into different sub-folders of your test directory.
2. Scan the directory and move both files to the same destination folder.
3. Click RUN.

**Expected:**
- ✅ Both files are present in the destination folder.
- ✅ The second file is renamed with a numeric suffix (e.g., `photo_1.jpg`).
- ✅ No error is reported and no file is silently overwritten.

---

### TC-10 Customise Folder Templates

**Goal:** Verify that folder types can be added, edited, and removed via the UI.

**Steps:**
1. On the Setup screen, click **Edit Folder Types**.
2. Add a new row with key `8` and label `Vacation`.
3. Remove one of the existing rows.
4. Click **Save Folder Types**.
5. Start a new scan.

**Expected:**
- ✅ The new folder key `8` (Vacation) appears in the Sort screen panel.
- ✅ The removed folder no longer appears.
- ✅ Templates are saved to `~/.sortr/folders.json` (inspect the file to confirm).

---

### TC-11 Persist Folder Templates Across Restarts

**Goal:** Verify that custom folder templates survive an app restart.

**Steps:**
1. Complete TC-10 (save custom templates).
2. Stop the app (`Ctrl+C` in the terminal or close the window).
3. Restart with `python app.py` and open the URL.

**Expected:**
- ✅ The custom folder list from the previous session is shown on the Setup screen.
- ✅ The default templates are **not** restored automatically.

---

### TC-12 Edge Cases

| Scenario | Steps | Expected |
|---|---|---|
| **Empty source folder** | Scan a folder that contains only non-image files | Error: "No images found in that directory" |
| **Non-existent path** | Type a path that doesn't exist in the Source Directory field and click SCAN | Error: "Directory not found" |
| **Duplicate folder key** | In Edit Folder Types, assign the same key to two rows and save | Validation error; templates are not saved |
| **Empty folder label** | In Edit Folder Types, clear a label and save | Validation error; templates are not saved |
| **Keyboard shortcuts in text fields** | Focus the Source Directory input, then press `D` | No image should be marked for deletion |
| **All images skipped** | Press `S` for every image, go to Review, and click RUN | Results show all files as skipped; no files moved or deleted |
| **Source file removed mid-session** | Scan a folder, manually delete one source file, then click RUN | The missing file is listed under errors; all other changes still apply |

---

## Keyboard Shortcut Reference

| Key | Action | Active on |
|---|---|---|
| Configured folder key (e.g., `1`–`7`) | Move current image to matching folder | Sort screen |
| `D` | Mark current image for deletion | Sort screen |
| `S` | Skip (leave in place) | Sort screen |
| `Z` | Undo last decision and step back | Sort screen |

> Keyboard shortcuts are **inactive** when a text input has focus.

---

## Reporting Bugs

When reporting a bug, please include:

1. **OS and version** (e.g., Windows 11, macOS 14.5, Ubuntu 24.04)
2. **Python version** (`python --version`)
3. **Steps to reproduce** (be as specific as possible)
4. **Expected behaviour**
5. **Actual behaviour**
6. **Terminal output / error messages** (copy the full text)
7. **Screenshots** if the issue is visual

Open a new issue at: [https://github.com/SinghChinmay/sortr-image-organizer-desktop/issues](https://github.com/SinghChinmay/sortr-image-organizer-desktop/issues)
