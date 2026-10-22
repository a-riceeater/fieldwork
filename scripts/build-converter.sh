#!/bin/sh
# Builds the bundled 3du-converter CLI from the pinned vendor/3du-converter
# submodule and stages it in build/converter/ (ignored by git):
#
#   build/converter/3du-converter             the executable Xcode embeds
#   build/converter/3du-converter-build.json  version, source commit, architectures
#
# Usage: scripts/build-converter.sh [--native | --universal] [--fixtures]
#   --native     this machine's architecture only (default; fast local builds)
#   --universal  arm64 + x86_64 merged with lipo (macOS distribution)
#   --fixtures   also write the converter's synthetic test show to
#                build/converter/fixtures/synthetic.3du (for integration tests)
#   --xcode      called from the Xcode build phase: architectures come from
#                $ARCHS, Release and archive builds are always universal, and
#                the staged binary is pre-signed for the app's sandbox
#
# Environment:
#   FW_CONVERTER_SOURCE         build another checkout (converter development only)
#   FW_CONVERTER_ALLOW_UNPINNED let an archive build use a submodule that is not
#                               at the commit Fieldwork pins
#
# Cargo builds incrementally into build/converter/target, so a build with no
# changes takes about a second. Nothing is downloaded except crates pinned by
# the converter's Cargo.lock.
set -eu

root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/build/converter"
src="${FW_CONVERTER_SOURCE:-$root/vendor/3du-converter}"
package="three-du-cli"
bin_name="3du-converter"
# The CLI contract Fieldwork relies on (arguments, --json envelope, exit codes).
# See docs/converter.md before changing it.
interface=1

fail() {
    echo "error: build-converter: $*" >&2
    exit 1
}
warn() { echo "warning: build-converter: $*" >&2; }

mode=native
fixtures=no
xcode=no
for arg in "$@"; do
    case "$arg" in
        --native) mode=native ;;
        --universal) mode=universal ;;
        --fixtures) fixtures=yes ;;
        --xcode) xcode=yes ;;
        *) fail "unknown option $arg (see the header of scripts/build-converter.sh)" ;;
    esac
done

# --- Locate the source -------------------------------------------------------

if [ ! -f "$src/Cargo.toml" ]; then
    fail "converter source not found at $src. Run: git submodule update --init --recursive"
fi

archive=no
if [ "$xcode" = yes ] && [ "${ACTION:-build}" = install ]; then archive=yes; fi

commit="$(git -C "$src" rev-parse HEAD 2>/dev/null || echo unknown)"
dirty=false
if [ -n "$(git -C "$src" status --porcelain --untracked-files=no 2>/dev/null)" ]; then dirty=true; fi
if [ -z "${FW_CONVERTER_SOURCE:-}" ]; then
    # The commit Fieldwork pins is the gitlink in its index (equal to HEAD once committed).
    pinned="$(git -C "$root" ls-files -s vendor/3du-converter 2>/dev/null | awk '{print $2}')"
    if [ -n "$pinned" ] && [ "$pinned" != "$commit" ]; then
        message="vendor/3du-converter is at ${commit}, but Fieldwork pins ${pinned}. Run: git submodule update --init --recursive"
        if [ "$archive" = yes ] && [ -z "${FW_CONVERTER_ALLOW_UNPINNED:-}" ]; then fail "$message"; fi
        warn "$message"
    fi
else
    warn "building the converter from FW_CONVERTER_SOURCE=$src instead of the pinned submodule"
fi
if [ "$dirty" = true ]; then
    if [ "$archive" = yes ] && [ -z "${FW_CONVERTER_ALLOW_UNPINNED:-}" ]; then
        fail "the converter source has uncommitted changes; archives must be built from a pinned commit"
    fi
    warn "the converter source has uncommitted changes"
fi

# --- Toolchain ---------------------------------------------------------------

# Xcode runs build phases without the user's shell profile, so rustup's default
# location is not on PATH there.
if ! command -v cargo >/dev/null 2>&1 && [ -x "${CARGO_HOME:-$HOME/.cargo}/bin/cargo" ]; then
    PATH="${CARGO_HOME:-$HOME/.cargo}/bin:$PATH"
    export PATH
fi
command -v cargo >/dev/null 2>&1 || fail "cargo was not found. Install Rust from https://rustup.rs (1.75 or newer)"
command -v rustc >/dev/null 2>&1 || fail "rustc was not found. Install Rust from https://rustup.rs (1.75 or newer)"

# Fail early, with a clear message, if the converter renamed its CLI target.
if ! cargo metadata --manifest-path "$src/Cargo.toml" --no-deps --format-version 1 --locked 2>/dev/null \
    | tr -d ' \n' | awk '{ gsub(/\{"kind"/, "\n{\"kind\""); print }' | grep '^{"kind":\["bin"\]' | grep -q "\"name\":\"$bin_name\""; then
    fail "the converter workspace has no binary target named $bin_name (package $package)"
fi

host="$(uname -s)"
exe=""
triples=""
case "$host" in
    Darwin)
        if [ "$xcode" = yes ]; then
            if [ "$archive" = yes ] || [ "${CONFIGURATION:-Debug}" = Release ]; then
                mode=universal
            else
                for arch in ${ARCHS:-$(uname -m)}; do
                    case "$arch" in
                        arm64) triples="$triples aarch64-apple-darwin" ;;
                        x86_64) triples="$triples x86_64-apple-darwin" ;;
                        *) fail "unsupported architecture $arch" ;;
                    esac
                done
            fi
        fi
        if [ "$mode" = universal ]; then
            triples="aarch64-apple-darwin x86_64-apple-darwin"
        elif [ -z "$triples" ]; then
            case "$(uname -m)" in
                arm64) triples="aarch64-apple-darwin" ;;
                x86_64) triples="x86_64-apple-darwin" ;;
                *) fail "unsupported architecture $(uname -m)" ;;
            esac
        fi
        # Same minimum macOS as the app (rustc reads this variable).
        if [ -z "${MACOSX_DEPLOYMENT_TARGET:-}" ]; then
            MACOSX_DEPLOYMENT_TARGET="$(sed -n 's/^MACOSX_DEPLOYMENT_TARGET *= *//p' "$root/apps/macos/Config/Base.xcconfig")"
        fi
        export MACOSX_DEPLOYMENT_TARGET
        ;;
    MINGW* | MSYS* | CYGWIN*)
        [ "$mode" = native ] || fail "--universal is only available on macOS"
        exe=".exe"
        ;;
    *)
        [ "$mode" = native ] || fail "--universal is only available on macOS"
        ;;
esac

if [ -n "$triples" ] && command -v rustup >/dev/null 2>&1; then
    installed="$(rustup target list --installed)"
    for triple in $triples; do
        echo "$installed" | grep -qx "$triple" || fail "Rust target $triple is not installed. Run: rustup target add $triple"
    done
elif [ -n "$triples" ]; then
    warn "rustup not found; assuming the Rust standard library for $triples is installed"
fi

# --- Build -------------------------------------------------------------------

export CARGO_TARGET_DIR="$out/target"
# Keep local paths (home folder, checkout location) out of the shipped binary.
RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$src=/3du-converter --remap-path-prefix=$HOME=/home"
export RUSTFLAGS
mkdir -p "$out/work"

# The built slices collect in "$@" so paths with spaces survive.
set --
if [ -z "$triples" ]; then
    echo "Building $bin_name (native, release) from ${commit}"
    cargo build --manifest-path "$src/Cargo.toml" --locked --release -p "$package" --bin "$bin_name" \
        || fail "cargo build failed"
    set -- "$CARGO_TARGET_DIR/release/$bin_name$exe"
else
    for triple in $triples; do
        echo "Building $bin_name for $triple (release, macOS $MACOSX_DEPLOYMENT_TARGET) from ${commit}"
        cargo build --manifest-path "$src/Cargo.toml" --locked --release -p "$package" --bin "$bin_name" --target "$triple" \
            || fail "cargo build failed for $triple"
        set -- "$@" "$CARGO_TARGET_DIR/$triple/release/$bin_name"
    done
fi

merged="$out/work/$bin_name$exe"
if [ "$#" -gt 1 ]; then
    lipo -create "$@" -output "$merged.tmp" || fail "lipo could not merge $*"
else
    cp "$1" "$merged.tmp"
fi
mv -f "$merged.tmp" "$merged"

architectures="$(if [ "$host" = Darwin ]; then lipo -archs "$merged"; else uname -m; fi)"
if [ "$mode" = universal ]; then
    for arch in arm64 x86_64; do
        echo " $architectures " | grep -q " $arch " || fail "universal build is missing $arch (has: $architectures)"
    done
fi

# --- Sign (macOS) and stage --------------------------------------------------

# The app is sandboxed whenever it is signed, so the helper must inherit that
# sandbox. An unsigned app is not sandboxed, and a helper carrying
# com.apple.security.inherit would trap on launch, so unsigned builds get a plain
# ad-hoc signature. Xcode's Code Sign On Copy then re-signs the embedded copy with
# the app's identity and keeps these entitlements; the app itself is signed last.
sign=none
if [ "$host" = Darwin ]; then
    sign=adhoc
    if [ "$xcode" = yes ] && [ "${CODE_SIGNING_ALLOWED:-YES}" = YES ]; then sign=sandboxed; fi
fi

hash_of() {
    if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi
}

staged="$out/$bin_name$exe"
stamp="$(hash_of "$merged") $sign"
# Restage only when the binary or the signing mode changed, so Xcode does not
# re-copy and re-sign the app on every build.
if [ ! -f "$staged" ] || [ "$(cat "$out/work/staged.stamp" 2>/dev/null)" != "$stamp" ]; then
    cp "$merged" "$staged.tmp"
    identifier="${FW_BUNDLE_NAMESPACE:-org.fieldwork}.3du-converter"
    case "$sign" in
        sandboxed)
            codesign --force --sign - --identifier "$identifier" --options runtime \
                --entitlements "$root/apps/macos/Converter/3du-converter.entitlements" "$staged.tmp" \
                || fail "codesign failed" ;;
        adhoc)
            codesign --force --sign - --identifier "$identifier" --options runtime "$staged.tmp" || fail "codesign failed" ;;
    esac
    chmod 755 "$staged.tmp"
    mv -f "$staged.tmp" "$staged"
    echo "$stamp" > "$out/work/staged.stamp"
fi

version="$(sed -n 's/^version *= *"\(.*\)"/\1/p' "$src/Cargo.toml" | head -n 1)"
rustc_version="$(rustc --version)"
arch_json="$(for a in $architectures; do printf '"%s",' "$a"; done | sed 's/,$//')"
target_json="null"
if [ -n "${MACOSX_DEPLOYMENT_TARGET:-}" ]; then target_json="\"$MACOSX_DEPLOYMENT_TARGET\""; fi
manifest="$(cat <<EOF
{
  "name": "$bin_name",
  "version": "$version",
  "interface": $interface,
  "sourceCommit": "$commit",
  "sourceDirty": $dirty,
  "architectures": [$arch_json],
  "macOSDeploymentTarget": $target_json,
  "rustc": "$rustc_version"
}
EOF
)"
if [ "$(cat "$out/$bin_name-build.json" 2>/dev/null)" != "$manifest" ]; then
    printf '%s\n' "$manifest" > "$out/$bin_name-build.json"
fi

# --- Optional synthetic fixture -----------------------------------------------

if [ "$fixtures" = yes ]; then
    mkdir -p "$out/fixtures"
    cargo run --quiet --manifest-path "$src/Cargo.toml" --locked --release -p three-du-core \
        --example make_synthetic -- "$out/fixtures/synthetic.3du" || fail "could not write the synthetic fixture"
fi

echo "Staged $staged ($architectures, $bin_name $version, source ${commit})"
