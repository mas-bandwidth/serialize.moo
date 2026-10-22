#!/bin/sh
# tools/revendor.sh <tag> -- re-vendor STANDARD.md, IMPLEMENTING.md,
# conformance/ and conformance-controls/ VERBATIM from mas-bandwidth/serialize
# at <tag> (DESIGN.md, "The vendored standard"), then show what moved. The pin
# in DESIGN.md and SERIALIZE_TAG in .github/workflows/ci.yml are edited by hand
# to match; CI's corpus job diffs every vendored file against the tag.
set -eu
tag=${1:?usage: tools/revendor.sh <tag>}
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/serialize-revendor.XXXXXX")
trap 'rm -rf "$work"' EXIT
git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" https://github.com/mas-bandwidth/serialize.git "$work/serialize"
rm -rf "$root/conformance" "$root/conformance-controls"
cp -R "$work/serialize/conformance" "$root/conformance"
cp -R "$work/serialize/conformance-controls" "$root/conformance-controls"
cp "$work/serialize/STANDARD.md" "$work/serialize/IMPLEMENTING.md" "$root/"
echo "revendor: $tag is $(git -C "$work/serialize" rev-parse HEAD)"
git -C "$root" status --short -- STANDARD.md IMPLEMENTING.md conformance conformance-controls
