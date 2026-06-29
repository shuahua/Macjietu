#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-debug}"
APP_NAME="截图Free"
BINARY_NAME="截图Free"
APP_DIR="/Applications/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
SIGN_IDENTITY="JietuFree Local Development"

cd "$ROOT_DIR"
swift build -c "$CONFIGURATION" --product "$BINARY_NAME"

pkill "$APP_NAME" >/dev/null 2>&1 || true
pkill "$BINARY_NAME" >/dev/null 2>&1 || true
rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

if [[ "$CONFIGURATION" == "release" ]]; then
  BINARY_PATH="$ROOT_DIR/.build/release/$BINARY_NAME"
else
  BINARY_PATH="$ROOT_DIR/.build/debug/$BINARY_NAME"
fi

cp "$BINARY_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"
cp "$ROOT_DIR/Sources/截图Free/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh_CN</string>
  <key>CFBundleExecutable</key>
  <string>截图Free</string>
  <key>CFBundleIdentifier</key>
  <string>local.jietu-free</string>
  <key>CFBundleDisplayName</key>
  <string>截图Free</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>截图Free</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>录屏时可选择录制麦克风声音。</string>
</dict>
</plist>
PLIST

ENTITLEMENTS_PATH="$ROOT_DIR/Xcode/截图Free.entitlements"

printf '%s\n' "已生成 $APP_DIR"
if command -v codesign >/dev/null 2>&1; then
  if security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    codesign --force --deep --sign "$SIGN_IDENTITY" --options runtime --entitlements "$ENTITLEMENTS_PATH" "$APP_DIR" >/dev/null
    printf '%s\n' "已使用稳定本地证书签名：$SIGN_IDENTITY"
  else
    codesign --force --deep --sign - --options runtime --entitlements "$ENTITLEMENTS_PATH" "$APP_DIR" >/dev/null
    printf '%s\n' "未找到稳定本地证书，已执行 ad-hoc app bundle 签名"
  fi
fi
printf '%s\n' "运行：open \"$APP_DIR\""
