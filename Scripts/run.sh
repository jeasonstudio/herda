#!/usr/bin/env bash
# Builds and launches the app.
#
#   run.sh            build, then launch
#   run.sh --watch    the same, then rebuild and relaunch whenever Sources change
#   run.sh --reset    discard the embedded server's session first, then build and launch
set -euo pipefail
cd "$(dirname "$0")/.."

RUNTIME="$HOME/Library/Application Support/app.herda/runtime"
APP="build/Build/Products/Debug/Herda.app"
EXECUTABLE="$APP/Contents/MacOS/Herda"
LOG="build/last-build.log"

build() {
  # The .xcodeproj is generated, so a new or deleted file has to be picked up
  # before it can compile.
  xcodegen generate >/dev/null
  mkdir -p build
  if xcodebuild -project herda.xcodeproj -scheme Herda \
      -configuration Debug -destination 'platform=macOS' -derivedDataPath build \
      build >"$LOG" 2>&1; then
    return 0
  fi
  grep -E "error:" "$LOG" | head -20 || tail -20 "$LOG"
  return 1
}

launch() {
  # Killed rather than quit. Quitting runs the app's shutdown path, which stops
  # the embedded server and takes every PTY with it; killing leaves the server
  # running, and the relaunched app reconnects to the same one, so a rebuild
  # does not disturb the agents. Verified by the server keeping its pid across a
  # restart.
  #
  # The trade-off: SIGKILL never sends Detach, so the server only learns the old
  # client is gone when it notices the closed socket. Across many relaunches it
  # accumulates render targets, and each one carries the terminal size that
  # instance declared. The server's terminal_area is then overwritten by whichever
  # target rendered last, which recomputes the layout and emits layout_updated
  # every time — measured at ~10 events/second with a stale target, versus one
  # event on a fresh server.
  #
  # Harmless for the agents, but it looks exactly like a layout bug: pane rects
  # drift, the reported area flips between the sizes different builds declared,
  # and the pane count changes. If layout churn appears while iterating, relaunch
  # with --reset before believing it.
  pkill -9 -f "$EXECUTABLE" 2>/dev/null || true

  # Executed directly rather than through `open`, which proved unreliable across
  # rapid kill-and-relaunch cycles and started failing with
  # `_LSOpenURLsWithCompletionHandler() failed with error -600`. Running the
  # binary avoids LaunchServices entirely.
  #
  # The app strips inherited HERDR_* variables itself, but nothing else. Claude
  # Code's session markers would otherwise reach the agents running inside the
  # panes, which respond by turning off transcript saving.
  #
  # Detached in a subshell so the app outlives ctrl-c on the watch loop.
  ( env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_SESSION_ID \
      "$EXECUTABLE" >"build/last-run.log" 2>&1 & )
}

reset_session() {
  # Only the process holding this exact socket, so a herdr session of the user's
  # own is never a candidate.
  if [ -S "$RUNTIME/herdr.sock" ]; then
    local server
    server=$(lsof -t "$RUNTIME/herdr.sock" 2>/dev/null || true)
    [ -n "$server" ] && kill "$server" 2>/dev/null || true
  fi
  pkill -9 -f "$EXECUTABLE" 2>/dev/null || true
  rm -rf "$RUNTIME"
  echo "discarded the embedded server's session"
}

# Changes that require a rebuild. Tests are excluded: they do not affect the app.
fingerprint() {
  find Sources project.yml -type f -exec stat -f '%m %N' {} + | sort | md5 -q
}

watch() {
  local previous
  previous=$(fingerprint)
  echo "watching Sources — ctrl-c to stop"
  while sleep 1; do
    local current
    current=$(fingerprint)
    [ "$current" = "$previous" ] && continue
    previous=$current
    echo "--- change detected, rebuilding ---"
    if build; then
      launch
      echo "--- relaunched ---"
    else
      echo "--- build failed, app left running ---"
    fi
  done
}

case "${1:-}" in
  --watch) build && launch && watch ;;
  --reset) reset_session; build && launch ;;
  "") build && launch ;;
  *) echo "usage: $0 [--watch|--reset]" >&2; exit 2 ;;
esac
