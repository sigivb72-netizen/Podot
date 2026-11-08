#!/usr/bin/env bash
# Fetches the upstream Godot source at the pinned revision and applies the Podot patch series.
# Usage: scripts/fetch_godot.sh [destination]   (default: ./godot)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/UPSTREAM"
DEST="${1:-$ROOT/godot}"

if [ ! -d "$DEST/.git" ]; then
	git clone --depth 1 --branch "$GODOT_TAG" "$GODOT_REPO" "$DEST"
fi
cd "$DEST"
HEAD_COMMIT="$(git rev-parse HEAD)"
if [ "$HEAD_COMMIT" != "$GODOT_COMMIT" ] && ! git merge-base --is-ancestor "$GODOT_COMMIT" HEAD 2>/dev/null; then
	echo "error: $DEST is at $HEAD_COMMIT, expected $GODOT_TAG ($GODOT_COMMIT)" >&2
	exit 1
fi
if git log --format=%s | grep -q "^podot:"; then
	echo "Patches already applied in $DEST"
	exit 0
fi
git -c user.name=podot -c user.email=podot@localhost am --3way "$ROOT"/patches/*.patch
echo "Godot $GODOT_TAG with the Podot patches is ready in $DEST"
