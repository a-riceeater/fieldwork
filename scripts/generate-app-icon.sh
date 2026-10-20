#!/bin/sh
# Regenerate the macOS icon from its editable vector source using ImageMagick 7.
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
assets="$root/apps/macos/Fieldwork/Assets.xcassets/AppIcon.appiconset"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT HUP INT TERM

magick -background none -density 384 "$root/design/icon/fieldwork.svg" "$work/master.png"
for size in 16 32 64 128 256 512 1024; do
    magick "$work/master.png" -resize "${size}x${size}" -strip "PNG32:$assets/icon-${size}.png"
done
