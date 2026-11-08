#!/usr/bin/env bash
# 预取 Gradle 发行版，把 wrapper 的 distributionUrl 改指本地 file:// 副本。
#
# 背景（2026-11）：services.gradle.org 对 /distributions/ 的请求 307 重定向到
# GitHub release 资产（gradle/gradle-distributions），被 GitHub release CDN
# 504 故障连带打挂（与 prefetch_sqlite3_assets.sh 同一故障面）。CI 的
# Android job 因 Gradle wrapper 下载发行版失败而挂。
#
# 绕法：gh release download 走 api.github.com 通道（不受影响）预取 zip，
# unzip -t 校验完整性后，把当前 checkout 副本的 gradle-wrapper.properties
# 的 distributionUrl 改为 file:// 指向它。只改 CI 工作副本——仓库文件与
# 本地构建行为不受任何影响。版本动态取自 distributionUrl，升级零维护。
#
# 前置: gh 已认证（CI 步骤传 GH_TOKEN）；在仓库任意目录调用均可。
set -euo pipefail

cd "$(dirname "$0")/../android"
props=gradle/wrapper/gradle-wrapper.properties

# distributionUrl 值里的 ':' 是 properties 转义（https\:），先还原再解析；
# properties 可能是 CRLF 行尾，\r 混进 pattern 会让 gh 报误导性的
# "release not found"——务必剥掉。
url=$(sed -n 's/^distributionUrl=\(.*\)/\1/p' "$props" | sed 's/\\:/:/g' | tr -d '\r')
ver=$(basename "$url" | sed -n 's/^gradle-\(.*\)-\(all\|bin\)\.zip/\1/p')
[ -n "$ver" ] || { echo "::error::未从 distributionUrl 解析出 Gradle 版本: $url"; exit 1; }

# 固定路径（非 mktemp）：本脚本是独立 CI step，退出后 zip 必须存活到
# Build 步骤结束；mktemp+trap 清理会删掉 file:// 目标。job 生命周期内
# runner 磁盘持续可用，重复执行命中缓存即跳过 220MB 下载。
dist=/tmp/gradle-dist-prefetch
zip="gradle-$ver-all.zip"
mkdir -p "$dist"

if [ -f "$dist/$zip" ] && unzip -t "$dist/$zip" > /dev/null 2>&1; then
  echo "$zip 已预取且完整，跳过下载"
else
  echo "下载 Gradle $ver（api.github.com 通道，~220MB）"
  # gh 偶发把 API 抖动报成 "release not found"（实测重试即过），大文件
  # 也可能中断——重试 3 次，间隔递增。
  ok=0
  for attempt in 1 2 3; do
    if gh release download "v$ver" --repo gradle/gradle-distributions \
        --pattern "$zip" --dir "$dist"; then
      ok=1; break
    fi
    echo "::warning::gh release download 第 ${attempt} 次失败，重试…"
    sleep $((attempt * 5))
  done
  [ "$ok" = 1 ] || { echo "::error::gh release download 三次均失败"; exit 1; }
  unzip -t "$dist/$zip" > /dev/null   # 官方未 pin sha256，以 zip 完整性自检兜底
fi

# properties 里 ':' 需转义；file:// 三斜杠
newurl="file\\://$dist/$zip"
sed -i "s|^distributionUrl=.*|distributionUrl=$newurl|" "$props"
echo "Gradle $ver 预取完成，wrapper 已指向本地副本（仅本次 CI 生效）"
