#!/usr/bin/env bash
# Regenerates patches/ from a Godot checkout whose commits on top of the upstream tag are the port.
# Usage: scripts/export_patches.sh [godot checkout]   (default: ./godot)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT/UPSTREAM"
SRC="${1:-$ROOT/godot}"
rm -f "$ROOT"/patches/*.patch
mkdir -p "$ROOT/patches"
git -C "$SRC" format-patch --zero-commit --no-signature -o "$ROOT/patches" "$GODOT_COMMIT..HEAD"
ls "$ROOT/patches"
