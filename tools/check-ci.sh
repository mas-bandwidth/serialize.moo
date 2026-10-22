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
exit $status
