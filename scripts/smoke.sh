#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
swift build --build-system native --product Everything --product es >/dev/null
BIN_DIR="${BIN_DIR:-$(swift build --build-system native --show-bin-path 2>/dev/null)}"
SUPPORT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/everything-smoke.XXXXXX")"
INSTANCE="smoke-$RANDOM"
export EVERYTHING_APP_SUPPORT="$SUPPORT_DIR"

"$BIN_DIR/Everything" -startup -no-auto-index -save -instance "$INSTANCE" >/dev/null 2>&1 &
APP_PID=$!
SOCKET="${TMPDIR:-/tmp}/everything-$INSTANCE.sock"
if (( ${#SOCKET} >= 100 )); then
    SOCKET="/tmp/everything-$UID-$INSTANCE.sock"
fi
for _ in {1..100}; do
    [[ -S "$SOCKET" ]] && break
    sleep 0.05
done
[[ -S "$SOCKET" ]]

"$BIN_DIR/es" -json -instance "$INSTANCE" '' >/dev/null
"$BIN_DIR/Everything" -exit -instance "$INSTANCE"
for _ in {1..100}; do
    ! kill -0 "$APP_PID" 2>/dev/null && break
    sleep 0.05
done
if kill -0 "$APP_PID" 2>/dev/null; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
    print -u2 "Everything did not terminate after -exit"
    exit 1
fi
wait "$APP_PID" 2>/dev/null || true
print "Everything launch/IPC/exit smoke passed"
