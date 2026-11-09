#!/bin/sh
# tools/check-ci.sh -- every job in .github/workflows runs on the fleet's
# self-hosted runners, never on a GitHub-hosted one (DESIGN.md, "The runner").
# It reads the workflow files only, never the network.
set -eu
status=0
for f in .github/workflows/*.yml; do
	grep -n 'runs-on:' "$f" | while IFS= read -r line; do
		case "$line" in
		*self-hosted*) ;;
		*) echo "check-ci REFUSES $f:$line: runs-on must name the fleet's self-hosted runners"; exit 1 ;;
		esac
	done || status=1
done
# A release tag names the port version, independently of the wire format.
version=$(sed -n 's/^S.VERSION = "\([^"]*\)"$/\1/p' src/serialize.moo)
if [ -z "$version" ]; then
	echo "check-ci REFUSES: src/serialize.moo must export VERSION"
	status=1
fi
refs=""
if [ "${GITHUB_REF_TYPE:-}" = tag ]; then
	refs=${GITHUB_REF_NAME:-}
elif [ -n "${GITHUB_REF:-}" ]; then
	case "$GITHUB_REF" in refs/tags/*) refs=${GITHUB_REF#refs/tags/} ;; esac
elif git rev-parse --git-dir >/dev/null 2>&1; then
	refs=$(git tag --points-at HEAD)
fi
for ref in $refs; do
	if [ "$ref" != "v$version" ]; then
		echo "check-ci REFUSES: tag $ref does not match VERSION $version"
		status=1
	fi
done
exit $status
