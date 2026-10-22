#!/bin/sh
# Installs the pinned XcodeGen into ./.tools, builds the bundled 3du-converter
# from the pinned submodule and generates the Xcode project.
# The generated apps/macos/Fieldwork.xcodeproj is ignored by git.
set -eu
XCODEGEN_VERSION="2.46.0"
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

# The project embeds build/converter/3du-converter, so it must exist before
# generation. Xcode rebuilds it on every build (see project.yml).
if [ ! -f "$root/vendor/3du-converter/Cargo.toml" ]; then
    echo "Initializing the vendor/3du-converter submodule"
    git -C "$root" submodule update --init --recursive
fi
sh "$root/scripts/build-converter.sh" --native

"$bin" generate --spec "$root/apps/macos/project.yml"
echo "Open apps/macos/Fieldwork.xcodeproj, or build unsigned with:"
echo "  xcodebuild -project apps/macos/Fieldwork.xcodeproj -scheme Fieldwork -configuration Debug CODE_SIGNING_ALLOWED=NO build"
