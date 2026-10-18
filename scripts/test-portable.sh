#!/bin/sh
# Runs every portable Swift package test suite. Works on macOS, Linux and
# Windows (Git Bash) with a Swift 6 toolchain on PATH.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
for package in DrillTiming DrillCore DrillDocument DrillBridge; do
    echo "== swift test: $package"
    swift test --package-path "$root/packages/$package"
done
echo "All portable test suites passed."
