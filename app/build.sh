#!/bin/bash
# 编译并打包成 WeChatMulti.app（无需 Xcode，仅用 swift build + 手动组 bundle）
set -e
cd "$(dirname "$0")"

echo "==> swift build -c release"
swift build -c release

APP="WeChatMulti.app"
BIN=".build/release/WeChatMulti"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/WeChatMulti"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
[ -f Resources/menubar.png ] && cp Resources/menubar.png "$APP/Contents/Resources/menubar.png"
[ -f Resources/X1a0HeWeChatPlugin.pkg ] && cp Resources/X1a0HeWeChatPlugin.pkg "$APP/Contents/Resources/X1a0HeWeChatPlugin.pkg"

# 本地化资源（简中 / 英文），按系统语言自动切换
for lproj in zh-Hans.lproj en.lproj; do
  [ -d "Resources/$lproj" ] && cp -R "Resources/$lproj" "$APP/Contents/Resources/$lproj"
done

# 自研多开引擎资产（安装脚本 + dylib + 注入/定位脚本），供 GUI 调用 installSelfEngine()
ENGINE_SRC="../engine"
if [ -d "$ENGINE_SRC" ]; then
  mkdir -p "$APP/Contents/Resources/engine"
  # 注入引擎资产 + bundleID 终极兜底克隆脚本(install-clone / cleanup-clone)
  for f in install-self-engine.sh WeChatMultiEngine.dylib insert_dylib.py locate_gate1.py install-clone.sh cleanup-clone.sh; do
    [ -f "$ENGINE_SRC/$f" ] && cp "$ENGINE_SRC/$f" "$APP/Contents/Resources/engine/$f"
  done
  for s in install-self-engine.sh install-clone.sh cleanup-clone.sh; do
    chmod +x "$APP/Contents/Resources/engine/$s" 2>/dev/null || true
  done
fi

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>WeChatMulti</string>
  <key>CFBundleDisplayName</key><string>微信多开工具</string>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>zh-Hans</string>
    <string>en</string>
  </array>
  <key>CFBundleIdentifier</key><string>com.will.wechatmulti</string>
  <key>CFBundleVersion</key><string>32</string>
  <key>CFBundleShortVersionString</key><string>0.9.1</string>
  <key>CFBundleExecutable</key><string>WeChatMulti</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>仅供学习研究 · github.com/Wuvomi/WeChatMulti</string>
</dict>
</plist>
EOF

codesign -f -s - "$APP" 2>/dev/null || true
echo "==> 完成：$(pwd)/$APP"
