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

cat > "$APP/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>WeChatMulti</string>
  <key>CFBundleDisplayName</key><string>微信多开工具</string>
  <key>CFBundleIdentifier</key><string>com.will.wechatmulti</string>
  <key>CFBundleVersion</key><string>0.1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleExecutable</key><string>WeChatMulti</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

codesign -f -s - "$APP" 2>/dev/null || true
echo "==> 完成：$(pwd)/$APP"
