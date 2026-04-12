"""
SORTR — Image Organizer
=======================
A Flask-based web application that lets users scan a directory of images,
decide per-image whether to move, delete, or skip each one, preview all
pending changes, and finally apply them in a single batch operation.

All file operations are performed only when the user confirms via the
"RUN" step, so nothing is destructive until explicitly issued.

Usage (development):
    python app.py
    # Then open http://127.0.0.1:5050 in a browser.

Usage (standalone executable built with PyInstaller):
    ./sortr   (or sortr.exe on Windows)
    # The app opens a browser window automatically.
"""

import os
import sys
import json
import shutil
import socket
import threading
import time
import webbrowser
from pathlib import Path
from typing import Optional

from flask import Flask, jsonify, request, send_file, render_template

# ── Version ──────────────────────────────────────────────────────────────────
__version__ = "1.2.0"


def get_resource_path(relative_path: str) -> str:
    """
    Return the absolute path to a bundled resource file.

    When running as a PyInstaller one-file executable, all data files are
    extracted to a temporary directory stored in ``sys._MEIPASS``.  During
    normal development ``__file__`` is used as the base instead.
    """
    if getattr(sys, "frozen", False):
        # Running inside a PyInstaller bundle
        base = sys._MEIPASS  # type: ignore[attr-defined]
    else:
        base = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(base, relative_path)


# Point Flask at the directory that contains index.html.  This works for both
# the normal development run and the frozen executable bundle.
app = Flask(__name__, template_folder=get_resource_path("."))

# ── Destination folders config ──────────────────────────────────────────────
# Folder templates are user-editable and persisted to disk.
# Config is stored in a 'config' sub-directory next to the executable / script.
DEFAULT_FOLDER_TEMPLATES = [
    {"key": "A", "label": "General"},
]

# 默认功能键绑定
DEFAULT_ACTION_KEYS = {
    "undo": "Z",
    "delete": "X",
    "skip": "C",
}


def get_config_dir() -> Path:
    """Return config directory adjacent to the running script/exe.

    In development mode this is <script_dir>/config.
    As a PyInstaller frozen exe this is <exe_dir>/config.
    """
    if getattr(sys, "frozen", False):
        base = Path(sys.executable).parent
    else:
        base = Path(__file__).resolve().parent
    return base / "config"


CONFIG_DIR = get_config_dir()
PROFILES_FILE = CONFIG_DIR / "profiles.json"  # 多组配置文件

# 全局语言设置（默认英文）
_app_lang = "en"

# Default destination parent used when the user has not yet supplied one.
DEFAULT_DEST_PARENT = str(Path.home() / "Pictures")


def get_effective_dest_parent() -> str:
    """Return the user's last-used dest parent, falling back to the default."""
    last = load_last_dirs()
    return last["dest_parent"] or DEFAULT_DEST_PARENT


def save_last_dirs(source_dir: str, dest_parent: str) -> None:
    """Persist the last-used source dir and destination parent to disk."""
    global profiles_data
    try:
        if not profiles_data:
            profiles_data = _load_profiles()
        CONFIG_DIR.mkdir(parents=True, exist_ok=True)
        payload = {
            "active_profile": ACTIVE_PROFILE,
            "profiles": profiles_data,
            "language": _app_lang,
        }
        if source_dir:
            payload["last_source_dir"] = expand(source_dir)
        if dest_parent:
            payload["last_dest_parent"] = expand(dest_parent)
        PROFILES_FILE.write_text(
            json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8"
        )
    except Exception:
        pass  # non-critical, silently ignore


def load_last_dirs() -> dict:
    """Load the persisted last-used directories from disk."""
    result = {"source_dir": "", "dest_parent": ""}
    try:
        if PROFILES_FILE.exists():
            raw = json.loads(PROFILES_FILE.read_text(encoding="utf-8"))
            src = raw.get("last_source_dir", "").strip()
            dst = raw.get("last_dest_parent", "").strip()
            if src and os.path.isdir(src):
                result["source_dir"] = src
            if dst and os.path.isdir(dst):
                result["dest_parent"] = dst
    except Exception:
        pass
    return result


# Full set of recognised image file extensions (lower-case).
IMAGE_EXTENSIONS = {
    ".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp",
    ".tiff", ".tif", ".svg", ".ico", ".heic", ".heif",
    ".raw", ".cr2", ".nef", ".arw", ".dng", ".avif",
}


def normalize_folder_templates(raw_templates) -> list:
    """
    Validate and normalize a folder template list.

    Each template must be a dict containing:
      ``key``   — single-character shortcut
      ``label`` — destination folder label
    """
    if not isinstance(raw_templates, list):
        raise ValueError("文件夹模板必须是列表")
    if not raw_templates:
        raise ValueError("至少需要一个目标文件夹")

    normalized = []
    seen_keys = set()

    for entry in raw_templates:
        if not isinstance(entry, dict):
            raise ValueError("每个文件夹模板必须是对象")

        key = str(entry.get("key", "")).strip()
        label = str(entry.get("label", "")).strip()

        if len(key) != 1:
            raise ValueError("每个文件夹快捷键必须恰好 1 个字符")
        key_norm = key.lower()
        if key_norm in seen_keys:
            raise ValueError(f"重复的快捷键: {key}")
        if not label:
            raise ValueError("文件夹名称不能为空")

        seen_keys.add(key_norm)
        normalized.append({"key": key.upper(), "label": label})

    return normalized


# ── Profile / multi-group config ────────────────────────────────────────────
# Active profile name and the in-memory profiles dict.
ACTIVE_PROFILE = "Default"
# 新格式: { profile_name: {"folders": [...], "action_keys": {...}} }
# 兼容旧格式: { profile_name: [...] }
profiles_data: dict = {}


def _ensure_profile_dict(profile_value) -> dict:
    """将旧格式列表转换为新格式字典，确保统一结构。"""
    if isinstance(profile_value, list):
        return {
            "folders": profile_value,
            "action_keys": DEFAULT_ACTION_KEYS.copy(),
        }
    if isinstance(profile_value, dict):
        return {
            "folders": profile_value.get("folders", DEFAULT_FOLDER_TEMPLATES.copy()),
            "action_keys": profile_value.get("action_keys", DEFAULT_ACTION_KEYS.copy()),
        }
    return {"folders": DEFAULT_FOLDER_TEMPLATES.copy(), "action_keys": DEFAULT_ACTION_KEYS.copy()}


def _get_profile_folders(name: str) -> list:
    """获取指定配置组的文件夹模板列表。"""
    profile = profiles_data.get(name, {})
    pd = _ensure_profile_dict(profile)
    return pd["folders"]


def _get_profile_action_keys(name: str) -> dict:
    """获取指定配置组的功能键绑定。"""
    profile = profiles_data.get(name, {})
    pd = _ensure_profile_dict(profile)
    return pd["action_keys"]


def _load_profiles() -> dict:
    """Load profiles from disk. Returns the profiles dict or empty defaults."""
    global ACTIVE_PROFILE

    # ── Migration: if old single-file folders.json exists, import it ────────
    old_file = Path.home() / ".sortr" / "folders.json"
    if old_file.exists() and not PROFILES_FILE.exists():
        try:
            old_templates = json.loads(old_file.read_text(encoding="utf-8"))
            # Validate and normalize
            old_templates = normalize_folder_templates(old_templates)
            migrated = {"active_profile": "Default", "profiles": {"Default": old_templates}}
            CONFIG_DIR.mkdir(parents=True, exist_ok=True)
            PROFILES_FILE.write_text(
                json.dumps(migrated, indent=2, ensure_ascii=False), encoding="utf-8"
            )
            print(f"[sortr] 已从旧版配置迁移: ~/.sortr/folders.json → {PROFILES_FILE}")
        except Exception as exc:
            print(f"[sortr] 旧配置迁移失败: {exc}")

    if not PROFILES_FILE.exists():
        return {"Default": DEFAULT_FOLDER_TEMPLATES.copy()}

    try:
        raw = json.loads(PROFILES_FILE.read_text(encoding="utf-8"))
        if isinstance(raw, dict) and "profiles" in raw:
            ACTIVE_PROFILE = raw.get("active_profile", "Default")
            # 读取语言偏好
            global _app_lang
            _app_lang = raw.get("language", "en")
            result = raw["profiles"]
            # Ensure every profile's templates are normalized
            for name, value in list(result.items()):
                pd = _ensure_profile_dict(value)
                try:
                    pd["folders"] = normalize_folder_templates(pd["folders"])
                except (ValueError, TypeError):
                    pd["folders"] = DEFAULT_FOLDER_TEMPLATES.copy()
                result[name] = pd
            # Ensure active profile exists
            if ACTIVE_PROFILE not in result:
                ACTIVE_PROFILE = next(iter(result))
            return result
        else:
            # Backwards compat: file is a plain list → treat as "Default" profile
            tmpl_list = normalize_folder_templates(raw) if isinstance(raw, list) else DEFAULT_FOLDER_TEMPLATES.copy()
            return {"Default": tmpl_list}
    except Exception:
        return {"Default": DEFAULT_FOLDER_TEMPLATES.copy()}


def _save_profiles() -> None:
    """Persist the current profiles dict to disk."""
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    payload = {
        "active_profile": ACTIVE_PROFILE,
        "profiles": profiles_data,
        "language": _app_lang,
    }
    PROFILES_FILE.write_text(
        json.dumps(payload, indent=2, ensure_ascii=False), encoding="utf-8"
    )


def load_folder_templates() -> list:
    """Load persisted folder templates for the active profile."""
    global profiles_data
    if not profiles_data:
        profiles_data = _load_profiles()
    return _get_profile_folders(ACTIVE_PROFILE)


def load_action_keys() -> dict:
    """Load persisted action keys for the active profile."""
    global profiles_data
    if not profiles_data:
        profiles_data = _load_profiles()
    return _get_profile_action_keys(ACTIVE_PROFILE)


def save_folder_templates(templates: list) -> None:
    """Persist folder templates to the local config directory (under active profile)."""
    global profiles_data
    if not profiles_data:
        profiles_data = _load_profiles()
    pd = _ensure_profile_dict(profiles_data.get(ACTIVE_PROFILE))
    pd["folders"] = templates
    profiles_data[ACTIVE_PROFILE] = pd
    _save_profiles()


def save_action_keys(action_keys: dict) -> None:
    """Persist action key bindings for the active profile."""
    global profiles_data
    if not profiles_data:
        profiles_data = _load_profiles()
    pd = _ensure_profile_dict(profiles_data.get(ACTIVE_PROFILE))
    pd["action_keys"] = action_keys
    profiles_data[ACTIVE_PROFILE] = pd
    _save_profiles()


folder_templates = load_folder_templates()

# ── In-memory session state ─────────────────────────────────────────────────
# A single global dict holds all runtime state for the current sorting session.
# Because this is a local single-user tool there is no need for proper session
# management or a database — state is reset when a new scan is started or after
# the user applies changes.
session_state = {
    "source_dir": None,
    "images": [],
    "current_index": 0,
    "destination_parent": None,
    "folder_templates": [],
    "folders": [],
    # Maps relative file path → decision dict:
    #   {"action": "move", "dest_label": str, "dest_path": str}
    #   {"action": "delete"}
    #   {"action": "skip"}
    "decisions": {},
}


def expand(path: str) -> str:
    """Expand ``~`` and resolve symlinks / relative segments in *path*."""
    return str(Path(path).expanduser().resolve())


def compute_destination_folders(parent_dir: str, templates: Optional[list] = None) -> list:
    """
    Build a list of destination folder descriptors from the active templates
    config, rooted at *parent_dir*.

    Each returned dict contains:
      ``key``   — keyboard shortcut string
      ``label`` — human-readable folder name
      ``path``  — absolute filesystem path
    """
    root = expand(parent_dir)
    active_templates = templates if templates is not None else folder_templates
    return [
        {
            "key": folder["key"],
            "label": folder["label"],
            "path": os.path.join(root, folder["label"]),
        }
        for folder in active_templates
    ]


def get_active_folder_templates() -> list:
    """Return session templates when available, otherwise persisted templates."""
    return session_state["folder_templates"] or folder_templates


def get_active_folders() -> list:
    """Return the current session's folder list, or the default if none set."""
    return session_state["folders"] or compute_destination_folders(
        DEFAULT_DEST_PARENT,
        get_active_folder_templates(),
    )


# ── Routes ───────────────────────────────────────────────────────────────────

# ── 本地字体文件（替代 Google Fonts CDN，消除网络延迟）──────────────────────
_FONTS_DIR = os.path.join(get_resource_path("assets"), "fonts")


@app.route("/fonts/<path:filename>")
def serve_font(filename):
    """提供本地字体文件，避免每次启动都从 CDN 下载。"""
    return send_file(
        os.path.join(_FONTS_DIR, filename),
        mimetype="font/ttf",
        conditional=True,
    )


@app.route("/")
def index():
    """Serve the single-page application shell (index.html)."""
    return render_template(
        "index.html",
        folders=get_active_folders(),
        folder_templates=get_active_folder_templates(),
        default_dest_parent=session_state["destination_parent"] or get_effective_dest_parent(),
        default_lang=_app_lang,
    )


@app.route("/api/lang", methods=["GET"])
def get_lang():
    """返回当前语言设置。"""
    return jsonify({"lang": _app_lang})


@app.route("/api/lang", methods=["POST"])
def set_lang():
    """保存语言偏好。"""
    global _app_lang
    data = request.get_json(silent=True) or {}
    lang = data.get("lang", "en")
    if lang not in ("en", "zh"):
        return jsonify({"error": "Invalid language"}), 400
    _app_lang = lang
    _save_profiles()
    return jsonify({"lang": _app_lang})


@app.route("/api/folders")
def get_folders():
    """Return the current destination folder list as JSON."""
    return jsonify({
        "folders": get_active_folders(),
        "templates": get_active_folder_templates(),
        "action_keys": load_action_keys(),
    })


@app.route("/api/folders", methods=["POST"])
def set_folders():
    """
    Update and persist the user-defined folder template list and action keys.

    Expected JSON body:
      ``folders``     — list of {"key": str, "label": str}
      ``action_keys`` — optional {"undo": str, "delete": str, "skip": str}
    """
    global folder_templates

    data = request.json or {}
    raw_templates = data.get("folders")
    if raw_templates is None:
        return jsonify({"error": "未提供文件夹列表"}), 400

    # 解析 action_keys（可选）
    raw_action_keys = data.get("action_keys")
    current_action_keys = load_action_keys()

    if raw_action_keys is not None:
        # 验证 action_keys 格式
        for k in ("undo", "delete", "skip"):
            val = str(raw_action_keys.get(k, current_action_keys.get(k, ""))).strip()
            if len(val) != 1:
                return jsonify({"error": f"功能键「{k}」必须为单个字符"}), 400
            current_action_keys[k] = val.upper()
        save_action_keys(current_action_keys)

    try:
        normalized = normalize_folder_templates(raw_templates)
    except ValueError as e:
        return jsonify({"error": str(e)}), 400

    folder_templates = normalized
    save_folder_templates(folder_templates)

    session_state["folder_templates"] = folder_templates.copy()
    active_parent = session_state["destination_parent"] or DEFAULT_DEST_PARENT
    session_state["folders"] = compute_destination_folders(active_parent, folder_templates)

    return jsonify({
        "templates": session_state["folder_templates"],
        "folders": session_state["folders"],
        "action_keys": current_action_keys,
    })


@app.route("/api/scan", methods=["POST"])
def scan():
    """
    Recursively scan *directory* for image files and initialise a new session.

    Expected JSON body:
      ``directory``          — path to scan (required)
      ``destination_parent`` — root for destination sub-folders (optional)
      ``folder_templates``   — list of key/label templates (optional)

    Returns JSON with the list of found image paths (relative to *directory*)
    and the resolved destination folder descriptors.
    """
    global folder_templates

    data = request.json or {}
    raw_dir = data.get("directory", "").strip()
    raw_dest_parent = data.get("destination_parent", "").strip() or DEFAULT_DEST_PARENT
    raw_templates = data.get("folder_templates")
    if not raw_dir:
        return jsonify({"error": "未提供目录路径"}), 400

    if raw_templates is not None:
        try:
            normalized = normalize_folder_templates(raw_templates)
        except ValueError as e:
            return jsonify({"error": str(e)}), 400
        folder_templates = normalized
        save_folder_templates(folder_templates)

    source = expand(raw_dir)
    if not os.path.isdir(source):
        return jsonify({"error": f"目录不存在: {source}"}), 404

    # Walk the directory tree and collect all recognised image files.
    recursive = data.get("recursive", True)
    images = []
    entries = Path(source).rglob("*") if recursive else Path(source).glob("*")
    for entry in sorted(entries):
        if entry.is_file() and entry.suffix.lower() in IMAGE_EXTENSIONS:
            # Store paths relative to source so they're portable across
            # systems and safe to display in the browser.
            images.append(str(entry.relative_to(source)))

    if not images:
        return jsonify({"error": "该目录下未找到图片文件"}), 404

    # Reset all session state for the new scan.
    session_state["source_dir"] = source
    session_state["images"] = images
    session_state["current_index"] = 0
    session_state["destination_parent"] = expand(raw_dest_parent)
    # ★ 记住用户本次使用的源目录和目标父目录，下次启动时自动填入
    save_last_dirs(raw_dir, raw_dest_parent)
    session_state["folder_templates"] = folder_templates.copy()
    session_state["folders"] = compute_destination_folders(raw_dest_parent, session_state["folder_templates"])
    session_state["decisions"] = {}

    return jsonify({
        "count": len(images),
        "images": images,
        "templates": session_state["folder_templates"],
        "folders": session_state["folders"],
    })


@app.route("/api/image/<int:index>")
def get_image(index: int):
    """
    Stream the image at position *index* in the current session's image list.

    The correct MIME type is inferred from the file extension so that the
    browser can render SVG, AVIF, and other non-JPEG formats correctly.
    """
    images = session_state["images"]
    source = session_state["source_dir"]
    if not images or index >= len(images):
        return jsonify({"error": "图片不存在"}), 404

    path = os.path.join(source, images[index])
    ext = Path(path).suffix.lower()
    mime_map = {
        ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
        ".png": "image/png", ".gif": "image/gif",
        ".bmp": "image/bmp", ".webp": "image/webp",
        ".svg": "image/svg+xml", ".ico": "image/x-icon",
        ".tiff": "image/tiff", ".tif": "image/tiff",
        ".avif": "image/avif",
    }
    mime = mime_map.get(ext, "image/jpeg")
    return send_file(path, mimetype=mime)


@app.route("/api/image/<int:index>/meta")
def get_image_meta(index: int):
    """返回指定图片的元信息（路径、大小、像素、时间）。"""
    images = session_state["images"]
    source = session_state["source_dir"]
    if not images or index >= len(images):
        return jsonify({"error": "not found"}), 404

    rel = images[index]
    full = os.path.join(source, rel)
    if not os.path.isfile(full):
        return jsonify({"error": "not found"}), 404

    try:
        st = os.stat(full)
        meta: dict = {
            "path": os.path.abspath(full),
            "size": f"{st.st_size / 1024:.1f} KB",
            "created": "",
            "modified": "",
            "pixels": "",
        }
        # 时间
        import datetime
        meta["created"] = datetime.datetime.fromtimestamp(st.st_ctime).strftime("%Y-%m-%d %H:%M")
        meta["modified"] = datetime.datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%d %H:%M")

        return jsonify(meta)
    except Exception:
        return jsonify({"error": "read failed"}), 500


@app.route("/api/decide", methods=["POST"])
def decide():
    """
    Record a sorting decision for the image at the given index.

    Expected JSON body:
      ``index``  — 0-based position in the image list
      ``action`` — one of ``"move"``, ``"delete"``, ``"skip"``
      ``dest``   — destination folder key (required when action is ``"move"``)

    Returns the next index and a ``done`` flag when all images are processed.
    """
    data = request.json
    index = data.get("index")
    action = data.get("action")   # "move" | "delete" | "skip"
    dest_key = data.get("dest")   # folder key, or None for non-move actions

    images = session_state["images"]
    if index is None or index >= len(images):
        return jsonify({"error": "无效的图片索引"}), 400

    file_path = images[index]
    active_folders = get_active_folders()

    if action == "move":
        # ★ __root__ 表示移动到目标父目录根目录（不进入子文件夹）
        if dest_key == "__root__":
            root_path = expand(session_state["destination_parent"] or DEFAULT_DEST_PARENT)
            session_state["decisions"][file_path] = {
                "action": "move",
                "dest_key": "__root__",
                "dest_label": "根目录",
                "dest_path": root_path,
            }
        else:
            folder = next((f for f in active_folders if f["key"] == dest_key), None)
            if not folder:
                return jsonify({"error": "无效的目标文件夹"}), 400
            session_state["decisions"][file_path] = {
                "action": "move",
                "dest_key": dest_key,
                "dest_label": folder["label"],
                "dest_path": folder["path"],
            }
    elif action == "delete":
        session_state["decisions"][file_path] = {"action": "delete"}
    elif action == "skip":
        session_state["decisions"][file_path] = {"action": "skip"}

    next_index = index + 1
    session_state["current_index"] = next_index
    done = next_index >= len(images)
    return jsonify({"next_index": next_index, "done": done})


@app.route("/api/review")
def review():
    """
    Return all recorded decisions plus any images not yet assigned a decision.

    The frontend uses this to populate the Review screen before the user
    confirms that changes should be applied.
    """
    decisions = session_state["decisions"]
    images = session_state["images"]
    # Identify images that the user navigated past without making a decision.
    undecided = [img for img in images if img not in decisions]
    return jsonify({
        "decisions": decisions,
        "undecided": undecided,
        "source_dir": session_state["source_dir"],
    })


@app.route("/api/run", methods=["POST"])
def run():
    """
    Apply all recorded decisions (move / delete) to the filesystem.

    This is the **only** route that mutates files on disk.  Files are only
    moved or deleted after the user explicitly clicks RUN on the Review screen.

    Collisions are resolved by appending a numeric suffix so existing files at
    the destination are never silently overwritten.

    Session state is cleared after a successful run so the user can start a
    fresh scan without restarting the server.
    """
    decisions = session_state["decisions"]
    source = session_state["source_dir"]
    dest_parent = session_state["destination_parent"] or DEFAULT_DEST_PARENT
    active_templates = session_state["folder_templates"] or folder_templates
    results = {"moved": [], "deleted": [], "skipped": [], "errors": []}

    # ★ 用 session 最新数据构建 key → 绝对路径 映射，确保目标目录正确
    folder_map = {f["key"]: f["path"] for f in compute_destination_folders(dest_parent, active_templates)}

    for file_path, decision in decisions.items():
        src = os.path.join(source, file_path)
        action = decision["action"]

        if action == "skip":
            results["skipped"].append(file_path)
            continue

        # Guard against files that were removed externally between scan and run.
        if not os.path.exists(src):
            results["errors"].append({"file": file_path, "reason": "源文件已缺失"})
            continue

        if action == "delete":
            try:
                os.remove(src)
                results["deleted"].append(file_path)
            except Exception as e:
                results["errors"].append({"file": file_path, "reason": str(e)})

        elif action == "move":
            # ★ 通过 dest_key 从最新 folder_map 取路径，避免 dest_path 过期/错误
            dest_key = decision.get("dest_key", "")
            if dest_key == "__root__":
                dest_dir = expand(session_state["destination_parent"] or DEFAULT_DEST_PARENT)
            else:
                dest_dir = folder_map.get(dest_key, "")
                if not dest_dir and "dest_path" in decision:
                    dest_dir = decision["dest_path"]
                if not dest_dir and "dest_label" in decision:
                    for f in compute_destination_folders(dest_parent, active_templates):
                        if f["label"] == decision["dest_label"]:
                            dest_dir = f["path"]
                            break

            try:
                os.makedirs(dest_dir, exist_ok=True)
                base_name = os.path.basename(file_path)
                dest_file = os.path.join(dest_dir, base_name)
                # If a file with the same name already exists, append _1, _2, …
                if os.path.exists(dest_file):
                    base, ext = os.path.splitext(base_name)
                    counter = 1
                    while os.path.exists(dest_file):
                        dest_file = os.path.join(dest_dir, f"{base}_{counter}{ext}")
                        counter += 1
                shutil.move(src, dest_file)
                results["moved"].append({"file": file_path, "to": decision.get("dest_label", "")})
            except Exception as e:
                results["errors"].append({"file": file_path, "reason": str(e)})

    # Reset session so the interface returns cleanly to the setup screen.
    session_state["decisions"] = {}
    session_state["images"] = []
    session_state["source_dir"] = None
    session_state["current_index"] = 0
    session_state["destination_parent"] = None
    session_state["folder_templates"] = []
    session_state["folders"] = []

    return jsonify(results)


@app.route("/api/undo", methods=["POST"])
def undo():
    """
    Remove the decision for the most recently decided image and step back.

    This allows the user to change their mind without restarting the scan.
    Only one level of undo per call is supported; call repeatedly to step
    back further.
    """
    decisions = session_state["decisions"]
    images = session_state["images"]
    idx = session_state["current_index"]

    if idx > 0:
        prev_idx = idx - 1
        prev_file = images[prev_idx]
        # Remove whichever decision was made for the previous image (if any).
        decisions.pop(prev_file, None)
        session_state["current_index"] = prev_idx
        return jsonify({"index": prev_idx})
    return jsonify({"error": "Nothing to undo"}), 400


# ── Browse directory (native picker) ────────────────────────────────────────
@app.route("/api/browse")
def browse_directory():
    """Open native directory picker and return selected path."""
    try:
        import tkinter as tk
        from tkinter import filedialog
        root = tk.Tk()
        root.withdraw()
        root.attributes("-topmost", True)
        path = filedialog.askdirectory(title="选择目录")
        root.destroy()
    except Exception:
        path = ""
    return jsonify({"path": path or ""})




# ── Scan subdirectories ────────────────────────────────────────────────────
@app.route("/api/scan-subdirs", methods=["POST"])
def scan_subdirs():
    """List immediate child directories of the given parent."""
    data = request.json or {}
    parent_raw = data.get("parent", "").strip()
    if not parent_raw:
        return jsonify({"error": "未提供父目录路径"}), 400

    parent = expand(parent_raw)
    if not os.path.isdir(parent):
        return jsonify({"error": f"目录不存在: {parent}"}), 404

    subdirs = sorted([
        d.name for d in Path(parent).iterdir()
        if d.is_dir() and not d.name.startswith('.')
    ])
    return jsonify({"subdirs": subdirs})


# ── Profiles API (multi-group folder templates) ────────────────────────────
@app.route("/api/profiles")
def get_profiles():
    """Return all profile names, the active profile name, and its templates."""
    global profiles_data
    if not profiles_data:
        profiles_data = _load_profiles()

    active_templates = _get_profile_folders(ACTIVE_PROFILE)
    active_action_keys = _get_profile_action_keys(ACTIVE_PROFILE)
    dest_parent = session_state["destination_parent"] or DEFAULT_DEST_PARENT
    folders_list = compute_destination_folders(dest_parent, active_templates)

    return jsonify({
        "profiles": list(profiles_data.keys()),
        "active_profile": ACTIVE_PROFILE,
        "templates": active_templates,
        "folders": folders_list,
        "action_keys": active_action_keys,
        "last_dirs": load_last_dirs(),
    })


@app.route("/api/profiles", methods=["POST"])
def manage_profiles():
    """
    Manage profiles: switch, create, or delete.

    JSON body:
      action    — "switch" | "create" | "delete"
      name      — profile name (required for switch/delete)
      templates — list of templates (required for create)
    """
    global ACTIVE_PROFILE, profiles_data

    if not profiles_data:
        profiles_data = _load_profiles()

    data = request.json or {}
    action = data.get("action", "").strip().lower()
    name = (data.get("name") or "").strip()

    if action == "switch":
        if not name or name not in profiles_data:
            return (jsonify({"error": f"配置组不存在: {name}"}), 404)
        ACTIVE_PROFILE = name
        _save_profiles()
        active_tmpl = _get_profile_folders(name)
        active_keys = _get_profile_action_keys(name)
        dest_parent = session_state["destination_parent"] or DEFAULT_DEST_PARENT
        return jsonify({
            "active_profile": ACTIVE_PROFILE,
            "templates": active_tmpl,
            "folders": compute_destination_folders(dest_parent, active_tmpl),
            "action_keys": active_keys,
        })

    elif action == "create":
        if not name:
            return (jsonify({"error": "请提供配置组名称"}), 400)
        if name in profiles_data:
            return (jsonify({"error": f"配置组已存在: {name}"}), 400)

        raw_templates = data.get("templates")
        if raw_templates is None:
            templates = DEFAULT_FOLDER_TEMPLATES.copy()
        else:
            try:
                templates = normalize_folder_templates(raw_templates)
            except ValueError as e:
                return (jsonify({"error": str(e)}), 400)

        profiles_data[name] = {
            "folders": templates,
            "action_keys": DEFAULT_ACTION_KEYS.copy(),
        }
        ACTIVE_PROFILE = name
        _save_profiles()
        dest_parent = session_state["destination_parent"] or DEFAULT_DEST_PARENT
        return jsonify({
            "profiles": list(profiles_data.keys()),
            "active_profile": ACTIVE_PROFILE,
            "templates": templates,
            "folders": compute_destination_folders(dest_parent, templates),
            "action_keys": DEFAULT_ACTION_KEYS.copy(),
        })

    elif action == "delete":
        if not name or name not in profiles_data:
            return (jsonify({"error": f"配置组不存在: {name}"}), 404)
        if len(profiles_data) <= 1:
            return (jsonify({"error": "至少需要保留一个配置组"}), 400)

        del profiles_data[name]
        if ACTIVE_PROFILE == name:
            ACTIVE_PROFILE = next(iter(profiles_data))
        _save_profiles()
        active_tmpl = _get_profile_folders(ACTIVE_PROFILE)
        active_keys = _get_profile_action_keys(ACTIVE_PROFILE)
        dest_parent = session_state["destination_parent"] or DEFAULT_DEST_PARENT
        return jsonify({
            "profiles": list(profiles_data.keys()),
            "active_profile": ACTIVE_PROFILE,
            "templates": active_tmpl,
            "folders": compute_destination_folders(dest_parent, active_tmpl),
            "action_keys": active_keys,
        })

    return (jsonify({"error": "未知操作"}), 400)


# ── Run (SSE streaming version) ────────────────────────────────────────────
@app.route("/api/run-stream", methods=["POST"])
def run_stream():
    """Stream progress while applying decisions via SSE."""

    from flask import Response as FlaskResponse
    import json as _json

    def generate():
        decisions = session_state["decisions"]
        source = session_state["source_dir"]
        dest_parent = session_state["destination_parent"] or DEFAULT_DEST_PARENT
        active_templates = session_state["folder_templates"] or folder_templates
        total = len(decisions)
        results = {"moved": [], "deleted": [], "skipped": [], "errors": []}

        if total == 0:
            yield f"data: {_json.dumps({'done': True, 'results': results})}\n\n"
            return

        # ★ 用 session 最新数据构建 key → 绝对路径 映射，确保目标目录正确
        folder_map = {f["key"]: f["path"] for f in compute_destination_folders(dest_parent, active_templates)}

        for i, (file_path, decision) in enumerate(decisions.items()):
            src = os.path.join(source, file_path)
            action = decision["action"]

            if action == "skip":
                results["skipped"].append(file_path)
                yield f"data: {_json.dumps({'progress': i + 1, 'total': total, 'current_file': file_path})}\n\n"
                continue

            if not os.path.exists(src):
                results["errors"].append({"file": file_path, "reason": "源文件已缺失"})
                yield f"data: {_json.dumps({'progress': i + 1, 'total': total, 'current_file': file_path})}\n\n"
                continue

            if action == "delete":
                try:
                    os.remove(src)
                    results["deleted"].append(file_path)
                except Exception as e:
                    results["errors"].append({"file": file_path, "reason": str(e)})
            elif action == "move":
                # ★ 通过 dest_key 从最新 folder_map 取路径，避免 decide 时记录的 dest_path 过期/错误
                dest_key = decision.get("dest_key", "")
                if dest_key == "__root__":
                    dest_dir = expand(session_state["destination_parent"] or DEFAULT_DEST_PARENT)
                else:
                    dest_dir = folder_map.get(dest_key, "")
                    # 兼容旧版决策数据（没有 dest_key 字段时回退到 dest_path 或 label 匹配）
                    if not dest_dir and "dest_path" in decision:
                        dest_dir = decision["dest_path"]
                    if not dest_dir and "dest_label" in decision:
                        for f in compute_destination_folders(dest_parent, active_templates):
                            if f["label"] == decision["dest_label"]:
                                dest_dir = f["path"]
                                break

                if not dest_dir:
                    results["errors"].append({"file": file_path, "reason": "无法确定目标路径"})
                    yield f"data: {_json.dumps({'progress': i + 1, 'total': total, 'current_file': file_path})}\n\n"
                    continue

                try:
                    os.makedirs(dest_dir, exist_ok=True)
                    base_name = os.path.basename(file_path)
                    dest_file = os.path.join(dest_dir, base_name)
                    if os.path.exists(dest_file):
                        base, ext = os.path.splitext(base_name)
                        counter = 1
                        while os.path.exists(dest_file):
                            dest_file = os.path.join(dest_dir, f"{base}_{counter}{ext}")
                            counter += 1
                    shutil.move(src, dest_file)
                    results["moved"].append({"file": file_path, "to": decision.get("dest_label", "")})
                except Exception as e:
                    results["errors"].append({"file": file_path, "reason": str(e)})

            yield f"data: {_json.dumps({'progress': i + 1, 'total': total, 'current_file': file_path})}\n\n"

        # Reset session state
        session_state["decisions"] = {}
        session_state["images"] = []
        session_state["source_dir"] = None
        session_state["current_index"] = 0
        session_state["destination_parent"] = None
        session_state["folder_templates"] = []
        session_state["folders"] = []

        yield f"data: {_json.dumps({'done': True, 'results': results})}\n\n"

    return FlaskResponse(generate(), mimetype='text/event-stream')


# ── Heartbeat (auto-shutdown when browser tab closes) ────────────────────────
_last_heartbeat = time.time()
_HEARTBEAT_TIMEOUT = 30  # 秒，超过此时间无心跳则视为浏览器已关闭


@app.route("/api/heartbeat", methods=["POST"])
def heartbeat():
    """前端定时调用，证明浏览器标签页仍然打开。"""
    global _last_heartbeat
    _last_heartbeat = time.time()
    return jsonify({"ok": True})


def _watchdog():
    """后台线程：心跳超时后自动终止进程。"""
    global _last_heartbeat
    # 给前端足够的启动时间
    _last_heartbeat = time.time() + 15
    while True:
        time.sleep(5)
        if time.time() - _last_heartbeat > _HEARTBEAT_TIMEOUT:
            print("[sortr] 心跳超时，浏览器已关闭，自动退出")
            os._exit(0)


# ── Entry point ───────────────────────────────────────────────────────────────

def find_free_port(start: int = 5050, max_tries: int = 20) -> int:
    """
    Find a free TCP port on localhost, starting from *start*.

    Iterates up to *max_tries* consecutive ports until one is available.
    Raises ``RuntimeError`` if no free port is found within the range.
    """
    for port in range(start, start + max_tries):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
            # connect_ex returns 0 only if the port is already in use.
            if sock.connect_ex(("127.0.0.1", port)) != 0:
                return port
    raise RuntimeError(f"Could not find a free port in range {start}–{start + max_tries - 1}")


if __name__ == "__main__":
    port = find_free_port()
    url = f"http://127.0.0.1:{port}"

    if getattr(sys, "frozen", False):
        # ── Standalone executable mode (PyInstaller) ──────────────────────
        # 用 make_server 直接创建服务器，省去轮询等待
        from werkzeug.serving import make_server

        server = make_server("127.0.0.1", port, app, threaded=True)

        # 启动心跳看门狗：浏览器标签页关闭后自动退出进程
        threading.Thread(target=_watchdog, daemon=True).start()

        # 在后台线程启动服务器
        threading.Thread(target=server.serve_forever, daemon=True).start()

        # 服务器已在监听，立即打开浏览器
        webbrowser.open(url)
        print(f"SORTR v{__version__} — {url}")

        # 主线程阻塞，保持进程存活
        try:
            while True:
                time.sleep(1)
        except KeyboardInterrupt:
            server.shutdown()
    else:
        # ── Development mode ──────────────────────────────────────────────
        print(f"SORTR v{__version__} — development server on {url}")
        app.run(debug=True, host="127.0.0.1", port=port)