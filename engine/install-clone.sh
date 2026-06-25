#!/bin/bash
# install-clone.sh — clone-bundle 多开(今天就能用的并存多开方案)。
#
# 把 /Applications/WeChat.app 克隆成一个独立 bundleId 的副本,装上自研引擎,
# 这样它与原版(以及彼此)各自独立常驻、互不去重 —— 实测 2 实例并存 >32s。
#
# 为什么不是"同一个 .app 路径叠开":
#   同 bundleId + 同路径叠开被业务体内一道"早于 NSRunningApplication 的单例门"挡住
#   (见 re/spawn-verdict.md §2/§5),裸 open -n / posix_spawn / 各种 swizzle 都打不穿,
#   要打穿需进程内运行时 byte-patch 业务体(X1a0He 路线,patch 点尚未定位)。
#   clone-bundle 改 bundleId 后该门天然不触发,是当前最稳的并存多开落地。
#
# 绝不触碰 /Applications/WeChat.app(只读取它做克隆源)。
#
# 用法:
#   install-clone.sh <实例序号|新bundleId后缀> [目标目录]
# 例:
#   install-clone.sh 2
#     -> 克隆出 com.tencent.xinWeChat.2,默认放 ~/Library/Application Support/WeChatMulti/Instances/2/WeChat.app
#   install-clone.sh work ~/Apps
#     -> com.tencent.xinWeChat.work,放 ~/Apps/WeChat-work.app
#
# 依赖: ditto / PlistBuddy / codesign / lipo / otool / python3。
set -euo pipefail

ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_APP="/Applications/WeChat.app"
BASE_ID="com.tencent.xinWeChat"

err() { echo "[clone][ERR] $*" >&2; exit 1; }
log() { echo "[clone] $*"; }

SUFFIX="${1:-}"
[ -n "$SUFFIX" ] || err "用法: $0 <实例序号|后缀> [目标目录]"
# 后缀只允许字母数字(bundleId 安全)
case "$SUFFIX" in
  *[!A-Za-z0-9]*) err "后缀只能是字母数字: $SUFFIX";;
esac

DEST_DIR="${2:-$HOME/Library/Application Support/WeChatMulti/Instances/$SUFFIX}"
DEST_APP="$DEST_DIR/WeChat.app"
NEW_ID="$BASE_ID.$SUFFIX"

[ -d "$SRC_APP" ] || err "找不到源: $SRC_APP"
# 源若已被 X1a0He 注入也无妨——我们只读它克隆;但提示一下。
if otool -L "$SRC_APP/Contents/Resources/wechat.dylib" 2>/dev/null | grep -q X1a0He; then
  log "提示: 源是 X1a0He 注入版;克隆会连带其插件,通常无害(可后续清理)。"
fi

log "克隆 $SRC_APP -> $DEST_APP (bundleId=$NEW_ID)…"
mkdir -p "$DEST_DIR"
rm -rf "$DEST_APP"
ditto "$SRC_APP" "$DEST_APP"

# 改顶层 CFBundleIdentifier(这是 LS 去重 / 业务体单例域的钥匙)。
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $NEW_ID" "$DEST_APP/Contents/Info.plist" \
  || /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string $NEW_ID" "$DEST_APP/Contents/Info.plist"
GOT_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST_APP/Contents/Info.plist")"
[ "$GOT_ID" = "$NEW_ID" ] || err "bundleId 未改成: 实读 $GOT_ID"
log "bundleId = $GOT_ID ✓"

# 装引擎(门①静态 patch + 门③ swizzle + 逐文件 adhoc 重签)。
log "安装自研引擎…"
bash "$ENGINE_DIR/install-self-engine.sh" "$DEST_APP"

# 防 AppTranslocation(adhoc 重签后移除 quarantine 不影响签名有效性)。
xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true

log "完成。启动该实例:"
log "  open -n \"$DEST_APP\"      # 或"
log "  \"$DEST_APP/Contents/MacOS/WeChat\" &   # posix_spawn 直拉,更可控"
log "它与 /Applications 原版(及其它 clone)各自独立常驻、并存多开。"
