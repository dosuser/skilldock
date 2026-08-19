#!/usr/bin/env bash
# SkillsOnMenu 빌드 — Xcode 없이 swiftc + 수동 .app 번들로 만든다.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="SkillsOnMenu"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
MACOS_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"
TARGET="${SKILLSONMENU_TARGET:-${SKILLDOCK_TARGET:-$(uname -m)-apple-macos14.0}}"

echo "▸ 정리"
rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RES_DIR"

echo "▸ 컴파일 ($TARGET)"
# main.swift 에 top-level 코드가 있으므로 -parse-as-library 를 쓰지 않는다.
SOURCES=$(find Sources -name '*.swift' | sort)
# shellcheck disable=SC2086
swiftc \
  -target "$TARGET" \
  -O -whole-module-optimization \
  -framework AppKit -framework SwiftUI -framework UserNotifications \
  -framework Carbon -framework ServiceManagement -framework Combine \
  -o "$MACOS_DIR/$APP_NAME" \
  $SOURCES

echo "▸ 번들 구성"
cp Resources/Info.plist "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ 아이콘"
if swift tools/MakeIcon.swift "$BUILD_DIR/icon.png" >/dev/null 2>&1; then
  ICONSET="$BUILD_DIR/AppIcon.iconset"
  rm -rf "$ICONSET"; mkdir -p "$ICONSET"
  for s in 16 32 64 128 256 512; do
    sips -z $s $s "$BUILD_DIR/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    d=$((s * 2))
    sips -z $d $d "$BUILD_DIR/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$RES_DIR/AppIcon.icns"
else
  echo "  (아이콘 생성을 건너뜁니다 — 기본 아이콘으로 동작합니다)"
fi

echo "▸ 서명 (ad-hoc)"
codesign --force --sign - --timestamp=none "$APP" >/dev/null 2>&1 || \
  echo "  (서명 실패 — 알림 권한이 제한될 수 있습니다)"

echo
echo "완료: $APP"
echo "실행:   open $APP"
echo "설치:   cp -R $APP /Applications/"
