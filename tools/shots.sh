#!/usr/bin/env bash
# 실제 창을 화면 밖에 띄워 UI 를 PNG 로 저장한다.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
cp tools/Shots.swift build/main.swift
SOURCES=$(find Sources -name '*.swift' ! -name 'main.swift' | sort)
# shellcheck disable=SC2086
swiftc \
  -target "$(uname -m)-apple-macos14.0" \
  -framework AppKit -framework SwiftUI -framework UserNotifications \
  -framework Carbon -framework ServiceManagement \
  -o build/shots-render \
  $SOURCES build/main.swift
exec build/shots-render build/shots
