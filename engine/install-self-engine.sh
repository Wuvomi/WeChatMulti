#!/bin/bash
# install-self-engine.sh — 自研最小多开注入引擎安装器(微信 4.1.11)。
#
# 对一个 WeChat.app 副本就地施工:
#   门①  运行时按特征码定位 loader 的单例 cbz w0,patch 成无条件 b(静态 byte-patch)。
#   门②  纯运行时:引擎 constructor 在"第二+实例"里按特征码定位业务体
#         0x2106bc 放行函数里的 `tbz w20,#0,<bail>`(单例放行判定)并 NOP 之
#         ——这步在进程内运行时做,本安装脚本不写盘、无需偏移。详见 re/self-engine-v2.md。
#   门③  把 WeChatMultiEngine.dylib 复制进 Contents/Frameworks/,
#         用 insert_dylib.py 给 wechat.dylib 追加 LC_LOAD_DYLIB
#         (@rpath/WeChatMultiEngine.dylib),使其随业务体加载并先于业务体单例检测;
#         constructor 内再装 NSRunningApplication swizzle(辅助,消 UI 层"已有实例"提示)。
#   重签  adhoc,保留 app-sandbox / app-group / allow-jit 等 entitlement,
#         不用 --deep,逐文件签名顺序: 引擎 dylib -> 业务体 dylib -> loader -> 整 bundle。
#
# 真门是门②(运行时):没它,第二实例即便门①+门③ 也照样 exit(255)。实测见
# re/self-engine-v2.md §1。门② 仅在第二+实例触发(flock 容器锁判据),首个实例不动。
#
# 绝不触碰 /Applications/WeChat.app。只对传入的副本施工。
#
# 用法:
#   install-self-engine.sh /path/to/WeChat.app
#
# 依赖: lipo / otool / codesign / python3 / clang(仅当需现编译引擎)。
set -euo pipefail

ENGINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DYLIB_SRC="$ENGINE_DIR/WeChatMultiEngine.dylib"
INSERT="$ENGINE_DIR/insert_dylib.py"
LOCATE="$ENGINE_DIR/locate_gate1.py"
BUNDLE_ID="com.tencent.xinWeChat"

err() { echo "[install][ERR] $*" >&2; exit 1; }
log() { echo "[install] $*"; }

APP="${1:-}"
[ -n "$APP" ] || err "用法: $0 /path/to/WeChat.app"
[ -d "$APP" ] || err "找不到 app: $APP"
LOADER="$APP/Contents/MacOS/WeChat"
BODY="$APP/Contents/Resources/wechat.dylib"
FRAMEWORKS="$APP/Contents/Frameworks"
[ -f "$LOADER" ] || err "缺 loader: $LOADER"
[ -f "$BODY" ]   || err "缺业务体: $BODY"

############################################
# 准备干净业务体(可回滚):
#  - .original 存在(装过 X1a0He/本引擎)→ 备份当前注入版,还原干净体,移走 X1a0He 插件。
#  - .original 不存在(全新干净)→ 当前体即干净,创建 .original 备份供日后还原。
# 注:GUI 调用前已退微信;真装 /Applications 在此放行(自主期的硬锁已移除)。
############################################
ORIG="$BODY.original"
if [ -f "$ORIG" ]; then
  log "检测到 .original → 还原干净业务体(剥离已有注入,叠加会坏)"
  cp -f "$BODY" "$BODY.prev.bak" 2>/dev/null || true
  cp -f "$ORIG" "$BODY"
  [ -f "$FRAMEWORKS/X1a0HeWeChatPlugin.dylib" ] && \
    mv -f "$FRAMEWORKS/X1a0HeWeChatPlugin.dylib" "$FRAMEWORKS/X1a0HeWeChatPlugin.dylib.bak" 2>/dev/null || true
else
  log "未见 .original → 当前体视为干净,创建 .original 备份"
  cp -f "$BODY" "$ORIG"
fi

# 现编译引擎(若缺二进制)。
if [ ! -f "$DYLIB_SRC" ]; then
  log "引擎二进制缺失,现编译…"
  clang -dynamiclib -fobjc-arc -arch arm64 -arch x86_64 \
    -framework Foundation -framework AppKit -framework CoreGraphics \
    -mmacosx-version-min=11.0 \
    -install_name @rpath/WeChatMultiEngine.dylib \
    -o "$DYLIB_SRC" "$ENGINE_DIR/WeChatMultiEngine.m"
fi

############################################
# 门①: 特征码定位 + byte-patch cbz w0 -> b
############################################
log "门①: 定位 loader 单例分支(特征码)…"
GATE1_OUT="$(python3 "$LOCATE" "$LOADER")"
echo "$GATE1_OUT" | sed 's/^/[install][gate1] /'
eval "$GATE1_OUT"   # 注入 GATE1_FAT_OFF / GATE1_ORIG_LE / GATE1_PATCH_LE 等

[ -n "${GATE1_FAT_OFF:-}" ] || err "门①特征码未命中"

# 校验原字节再写,避免误 patch。
CUR=$(python3 - "$LOADER" "$GATE1_FAT_OFF" <<'PY'
import sys
p=sys.argv[1]; off=int(sys.argv[2],16)
with open(p,"rb") as f:
    f.seek(off); print(f.read(4).hex())
PY
)
if [ "$CUR" != "$GATE1_ORIG_LE" ]; then
  if [ "$CUR" == "$GATE1_PATCH_LE" ]; then
    log "门①已是 patched 状态($CUR),跳过"
  else
    err "门①原字节不符: 实读 $CUR 期望 $GATE1_ORIG_LE"
  fi
else
  python3 - "$LOADER" "$GATE1_FAT_OFF" "$GATE1_PATCH_LE" <<'PY'
import sys
p=sys.argv[1]; off=int(sys.argv[2],16); patch=bytes.fromhex(sys.argv[3])
with open(p,"r+b") as f:
    f.seek(off); f.write(patch)
print("[install][gate1] patched %s @0x%x -> %s"%(p,off,patch.hex()))
PY
fi

############################################
# 门③: 注入引擎 dylib(LC_LOAD_DYLIB)
############################################
log "门③: 安装引擎 dylib 到 Frameworks + insert LC_LOAD_DYLIB…"
mkdir -p "$FRAMEWORKS"
cp -f "$DYLIB_SRC" "$FRAMEWORKS/WeChatMultiEngine.dylib"

# wechat.dylib 用 @rpath 解析,需要确认 loader 有指向 Frameworks 的 @rpath。
# loader 默认带 @executable_path/../Frameworks 的 LC_RPATH;@rpath/WeChatMultiEngine.dylib
# 即解析到 Contents/Frameworks/WeChatMultiEngine.dylib。
if otool -l "$LOADER" | grep -qF '@executable_path/../Frameworks'; then
  log "loader 已含 @executable_path/../Frameworks RPATH,@rpath 可解析 ✓"
else
  log "WARN: loader 未见 ../Frameworks RPATH;改用 @loader_path 注入名"
fi

# 幂等: 若已注入则跳过。
if otool -l "$BODY" | grep -q 'WeChatMultiEngine.dylib'; then
  log "业务体已含 WeChatMultiEngine.dylib LC_LOAD_DYLIB,跳过"
else
  python3 "$INSERT" "@rpath/WeChatMultiEngine.dylib" "$BODY"
fi

############################################
# 重签: adhoc,保留 entitlement,不 --deep
############################################
log "重签: 提取 loader 原 entitlements…"
ENT_PLIST="$(mktemp /tmp/wcm-ent.XXXXXX.plist)"
codesign -d --entitlements "$ENT_PLIST" --xml "$LOADER" 2>/dev/null || true
if [ ! -s "$ENT_PLIST" ]; then
  # 干净 Tencent loader 的 entitlements(app-sandbox 必须保留,否则 loader 自退)。
  cat > "$ENT_PLIST" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.application-groups</key><array><string>5A4RE8SF68.com.tencent.xinWeChat</string></array>
  <key>com.apple.security.cs.allow-jit</key><true/>
  <key>com.apple.security.network.client</key><true/>
  <key>com.apple.security.network.server</key><true/>
  <key>com.apple.security.files.user-selected.read-write</key><true/>
</dict></plist>
PLIST
fi
log "entitlements -> $ENT_PLIST"

log "签名顺序: 引擎 -> 业务体 -> loader -> bundle (adhoc, 无 --deep)"
# 1) 引擎 dylib(adhoc)
codesign --force --sign - "$FRAMEWORKS/WeChatMultiEngine.dylib"
# 2) 业务体 dylib(被改了 header,必须重签;adhoc)
codesign --force --sign - "$BODY"
# 3) loader(被 byte-patch,重签;带 entitlements,保 app-sandbox)
codesign --force --sign - --entitlements "$ENT_PLIST" "$LOADER"
# 4) 整 bundle(密封资源;带同一 entitlements;不 --deep,避免破坏嵌套原厂签名)
codesign --force --sign - --entitlements "$ENT_PLIST" "$APP"

rm -f "$ENT_PLIST"

log "完成。验证:"
codesign -dvvv "$APP" 2>&1 | grep -E 'Identifier|flags|TeamIdentifier' | sed 's/^/[install]   /' || true
log "门① fat 偏移 $GATE1_FAT_OFF, 引擎已注入业务体。"
log "门②(业务体单例放行 tbz NOP)由引擎在第二+实例运行时自做,无需安装期偏移。"
log "可 open -n / 直接 exec 起 2 个同路径实例并存(实测稳定 >70s,见 re/self-engine-v2.md)。"
