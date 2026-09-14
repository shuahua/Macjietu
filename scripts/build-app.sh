#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-debug}"
NOTES_FILE="${2:-}"
APP_NAME="截图Free"
BINARY_NAME="截图Free"
APP_DIR="$ROOT_DIR/.build/$APP_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
SIGN_IDENTITY="JietuFree Local Development"
STATE_FILE="$ROOT_DIR/version-state"
DIST_DIR="$ROOT_DIR/dist"
LOCK_DIR="$ROOT_DIR/.build/build.lock"

if [[ -z "$NOTES_FILE" || ! -f "$NOTES_FILE" || ! -s "$NOTES_FILE" || -z "$(tr -d '[:space:]' < "$NOTES_FILE")" ]]; then
  printf '%s\n' "错误：必须提供存在的第二个参数（本次版本修改说明文件）" >&2
  exit 2
fi
mkdir -p "$ROOT_DIR/.build"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  printf '%s\n' "错误：已有打包任务运行中（锁：$LOCK_DIR）" >&2
  exit 3
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

if [[ -f "$STATE_FILE" ]]; then
  . "$STATE_FILE"
else
  VERSION="1.0.0"; BUILD="1"
fi
OLD_VERSION="$VERSION"; OLD_BUILD="$BUILD"
IFS=. read -r MAJOR MINOR PATCH <<EOF
$VERSION
EOF
NEXT_PATCH=$((PATCH + 1)); NEXT_BUILD=$((BUILD + 1)); NEXT_VERSION="$MAJOR.$MINOR.$NEXT_PATCH"
VERSION_TAG="v$NEXT_VERSION-build$NEXT_BUILD"
PACKAGE="$DIST_DIR/$APP_NAME-$VERSION_TAG.zip"
RELEASE_NOTES="$DIST_DIR/$APP_NAME-$VERSION_TAG.md"
if [[ -e "$PACKAGE" || -e "$RELEASE_NOTES" ]]; then
  printf '%s\n' "错误：版本文件已存在，不覆盖：$VERSION_TAG" >&2
  exit 4
fi

cd "$ROOT_DIR"
swift build -c "$CONFIGURATION" --product "$BINARY_NAME"

BUILD_APP_DIR="$APP_DIR"
rm -rf "$BUILD_APP_DIR"; mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$DIST_DIR"

if [[ "$CONFIGURATION" == "release" ]]; then
  BINARY_PATH="$ROOT_DIR/.build/release/$BINARY_NAME"
else
  BINARY_PATH="$ROOT_DIR/.build/debug/$BINARY_NAME"
fi

cp "$BINARY_PATH" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"
cp "$ROOT_DIR/Sources/截图Free/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
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
   <string>$NEXT_VERSION</string>
  <key>CFBundleVersion</key>
   <string>$NEXT_BUILD</string>
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

printf '%s\n' "已生成 $BUILD_APP_DIR"
if command -v codesign >/dev/null 2>&1; then
  if security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    codesign --force --deep --sign "$SIGN_IDENTITY" --options runtime --entitlements "$ENTITLEMENTS_PATH" "$BUILD_APP_DIR" >/dev/null
    printf '%s\n' "已使用稳定本地证书签名：$SIGN_IDENTITY"
  else
    codesign --force --deep --sign - --options runtime --entitlements "$ENTITLEMENTS_PATH" "$BUILD_APP_DIR" >/dev/null
    printf '%s\n' "未找到稳定本地证书，已执行 ad-hoc app bundle 签名"
  fi
fi
plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null
if command -v codesign >/dev/null 2>&1; then codesign --verify --deep --strict "$BUILD_APP_DIR" >/dev/null 2>&1; fi
ditto -c -k --sequesterRsrc --keepParent "$BUILD_APP_DIR" "$PACKAGE"
{
  printf '# %s %s\n\n' "$APP_NAME" "$VERSION_TAG"
  printf '基于：%s build%s\n\n' "$OLD_VERSION" "$OLD_BUILD"
  cat "$NOTES_FILE"
} > "$RELEASE_NOTES"
printf '%s\n' "## $VERSION_TAG" "" "$(cat "$NOTES_FILE")" "" "$(date '+%Y-%m-%d')" >> "$ROOT_DIR/CHANGELOG.md"
printf 'VERSION=%s\nBUILD=%s\n' "$NEXT_VERSION" "$NEXT_BUILD" > "$STATE_FILE"
printf '%s\n' "已生成：$PACKAGE" "说明：$RELEASE_NOTES"
