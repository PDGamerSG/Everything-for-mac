#!/bin/zsh
# Release-mode benchmark of the search engine (1M synthetic names).
set -e
cd "$(dirname "$0")/.."
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
PL=/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing
EVT_BENCH_RELEASE=1 swift test -c release --build-system native --filter benchmarkMillionNames -Xswiftc -F$FW -Xswiftc -plugin-path -Xswiftc $PL -Xlinker -rpath -Xlinker $FW 2>&1 | grep -E "BENCH|✘|✔ Test run|error:"
