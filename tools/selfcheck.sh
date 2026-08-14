#!/usr/bin/env bash
# GUI 없이 순수 로직을 점검한다. 앱 소스에서 main.swift 만 제외하고 SelfCheck.swift 를 붙여 빌드한다.
set -euo pipefail
cd "$(dirname "$0")/.."

mkdir -p build
# top-level 코드는 main.swift 라는 이름에서만 허용되므로 복사해서 컴파일한다.
cp tools/SelfCheck.swift build/main.swift
SOURCES=$(find Sources -name '*.swift' ! -name 'main.swift' | sort)
# shellcheck disable=SC2086
swiftc \
  -target "$(uname -m)-apple-macos14.0" \
  -framework AppKit -framework SwiftUI -framework UserNotifications \
  -framework Carbon -framework ServiceManagement \
  -o build/selfcheck \
  $SOURCES build/main.swift

exec build/selfcheck
