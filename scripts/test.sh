#!/bin/zsh
# Runs the package tests. Command Line Tools ship Swift Testing but not XCTest, and the
# default swiftbuild system cannot locate the TestingMacros plugin, so pass paths explicitly.
set -e
cd "$(dirname "$0")/.."
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
PL=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
exec swift test --build-system native "$@" -Xswiftc -F$FW -Xswiftc -plugin-path -Xswiftc $PL -Xlinker -rpath -Xlinker $FW 2>&1 | grep -v "ld: warning\|has been deprecated"
