#!/bin/bash
# patch_ksplayer.sh —— 给 SPM 拉下来的 KSPlayer 源码打 NewTV 防御补丁。
#
# 为什么需要它：
#   KSPlayer be7f60d3 的 FFmpegAssetTrack.init(codecpar:) 对直播流（DVB/MPEG-TS
#   带的 bin_data / teletext / 空 side data / 野 extradata_size）有多处裸指针
#   解引用，真机实测 EXC_BAD_ACCESS 直接闪退（Runner-2026-10-11-120910.ips）。
#   KSPlayer 是 SPM 远程包、改不了源码，上游 HEAD 又已转成闭源 xcframework，
#   只能在构建前对本地检出打补丁。补丁内容：ios/scripts/patches/*.patch
#
# 用法：
#   bash ios/scripts/patch_ksplayer.sh            # 自动定位 DerivedData 并打补丁
#   DERIVED_DATA=/path/to/DerivedData bash ios/scripts/patch_ksplayer.sh
#
# 幂等：已打过的检出会直接跳过（git apply --reverse --check 判定）。

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="$SCRIPT_DIR/patches/ksplayer-be7f60d3-ffassettrack-guard.patch"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ ! -f "$PATCH_FILE" ]; then
  echo "❌ 补丁文件不存在: $PATCH_FILE"
  exit 1
fi

# ── 定位 KSPlayer 的 SPM 检出目录 ──────────────────────────────
find_checkout() {
  local dd="$1"
  [ -d "$dd" ] || return 1
  # DerivedData/<App>-xxxx/SourcePackages/checkouts/KSPlayer
  for d in "$dd"/*/SourcePackages/checkouts/KSPlayer; do
    if [ -f "$d/Sources/KSPlayer/MEPlayer/FFmpegAssetTrack.swift" ]; then
      echo "$d"
      return 0
    fi
  done
  return 1
}

CHECKOUT=""
if [ -n "$DERIVED_DATA" ]; then
  CHECKOUT="$(find_checkout "$DERIVED_DATA" || true)"
fi
if [ -z "$CHECKOUT" ]; then
  CHECKOUT="$(find_checkout "$HOME/Library/Developer/Xcode/DerivedData" || true)"
fi

# ── 还没拉过包 → 先 resolve（本地首次构建的场景）─────────────────
if [ -z "$CHECKOUT" ]; then
  echo "==> 未找到 KSPlayer 检出，先执行 xcodebuild -resolvePackageDependencies"
  (cd "$IOS_DIR" && xcodebuild -resolvePackageDependencies \
    -workspace Runner.xcworkspace -scheme Runner >/dev/null 2>&1) || true
  if [ -n "$DERIVED_DATA" ]; then
    CHECKOUT="$(find_checkout "$DERIVED_DATA" || true)"
  fi
  if [ -z "$CHECKOUT" ]; then
    CHECKOUT="$(find_checkout "$HOME/Library/Developer/Xcode/DerivedData" || true)"
  fi
fi

if [ -z "$CHECKOUT" ]; then
  echo "❌ 仍找不到 KSPlayer 的 SPM 检出（DerivedData/*/SourcePackages/checkouts/KSPlayer）"
  echo "   请先在 Xcode 里 resolve 一次包依赖，或指定 DERIVED_DATA"
  exit 1
fi

echo "==> KSPlayer 检出: $CHECKOUT"

# ── 幂等打补丁 ────────────────────────────────────────────────
if (cd "$CHECKOUT" && git apply --check "$PATCH_FILE" 2>/dev/null); then
  (cd "$CHECKOUT" && git apply "$PATCH_FILE")
  echo "✅ 补丁已应用"
elif (cd "$CHECKOUT" && git apply --reverse --check "$PATCH_FILE" 2>/dev/null); then
  echo "✅ 补丁此前已应用，跳过"
else
  echo "❌ 补丁打不上也退不掉 —— KSPlayer 源码与 be7f60d3 不一致（版本被改过？）"
  exit 1
fi
