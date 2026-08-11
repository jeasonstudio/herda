#!/usr/bin/env bash
# Runs the HerdrKit unit tests and filters xcodebuild noise.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# grep exits 1 when nothing matches, so the pipeline's status cannot stand in
# for the build's. The `|| true` that used to cover that swallowed xcodebuild's
# status as well, so a failing suite still exited 0. Read xcodebuild's own
# status out of PIPESTATUS instead — nothing may run between the pipeline and
# the assignment, or bash resets it.
xcodebuild test \
  -project macos-client.xcodeproj \
  -scheme HerdrPrototype \
  -destination 'platform=macOS' \
  "$@" \
  2>&1 | grep -E "Test Suite|Test Case|error:|\*\* TEST"
status=${PIPESTATUS[0]}

exit "$status"
