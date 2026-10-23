#!/bin/zsh
# Runs the package tests. Command Line Tools ship Swift Testing but not XCTest, and the
# default swiftbuild system cannot locate the TestingMacros plugin, so pass paths explicitly.
set -euo pipefail
cd "$(dirname "$0")/.."
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
PL=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
# The package contains loopback servers and shared C-ABI state. Running every
# Swift Testing suite concurrently can starve those services and turn a quick
# request into the framework's 60-second timeout. Keep the reliable default
# serial; callers can pass --parallel explicitly when they want to stress it.
exec swift test --build-system native --no-parallel "$@" -Xswiftc -F$FW -Xswiftc -plugin-path -Xswiftc $PL -Xlinker -rpath -Xlinker $FW 2>&1 | grep -v "ld: warning\|has been deprecated"
