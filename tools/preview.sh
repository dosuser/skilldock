#!/usr/bin/env bash
# UI 를 PNG 로 렌더한다 (화면 캡처 권한 없이 시각 검증).
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
cp tools/RenderPreview.swift build/main.swift
SOURCES=$(find Sources -name '*.swift' ! -name 'main.swift' | sort)
# shellcheck disable=SC2086
swiftc \
  -target "$(uname -m)-apple-macos14.0" \
  -framework AppKit -framework SwiftUI -framework UserNotifications \
  -framework Carbon -framework ServiceManagement \
  -o build/preview-render \
  $SOURCES build/main.swift
exec build/preview-render build/preview
