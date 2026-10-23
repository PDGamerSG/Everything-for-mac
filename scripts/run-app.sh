#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="${EVERYTHING_APP:-$ROOT_DIR/dist/Everything.app}"
exec "$APP_DIR/Contents/MacOS/Everything" "$@"
