#!/bin/sh
# Installs the pinned XcodeGen into ./.tools and generates the Xcode project.
# The generated apps/macos/Fieldwork.xcodeproj is ignored by git.
set -eu
XCODEGEN_VERSION="2.42.0"
root="$(cd "$(dirname "$0")/.." && pwd)"
tools="$root/.tools"
bin="$tools/xcodegen-$XCODEGEN_VERSION/bin/xcodegen"

if [ ! -x "$bin" ]; then
    mkdir -p "$tools"
    echo "Downloading XcodeGen $XCODEGEN_VERSION"
    curl -fsSL "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip" -o "$tools/xcodegen.zip"
    rm -rf "$tools/xcodegen-$XCODEGEN_VERSION"
    mkdir -p "$tools/xcodegen-$XCODEGEN_VERSION"
    unzip -q "$tools/xcodegen.zip" -d "$tools/xcodegen-unpacked"
    mv "$tools/xcodegen-unpacked/xcodegen/"* "$tools/xcodegen-$XCODEGEN_VERSION/"
    rm -rf "$tools/xcodegen-unpacked" "$tools/xcodegen.zip"
fi

"$bin" generate --spec "$root/apps/macos/project.yml"
echo "Open apps/macos/Fieldwork.xcodeproj, or build unsigned with:"
echo "  xcodebuild -project apps/macos/Fieldwork.xcodeproj -scheme Fieldwork -configuration Debug CODE_SIGNING_ALLOWED=NO build"
