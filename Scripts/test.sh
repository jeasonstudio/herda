#!/usr/bin/env bash
# Runs the HerdrKit unit tests and filters xcodebuild noise.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodebuild test \
  -project macos-client.xcodeproj \
  -scheme HerdrPrototype \
  -destination 'platform=macOS' \
  "$@" \
  2>&1 | grep -E "Test Suite|Test Case|error:|\*\* TEST" || true
