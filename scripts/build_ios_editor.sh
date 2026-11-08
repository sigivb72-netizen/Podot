#!/usr/bin/env bash
# Builds the Godot editor static library for iPadOS (requires macOS with Xcode).
# Usage: scripts/build_ios_editor.sh device|simulator [extra scons args...]
#   device:    arm64 iPadOS, Metal (Forward+/Mobile) and OpenGL ES 3 (Compatibility) renderers.
#   simulator: arm64 iOS Simulator. Upstream Godot disables Metal on the simulator, so only the
#              Compatibility renderer (OpenGL ES 3) is available there.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT="${GODOT_DIR:-$ROOT/godot}"
VARIANT="${1:-device}"
shift || true

JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || nproc)}"
ARGS=(platform=ios target=editor arch=arm64 vulkan=no debug_symbols=no "-j$JOBS")
# Smaller binary: the editor is large, the iPad has 64 GB storage and 4 GB RAM.
ARGS+=(optimize=size_extra lto=none)
if [ "$VARIANT" = "simulator" ]; then
	ARGS+=(simulator=yes)
fi
if [ -n "${SCONS_CACHE_DIR:-}" ]; then
	ARGS+=("cache_path=$SCONS_CACHE_DIR" "cache_limit=${SCONS_CACHE_LIMIT:-6}")
fi

cd "$GODOT"
scons "${ARGS[@]}" "$@"
ls -la bin/libgodot.ios.editor*.a
