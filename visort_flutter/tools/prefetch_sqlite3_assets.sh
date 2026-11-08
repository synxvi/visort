#!/usr/bin/env bash
# 预取 sqlite3 包的 native-assets 预编译库到 hook 缓存目录。
#
# 背景（2026-11）：GitHub release 资产下载端点（/releases/download →
# objects.githubusercontent.com）大面积持续 504。sqlite3 包的 build hook
# 无重试、不校验 HTTP 状态码，把 504 错误页（92 字节 HTML）落盘当库文件，
# 随后哈希校验失败以误导性的 "Hash of downloaded file ... expected ..." 报错
# （见 simolus3/sqlite3.dart 上游 issue）。CI 三个 job（linux 测试 /
# Android / Windows 构建）全部因此挂掉。
#
# 绕法：gh release download 走 api.github.com 通道（不受该故障影响）。
# 预先把资产下载、校验 sha256 后放入 hook 的 shared 缓存目录——
# downloadIntoOutputDirectoryShared 见缓存命中且哈希匹配即跳过下载。
# 哈希与 releaseTag 动态取自 pub-cache 内 sqlite3 包的 asset_hashes.dart，
# pubspec.lock 升级 sqlite3 版本后本脚本零改动。
#
# 用法: prefetch_sqlite3_assets.sh <linux|android|windows>
# 前置: 已 flutter pub get（pub-cache 有 sqlite3 包）；gh 已认证
#（CI 步骤传 GH_TOKEN）。在仓库任意目录调用均可。
set -euo pipefail

target="${1:?用法: $0 <linux|android|windows>}"
cd "$(dirname "$0")/.."

# --- 定位 pub-cache 中的 sqlite3 包（版本随 pubspec.lock 走）---
# pubspec.lock 可能是 CRLF 行尾（Windows 侧 checkout），一并剥掉 \r
ver=$(awk '/^  sqlite3:/{f=1} f && /^    version:/{gsub(/[\r"]/,"",$2); print $2; exit}' pubspec.lock)
[ -n "$ver" ] || { echo "::error::pubspec.lock 中找不到 sqlite3 版本"; exit 1; }

if [ -n "${PUB_CACHE:-}" ]; then
  pc="$PUB_CACHE"
elif [ -d "$HOME/.pub-cache" ]; then
  pc="$HOME/.pub-cache"
elif [ -n "${LOCALAPPDATA:-}" ] && [ -d "$LOCALAPPDATA/Pub/Cache" ]; then
  pc="$LOCALAPPDATA/Pub/Cache"   # Windows runner 的 git-bash
else
  echo "::error::定位 pub-cache 失败（PUB_CACHE / ~/.pub-cache / LOCALAPPDATA 均无）"; exit 1
fi
hashes="$pc/hosted/pub.dev/sqlite3-$ver/lib/src/hook/asset_hashes.dart"
[ -f "$hashes" ] || { echo "::error::找不到 $hashes（flutter pub get 跑过了吗？）"; exit 1; }

tag=$(sed -n "s/^const String? releaseTag = '\(.*\)';/\1/p" "$hashes" | tr -d '\r')
[ -n "$tag" ] || { echo "::error::$hashes 中未解析出 releaseTag"; exit 1; }

# get_hash <资产名> → 从 asset_hashes.dart 提取 pin 的 sha256（'.' 转义防正则通配）
get_hash() {
  local esc; esc=$(printf '%s' "$1" | sed 's/\./\\./g')
  sed -n "s/^  '$esc': '\([0-9a-f]\{64\}\)'.*/\1/p" "$hashes"
}

# --- 目标平台所需资产（release 资产名:hook 缓存内的规范文件名）---
# 缓存文件名按目标 OS 的动态库命名规则（linux/android: libsqlite3.so，
# windows: sqlite3.dll）；缓存目录名 = pin 哈希前 8 位，天然按 ABI 区分。
case "$target" in
  linux)   pairs=("libsqlite3.x64.linux.so:libsqlite3.so") ;;
  # split-per-ABI 构建 arm64 + v7a + universal（含 x86_64），三个 ABI 都要
  android) pairs=("libsqlite3.arm64.android.so:libsqlite3.so"
                  "libsqlite3.arm.android.so:libsqlite3.so"
                  "libsqlite3.x64.android.so:libsqlite3.so") ;;
  windows) pairs=("sqlite3.x64.windows.dll:sqlite3.dll") ;;
  *) echo "::error::未知目标平台 $target"; exit 1 ;;
esac

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
patterns=()
for p in "${pairs[@]}"; do patterns+=(--pattern "${p%%:*}"); done

echo "下载 sqlite3 $tag 预编译资产 ×${#pairs[@]}（api.github.com 通道）"
gh release download "$tag" --repo simolus3/sqlite3.dart "${patterns[@]}" --dir "$tmp"

# --- 哈希校验 + 落位 hook shared 缓存 ---
cache_root=".dart_tool/hooks_runner/shared/sqlite3/build"
for p in "${pairs[@]}"; do
  asset="${p%%:*}"; canon="${p##*:}"
  h=$(get_hash "$asset")
  [ -n "$h" ] || { echo "::error::asset_hashes.dart 无 $asset 的哈希（sqlite3 $ver 变更了资产清单？需更新本脚本映射）"; exit 1; }
  actual=$(sha256sum "$tmp/$asset" | cut -d' ' -f1)
  [ "$actual" = "$h" ] || { echo "::error::$asset 哈希不符（实际 $actual ≠ pin $h）"; exit 1; }
  dir="$cache_root/download-${h:0:8}"
  mkdir -p "$dir"
  cp "$tmp/$asset" "$dir/$canon"
  echo "  ✓ $asset → $dir/$canon"
done

echo "sqlite3 native assets 预取完成，hook 将命中缓存、跳过 GitHub CDN 下载"
