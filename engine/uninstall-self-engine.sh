#!/bin/bash
# uninstall-self-engine.sh — 卸载自研引擎(也能卸 X1a0He),把微信还原成干净(无多开)状态。
#   1) 还原干净业务体(wechat.dylib.original → wechat.dylib),剥离任何注入。
#   2) 移除引擎 dylib。
#   3) 还原门①(若 loader 被 byte-patch 过,写回原字节)。
#   4) adhoc 重签(保留 entitlements,不 --deep),清 quarantine。
# 注:无法还原腾讯原始签名(那需重装微信);本脚本让微信恢复正常使用、不再多开。
# 用法: uninstall-self-engine.sh /path/to/WeChat.app   (GUI 退微信后经管理员权限调用)
set -euo pipefail
err() { echo "[uninstall][ERR] $*" >&2; exit 1; }
log() { echo "[uninstall] $*"; }

APP="${1:-}"
[ -d "$APP" ] || err "找不到 app: $APP"
LOADER="$APP/Contents/MacOS/WeChat"
BODY="$APP/Contents/Resources/wechat.dylib"
ORIG="$BODY.original"
FRAMEWORKS="$APP/Contents/Frameworks"
ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -f "$LOADER" ] || err "缺 loader: $LOADER"

# 1) 还原干净业务体
if [ -f "$ORIG" ]; then
  cp -f "$ORIG" "$BODY"
  log "已还原干净业务体(剥离注入)"
else
  log "无 .original 备份,业务体可能本就干净,跳过"
fi

# 2) 移除引擎 dylib(及 X1a0He 插件的 .bak 不动)
rm -f "$FRAMEWORKS/WeChatMultiEngine.dylib" && log "已移除引擎 dylib" || true

# 3) 还原门①(loader byte-patch)
if [ -f "$ENGINE_DIR/locate_gate1.py" ]; then
  GATE1_OUT="$(python3 "$ENGINE_DIR/locate_gate1.py" "$LOADER" 2>/dev/null || true)"
  eval "$GATE1_OUT" 2>/dev/null || true
  if [ -n "${GATE1_FAT_OFF:-}" ] && [ -n "${GATE1_ORIG_LE:-}" ] && [ -n "${GATE1_PATCH_LE:-}" ]; then
    CUR=$(python3 - "$LOADER" "$GATE1_FAT_OFF" <<'PY'
import sys
p=sys.argv[1]; off=int(sys.argv[2],16)
with open(p,"rb") as f: f.seek(off); print(f.read(4).hex())
PY
)
    if [ "$CUR" = "$GATE1_PATCH_LE" ]; then
      python3 - "$LOADER" "$GATE1_FAT_OFF" "$GATE1_ORIG_LE" <<'PY'
import sys
p=sys.argv[1]; off=int(sys.argv[2],16); b=bytes.fromhex(sys.argv[3])
with open(p,"r+b") as f: f.seek(off); f.write(b)
print("[uninstall][gate1] 已还原 loader 门①原字节")
PY
    else
      log "门① loader 未处于 patched 状态,跳过还原"
    fi
  fi
fi

# 4) adhoc 重签(保留 entitlements,不 --deep)
ENT="$(mktemp /tmp/wcm-uninst-ent.XXXXXX.plist)"
codesign -d --entitlements "$ENT" --xml "$LOADER" 2>/dev/null || true
codesign -f -s - "$BODY" 2>&1 | tail -1
[ -f "$FRAMEWORKS/X1a0HeWeChatPlugin.dylib" ] && codesign -f -s - "$FRAMEWORKS/X1a0HeWeChatPlugin.dylib" 2>&1 | tail -1 || true
codesign -f -s - --entitlements "$ENT" "$LOADER" 2>&1 | tail -1
codesign -f -s - --entitlements "$ENT" "$APP" 2>&1 | tail -1
xattr -cr "$APP" 2>/dev/null || true
rm -f "$ENT"
log "完成:多开引擎已卸载,微信还原为正常(无多开)状态。"
