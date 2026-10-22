#!/bin/sh
# Moves the pinned 3du-converter to another upstream revision, on purpose.
# Regular builds never do this; they build whatever commit Fieldwork pins.
#
#   scripts/update-converter.sh            fetch, then list upstream commits and
#                                          tags that are not pinned yet
#   scripts/update-converter.sh <rev>      check out <rev> (tag, commit or
#                                          origin/<branch>), build it, run the
#                                          converter and integration tests
#
# Nothing is committed. Review the result, then commit the new pin yourself:
#   git add vendor/3du-converter && git commit -m "build(converter): pin 3du-converter <version>"
set -eu
root="$(cd "$(dirname "$0")/.." && pwd)"
sub="$root/vendor/3du-converter"

fail() {
    echo "error: update-converter: $*" >&2
    exit 1
}

[ -f "$sub/Cargo.toml" ] || git -C "$root" submodule update --init --recursive
[ -z "$(git -C "$sub" status --porcelain)" ] || fail "vendor/3du-converter has local changes; commit them in the converter repository first"

pinned="$(git -C "$root" ls-files -s vendor/3du-converter | awk '{print $2}')"
echo "Pinned: $(git -C "$sub" log -1 --format='%h %s (%cs)' "$pinned")"
echo "Fetching $(git -C "$sub" remote get-url origin)"
git -C "$sub" fetch --tags --prune origin

if [ "$#" -eq 0 ]; then
    head="$(git -C "$sub" rev-parse 'origin/HEAD' 2>/dev/null || git -C "$sub" rev-parse origin/main)"
    echo
    echo "Upstream commits not pinned yet:"
    git -C "$sub" log --oneline "$pinned..$head" | sed 's/^/  /'
    echo "Tags:"
    git -C "$sub" tag --sort=-creatordate | head -n 10 | sed 's/^/  /'
    echo
    echo "Pick one with: scripts/update-converter.sh <tag-or-commit>"
    exit 0
fi

target="$(git -C "$sub" rev-parse --verify "$1^{commit}")" || fail "$1 is not a revision in the converter repository"
echo
echo "Changes from $(git -C "$sub" rev-parse --short "$pinned") to $(git -C "$sub" rev-parse --short "$target"):"
git -C "$sub" log --oneline "$pinned..$target" | sed 's/^/  /'
git -C "$sub" checkout --quiet --detach "$target"
git -C "$sub" submodule update --init --recursive

echo
echo "== Converter tests"
CARGO_TARGET_DIR="$root/build/converter/target" cargo test --manifest-path "$sub/Cargo.toml" --workspace --locked
echo "== Build"
if [ "$(uname -s)" = Darwin ]; then
    sh "$root/scripts/build-converter.sh" --universal --fixtures
else
    sh "$root/scripts/build-converter.sh" --native --fixtures
fi
echo "== Integration tests"
FIELDWORK_REQUIRE_CONVERTER=1 swift test --package-path "$root/packages/DrillDocument" --filter DrillConvertTests

echo
echo "vendor/3du-converter now points at $(git -C "$sub" log -1 --format='%h %s' HEAD) (not committed)."
echo "On macOS, also run the app tests (see docs/converter.md). To keep this version:"
echo "  git add vendor/3du-converter && git commit -m \"build(converter): pin 3du-converter <version>\""
echo "To go back: git submodule update --init --recursive"
