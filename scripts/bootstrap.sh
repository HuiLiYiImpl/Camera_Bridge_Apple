#!/usr/bin/env bash
set -euo pipefail

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "未找到 XcodeGen。请先执行: brew install xcodegen" >&2
  exit 1
fi

cd "$(dirname "$0")/.."
xcodegen generate
open CameraBridge.xcodeproj
