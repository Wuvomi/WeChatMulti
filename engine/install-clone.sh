#!/bin/bash
# install-clone.sh — bundleID 终极兜底:纯克隆多开(零注入、零 byte-patch、版本无关)。
#
# 把一份干净 WeChat.app 克隆成独立 bundleId 的副本(com.tencent.xinCloneN),
# adhoc 重签 + 正确 entitlement 配方,使其成为一个【完全独立的 WeChat 实例】:
#   - 独立 LaunchServices 注册(换 bundleId → 不被去重)
#   - 独立沙盒数据容器 ~/Library/Containers/com.tencent.xinCloneN
#   - 独立 app-group 容器 ~/Library/Group Containers/5A4RE8SF68.com.tencent.xinCloneN
#   - 与原版 / 其它克隆各自并存,实测稳定 >95s(见 re/clone-verdict.md)
#
# 为什么版本无关:微信的所有"单实例门"都按 bundle 身份判定,换 id 即天然绕过,
#   无需任何字节 patch / 注入 / 偏移定位 → 微信升级后零适配,这是"永不失效"兜底。
#
# ★ 稳定签名配方的关键(踩坑→坐实,见 re/clone-verdict.md):
#   adhoc 无 team,但微信内置 Crashpad 启动时会 bootstrap_check_in 一个
#   名为 "5A4RE8SF68.<bundleId>.crashpad.*" 的 mach 服务。沙盒只允许进程注册
#   以【自己 application-identifier 的 team 段】为前缀的 mach 名。
#   若 application-identifier 不带 team(如 com.tencent.xinClone1)→ Crashpad
#   注册 5A4RE8SF68.* 被 deny(1100)→ 进程 SIGTRAP 自退(exit 133),约 5~15s 内死。
#   ∴ 正解 = application-identifier / application-groups 都【保留 5A4RE8SF68 team 前缀】,
#     只把 bundle 后缀换成新 id:  5A4RE8SF68.com.tencent.xinCloneN
#   team 前缀决定沙盒 mach 注册命名空间(放行 Crashpad);bundle 后缀给克隆独立身份+容器。
#   app-sandbox 必须【保留】(删掉则容器/能力体系起不来);绝不 --deep(逐文件 adhoc,
#   保留嵌套结构),重签顺序 = 嵌套(深→浅)先签、顶层带 entitlements 最后签。
#
# 绝不触碰 /Applications/WeChat.app —— 只读它做克隆源,且会把克隆内的业务体
#   还原成干净版(剥离 X1a0He 注入残留),保证克隆是纯净的。
#
# 用法:
#   install-clone.sh <N> [源app] [目标目录]
# 例:
#   install-clone.sh 1
#     -> com.tencent.xinClone1,放 ~/Library/Application Support/WeChatMulti/Clones/WeChatClone1.app
#   install-clone.sh 2 /Applications/WeChat.app ~/Apps
#     -> com.tencent.xinClone2,放 ~/Apps/WeChatClone2.app
#
# 幂等:重复执行同一 N 会重建该克隆(先删旧 .app)。
# 依赖:ditto / PlistBuddy / codesign / otool。
set -euo pipefail

err() { echo "[clone][ERR] $*" >&2; exit 1; }
log() { echo "[clone] $*"; }

N="${1:-}"
[ -n "$N" ] || err "用法: $0 <N> [源app] [目标目录]"
case "$N" in
  *[!A-Za-z0-9]*) err "N 只能是字母数字(bundleId 安全): $N";;
esac

SRC_APP="${2:-/Applications/WeChat.app}"
DEST_DIR="${3:-$HOME/Library/Application Support/WeChatMulti/Clones}"
DEST_APP="$DEST_DIR/WeChatClone${N}.app"
TEAM="5A4RE8SF68"                       # 腾讯 team,仅用于沙盒 mach 命名前缀(非真签名 team)
NEW_ID="com.tencent.xinClone${N}"
APP_IDENT="${TEAM}.${NEW_ID}"           # application-identifier / app-group 全带 team 前缀

[ -d "$SRC_APP" ] || err "找不到源: $SRC_APP"

log "克隆源 = $SRC_APP"
log "新 bundleId = $NEW_ID   (application-identifier/group = $APP_IDENT)"
log "目标 = $DEST_APP"

mkdir -p "$DEST_DIR"
rm -rf "$DEST_APP"
log "ditto 复制中(~1.3GB)…"
ditto "$SRC_APP" "$DEST_APP"

############################################
# 还原干净业务体 + 剥离 X1a0He 注入残留(保证纯克隆)
############################################
BODY="$DEST_APP/Contents/Resources/wechat.dylib"
if [ -f "$BODY.original" ]; then
  log "发现 wechat.dylib.original → 还原干净业务体"
  mv -f "$BODY.original" "$BODY"
fi
# 移除 X1a0He 插件本体(若源带)
rm -f "$DEST_APP/Contents/Frameworks/X1a0HeWeChatPlugin.dylib" 2>/dev/null || true
# 若业务体仍引用 X1a0He(注入版),提示(还原 .original 后通常已无)
if otool -L "$BODY" 2>/dev/null | grep -qi X1a0He; then
  log "WARN: 业务体仍含 X1a0He LC_LOAD_DYLIB,但无 .original 可还原;克隆可能不纯净。"
  log "      建议改用干净源(挂载官方 DMG)再克隆。"
fi

############################################
# 改顶层 CFBundleIdentifier(独立身份的钥匙)
############################################
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $NEW_ID" "$DEST_APP/Contents/Info.plist"
GOT_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$DEST_APP/Contents/Info.plist")"
[ "$GOT_ID" = "$NEW_ID" ] || err "bundleId 未改成: 实读 $GOT_ID"
log "CFBundleIdentifier = $GOT_ID ✓"

############################################
# 生成正确 entitlements(team 前缀 app-identifier/group + app-sandbox)
############################################
ENT="$(mktemp /tmp/wcclone-ent.XXXXXX.plist)"
cat > "$ENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.application-identifier</key><string>${APP_IDENT}</string>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.application-groups</key><array><string>${APP_IDENT}</string></array>
  <key>com.apple.security.cs.allow-jit</key><true/>
  <key>com.apple.security.device.audio-input</key><true/>
  <key>com.apple.security.device.camera</key><true/>
  <key>com.apple.security.device.usb</key><true/>
  <key>com.apple.security.files.bookmarks.app-scope</key><true/>
  <key>com.apple.security.files.downloads.read-write</key><true/>
  <key>com.apple.security.files.user-selected.read-write</key><true/>
  <key>com.apple.security.network.client</key><true/>
  <key>com.apple.security.network.server</key><true/>
  <key>com.apple.security.personal-information.location</key><true/>
  <key>com.apple.security.personal-information.photos-library</key><true/>
  <key>com.apple.security.print</key><true/>
  <key>com.apple.security.temporary-exception.mach-lookup.global-name</key>
  <array>
    <string>com.tencent.xinWeChat-spks</string>
    <string>com.tencent.xinWeChat-spki</string>
  </array>
</dict></plist>
PLIST

############################################
# 重签:嵌套(深→浅)adhoc 先签,顶层带 entitlements 最后签;绝不 --deep
############################################
log "重签(adhoc,逐文件,无 --deep)…"
# 收集所有嵌套 bundle,按路径长度降序(最深先签)
NESTED_LIST="$(mktemp /tmp/wcclone-nested.XXXXXX)"
find "$DEST_APP" -type d \( -name "*.framework" -o -name "*.xpc" -o -name "*.appex" -o -name "*.app" \) \
  | awk '{ print length, $0 }' | sort -rn | cut -d" " -f2- > "$NESTED_LIST"
while IFS= read -r item; do
  [ -n "$item" ] || continue
  codesign --force --sign - "$item" >/dev/null 2>&1 \
    || log "WARN 嵌套签名失败(忽略): $item"
done < "$NESTED_LIST"
rm -f "$NESTED_LIST"

# 顶层可执行 + bundle,带 entitlements
codesign --force --sign - --entitlements "$ENT" "$DEST_APP" >/dev/null 2>&1 \
  || err "顶层重签失败"
rm -f "$ENT"

# 防 App Translocation(adhoc 重签后移除 quarantine 不影响签名有效性)
xattr -dr com.apple.quarantine "$DEST_APP" 2>/dev/null || true

############################################
# 验证
############################################
codesign --verify --verbose=2 "$DEST_APP" >/dev/null 2>&1 \
  || err "codesign --verify 未通过"
log "签名验证 ✓"
codesign -dvvv "$DEST_APP" 2>&1 | grep -E 'Identifier=|flags|TeamIdentifier' | sed 's/^/[clone]   /'
EMB_ID="$(codesign -d --entitlements :- "$DEST_APP" 2>/dev/null | tr '<' '\n' | grep -A1 application-identifier | grep "$APP_IDENT" || true)"
[ -n "$EMB_ID" ] && log "嵌入 application-identifier = $APP_IDENT ✓"

log "完成。启动该克隆实例:"
log "  open -n \"$DEST_APP\""
log "  # 或: \"$DEST_APP/Contents/MacOS/WeChat\" &"
log "它与原版及其它克隆各自独立常驻、独立容器、独立登录态。"
echo "$DEST_APP"
