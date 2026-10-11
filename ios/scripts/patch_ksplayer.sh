#!/bin/bash
# patch_ksplayer.sh —— 给 SPM 拉下来的 KSPlayer 源码打 NewTV 防御补丁。
#
# 为什么需要它：
#   KSPlayer be7f60d3 的 FFmpegAssetTrack.init(codecpar:) 对直播流（DVB/MPEG-TS
#   带的 bin_data / teletext / 空 side data / 野 extradata_size）有多处裸指针
#   解引用，真机实测 EXC_BAD_ACCESS 直接闪退（Runner-2026-10-11-120910/
#   133518/142555 三份 .ips，崩点机器码偏移完全一致）。
#   KSPlayer 是 SPM 远程包、改不了源码，上游 HEAD 又已转成闭源 xcframework，
#   只能在构建前对本地检出打补丁。补丁内容：ios/scripts/patches/*.patch
#   guard1 = 类型过滤/side data/extradata/sample format/profile name
#   guard2 = AVCodecDescriptor.name 与 metadata key/value 的 NULL 防护
#
# 调用方式：
#   1) CI 独立步骤（resolve 之后、build 之前）：
#        bash ios/scripts/patch_ksplayer.sh
#   2) Xcode scheme BuildAction PreAction（Runner.xcscheme 已内置，在一切编译
#      含 SPM 依赖之前执行，CI / 本地 Xcode 双覆盖，防止重新拉取覆盖补丁）：
#        KS_PATCH_SKIP_RESOLVE=1 bash "$SRCROOT/scripts/patch_ksplayer.sh"
#   3) 手动：DERIVED_DATA=/path/to/DerivedData bash ios/scripts/patch_ksplayer.sh
#
# 幂等：每个补丁独立判定（git apply --check / --reverse --check + 标记 grep）。

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_DIR="$SCRIPT_DIR/patches"
IOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ ! -d "$PATCH_DIR" ] || ! compgen -G "$PATCH_DIR/*.patch" > /dev/null; then
  echo "❌ 补丁目录不存在或没有 .patch 文件: $PATCH_DIR"
  exit 1
fi

# ── 收集所有候选 KSPlayer 检出目录 ─────────────────────────────
candidates=()

add_if_ksplayer() {
  local d="$1"
  if [ -f "$d/Sources/KSPlayer/MEPlayer/FFmpegAssetTrack.swift" ]; then
    # 去重
    local c
    for c in "${candidates[@]:-}"; do
      [ "$c" = "$d" ] && return 0
    done
    candidates+=("$d")
  fi
}

# ① Xcode Run Script 阶段：$BUILD_DIR = DerivedData/<App>-hash/Build/Products/…
#    逐级向上找 SourcePackages/checkouts/KSPlayer
if [ -n "$BUILD_DIR" ]; then
  d="$BUILD_DIR"
  for _ in 1 2 3 4; do
    add_if_ksplayer "$d/SourcePackages/checkouts/KSPlayer"
    d="$(dirname "$d")"
  done
fi

# ② 显式 DERIVED_DATA
if [ -n "$DERIVED_DATA" ] && [ -d "$DERIVED_DATA" ]; then
  for d in "$DERIVED_DATA"/*/SourcePackages/checkouts/KSPlayer; do
    [ -d "$d" ] && add_if_ksplayer "$d"
  done
fi

# ③ 默认 DerivedData
if [ -d "$HOME/Library/Developer/Xcode/DerivedData" ]; then
  for d in "$HOME/Library/Developer/Xcode/DerivedData"/*/SourcePackages/checkouts/KSPlayer; do
    [ -d "$d" ] && add_if_ksplayer "$d"
  done
fi

# ④ 一个都没找到：独立调用（非构建阶段）时先 resolve 再找一次。
#    scheme pre-action 里禁止递归调 xcodebuild（父构建正持有包管理锁）。
if [ ${#candidates[@]} -eq 0 ] && [ -z "$BUILD_DIR" ] && [ -z "$KS_PATCH_SKIP_RESOLVE" ]; then
  echo "==> 未找到 KSPlayer 检出，先执行 xcodebuild -resolvePackageDependencies"
  (cd "$IOS_DIR" && xcodebuild -resolvePackageDependencies \
    -workspace Runner.xcworkspace -scheme Runner >/dev/null 2>&1) || true
  if [ -d "$HOME/Library/Developer/Xcode/DerivedData" ]; then
    for d in "$HOME/Library/Developer/Xcode/DerivedData"/*/SourcePackages/checkouts/KSPlayer; do
      [ -d "$d" ] && add_if_ksplayer "$d"
    done
  fi
fi

if [ ${#candidates[@]} -eq 0 ]; then
  if [ -n "$BUILD_DIR" ]; then
    # 构建阶段找不到（理论不该发生 —— SPM 在 target 编译前已 resolve）：
    # 只警告不杀构建，避免非标准环境直接红；但 KSPlayer 野指针补丁没打进去，
    # 日志必须显眼。
    echo "⚠️⚠️⚠️ 构建阶段未找到 KSPlayer 检出，野指针补丁未应用！"
    echo "    BUILD_DIR=$BUILD_DIR"
    exit 0
  fi
  echo "❌ 找不到 KSPlayer 的 SPM 检出（DerivedData/*/SourcePackages/checkouts/KSPlayer）"
  echo "   请先在 Xcode 里 resolve 一次包依赖，或指定 DERIVED_DATA"
  exit 1
fi

echo "==> 发现 ${#candidates[@]} 个 KSPlayer 检出"

# ── 逐个补丁独立幂等应用 + 标记强校验 ────────────────────────────
# 每个补丁约定一个唯一标记（guard1=[NewTV]，guard2=[NewTV2]），
# 标记命中 = 该补丁已打；不同补丁互不干扰。
apply_one_patch() {
  local PATCH_FILE="$1"
  local PATCH_MARK="$2"
  local name
  name="$(basename "$PATCH_FILE")"
  local patched_any=0
  local CHECKOUT TARGET AVEXT

  for CHECKOUT in "${candidates[@]}"; do
    echo "==> [$name] 处理: $CHECKOUT"
    TARGET="$CHECKOUT/Sources/KSPlayer/MEPlayer/FFmpegAssetTrack.swift"
    AVEXT="$CHECKOUT/Sources/KSPlayer/MEPlayer/AVFFmpegExtension.swift"

    if grep -q "$PATCH_MARK" "$TARGET" 2>/dev/null || grep -q "$PATCH_MARK" "$AVEXT" 2>/dev/null; then
      echo "   ✅ [$name] 此前已应用，跳过"
      patched_any=1
      continue
    fi

    if (cd "$CHECKOUT" && git apply --check "$PATCH_FILE" 2>/dev/null); then
      (cd "$CHECKOUT" && git apply --whitespace=nowarn "$PATCH_FILE")
    elif (cd "$CHECKOUT" && git apply --reverse --check "$PATCH_FILE" 2>/dev/null); then
      echo "   ✅ [$name] 此前已应用（reverse-check），跳过"
      patched_any=1
      continue
    else
      echo "   ❌ [$name] 打不上 —— KSPlayer 源码与 be7f60d3 不一致（依赖版本被改过？）"
      exit 1
    fi

    # 打完必须验证标记真的在文件里（防止"apply 报成功但内容不对"的静默失败）
    if ! (grep -q "$PATCH_MARK" "$TARGET" 2>/dev/null || grep -q "$PATCH_MARK" "$AVEXT" 2>/dev/null); then
      echo "   ❌ [$name] 补丁命令成功但标记校验失败 —— 产物不可信，中止构建"
      exit 1
    fi
    echo "   ✅ [$name] 已应用并校验通过"
    patched_any=1
  done

  [ "$patched_any" -eq 1 ] || { echo "❌ [$name] 没有任何检出被成功补丁"; exit 1; }
}

for patch in "$PATCH_DIR"/*.patch; do
  case "$(basename "$patch")" in
    *guard2*) MARK='[NewTV2]' ;;
    *)        MARK='[NewTV]' ;;
  esac
  apply_one_patch "$patch" "$MARK"
done

echo "==> KSPlayer 补丁流程完成"
