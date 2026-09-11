#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
mkdir -p build
/usr/bin/clang -O2 -mmacosx-version-min=14.0 -c Sources/NativeProbe.c -o build/NativeProbe.o
/usr/bin/swiftc -swift-version 5 -O -target arm64-apple-macosx14.0 Sources/Core.swift Sources/NativeProbe.swift build/NativeProbe.o Sources/BrowserActivity.swift Sources/BrowserReaper.swift Tests/Tests.swift -o build/safety-tests
./build/safety-tests
