#!/bin/sh
# tools/revendor.sh <ref> -- re-vendor STANDARD.md, IMPLEMENTING.md,
# conformance/ and conformance-controls/ VERBATIM from mas-bandwidth/serialize
# at <ref>, a tag or a full commit (DESIGN.md, "The vendored standard"), then
# show what moved. The pin in DESIGN.md and SERIALIZE_REF in
# .github/workflows/ci.yml are edited by hand to match; CI's corpus job diffs
# every vendored file against the pin.
set -eu
ref=${1:?usage: tools/revendor.sh <tag or full commit>}
root=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d "${TMPDIR:-/tmp}/serialize-revendor.XXXXXX")
trap 'rm -rf "$work"' EXIT
git init -q "$work/serialize"
git -C "$work/serialize" fetch -q --depth 1 https://github.com/mas-bandwidth/serialize.git "$ref"
git -C "$work/serialize" -c advice.detachedHead=false checkout -q FETCH_HEAD
rm -rf "$root/conformance" "$root/conformance-controls"
cp -R "$work/serialize/conformance" "$root/conformance"
cp -R "$work/serialize/conformance-controls" "$root/conformance-controls"
cp "$work/serialize/STANDARD.md" "$work/serialize/IMPLEMENTING.md" "$root/"
echo "revendor: $ref is $(git -C "$work/serialize" rev-parse HEAD)"
git -C "$root" status --short -- STANDARD.md IMPLEMENTING.md conformance conformance-controls
