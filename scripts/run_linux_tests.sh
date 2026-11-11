#!/usr/bin/env bash
# Tests the platform-independent parts of the port with a Linux editor build:
#  - Godot's unit tests (including the ones added by the port: in-process instances, StringName
#    preservation across Main teardowns, project device limits, logger truncation).
#  - The end-to-end editor scenario with in-process instances (GODOT_IN_PROCESS_INSTANCES=1), which
#    exercises exactly the editor -> game -> editor flow used on iPadOS, headless.
# Usage: scripts/run_linux_tests.sh [path to godot editor binary] [results dir]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT_BIN="${1:-$ROOT/godot/bin/godot.linuxbsd.editor.x86_64}"
RESULTS="${2:-$ROOT/build/linux-results}"
mkdir -p "$RESULTS"
SUMMARY="$RESULTS/summary.txt"
: > "$SUMMARY"
result() { echo "$1 $2 ${3:-}" | tee -a "$SUMMARY"; }

# --- Unit tests ---
if "$GODOT_BIN" --headless --test --test-case="*[Podot]*" > "$RESULTS/unit_podot.log" 2>&1; then
	result PASS unit_tests_podot "$(grep -E 'test cases:' "$RESULTS/unit_podot.log" | tail -1)"
else
	result FAIL unit_tests_podot "$(tail -5 "$RESULTS/unit_podot.log" | tr '\n' ' ')"
fi

# --- End-to-end scenario in-process (headless) ---
WORK="$(mktemp -d)"
cp -R "$ROOT/tests/projects/e2e" "$WORK/e2e"
# Initial import of the test project (as when a project is opened for the first time).
timeout 600 "$GODOT_BIN" --headless --editor --path "$WORK/e2e" --import > "$RESULTS/e2e_import.log" 2>&1
mkdir -p "$WORK/e2e/.test_results" && touch "$WORK/e2e/.test_results/PODOT_E2E"
export GODOT_IN_PROCESS_INSTANCES=1
timeout 900 "$GODOT_BIN" --headless --editor --path "$WORK/e2e" > "$RESULTS/e2e.log" 2>&1
CODE=$?
unset GODOT_IN_PROCESS_INSTANCES
cp -R "$WORK/e2e/.test_results" "$RESULTS/e2e_results" 2>/dev/null
J="$WORK/e2e/.test_results/editor.json"
if [ -f "$J" ] && python3 -c "import json,sys; sys.exit(0 if json.load(open('$J'))['done'] else 1)"; then
	python3 - "$J" <<'PY' | tee -a "$SUMMARY"
import json, sys
d = json.load(open(sys.argv[1]))
for name, c in sorted(d["checks"].items()):
    print(("PASS" if c["ok"] else "FAIL"), "e2e:" + name, c["detail"][:160].replace("\n", " "))
PY
	result PASS e2e_in_process_exit "exit code $CODE"
else
	result FAIL e2e_in_process "editor exit code $CODE, see e2e.log"
fi
if grep -q "next to the editor" "$RESULTS/e2e.log" && grep -q "\[game\] done, quitting" "$RESULTS/e2e.log" && grep -q "\[e2e\] editor is back after running the game" "$RESULTS/e2e.log"; then
	result PASS in_process_game_window "game ran in the editor process next to the open editor"
else
	result FAIL in_process_game_window "see e2e.log"
fi
if grep -q "\[e2e\] editor is back after a restart" "$RESULTS/e2e.log"; then
	result PASS in_process_editor_restart "Reload Current Project relaunched the editor in-process"
else
	result FAIL in_process_editor_restart "see e2e.log"
fi
if grep -q -- "--- Game stopped after" "$RESULTS/e2e.log"; then
	result PASS game_output_shown_in_editor_log
else
	result FAIL game_output_shown_in_editor_log
fi
rm -rf "$WORK"

# --- Floppy Bird played in the game window next to the editor ---
# Usage: run_flappy <label> [godot args]; FLAPPY_PREFIX: command prefix array (e.g. xvfb-run).
FLAPPY_PREFIX=(env)
run_flappy() {
	local label="$1"; shift
	local work; work="$(mktemp -d)"
	cp -R "$ROOT/tests/projects/flappy" "$work/flappy"
	timeout 600 "${FLAPPY_PREFIX[@]}" "$GODOT_BIN" "$@" --editor --path "$work/flappy" --import > "$RESULTS/${label}_import.log" 2>&1
	mkdir -p "$work/flappy/.test_results" && touch "$work/flappy/.test_results/PODOT_FLAPPY"
	GODOT_IN_PROCESS_INSTANCES=1 timeout 900 "${FLAPPY_PREFIX[@]}" "$GODOT_BIN" "$@" --editor --path "$work/flappy" > "$RESULTS/${label}.log" 2>&1
	local code=$?
	cp -R "$work/flappy/.test_results" "$RESULTS/${label}_results" 2>/dev/null
	local j="$work/flappy/.test_results/flappy.json"
	if [ -f "$j" ] && python3 -c "import json,sys; sys.exit(0 if json.load(open('$j'))['done'] else 1)"; then
		python3 - "$j" "$label" <<'PY' | tee -a "$SUMMARY"
import json, sys
d = json.load(open(sys.argv[1]))
for name, c in sorted(d["checks"].items()):
    print(("PASS" if c["ok"] else "FAIL"), sys.argv[2] + ":" + name, c["detail"][:160].replace("\n", " "))
PY
		result PASS "${label}_exit" "exit code $code"
	else
		result FAIL "$label" "exit code $code, see ${label}.log"
	fi
	rm -rf "$work"
}
run_flappy flappy --headless

# --- Same scenario with a real renderer (OpenGL ES 3 / Compatibility on Mesa) and display server ---
if command -v xvfb-run >/dev/null; then
	WORK="$(mktemp -d)"
	cp -R "$ROOT/tests/projects/e2e" "$WORK/e2e"
	XVFB=(xvfb-run -a -s "-screen 0 1640x1180x24")
	timeout 900 "${XVFB[@]}" "$GODOT_BIN" --editor --rendering-driver opengl3 --path "$WORK/e2e" --import > "$RESULTS/e2e_gl_import.log" 2>&1
	mkdir -p "$WORK/e2e/.test_results" && touch "$WORK/e2e/.test_results/PODOT_E2E"
	GODOT_IN_PROCESS_INSTANCES=1 timeout 1800 "${XVFB[@]}" "$GODOT_BIN" --editor --rendering-driver opengl3 --path "$WORK/e2e" > "$RESULTS/e2e_gl.log" 2>&1
	CODE=$?
	cp -R "$WORK/e2e/.test_results" "$RESULTS/e2e_gl_results" 2>/dev/null
	J="$WORK/e2e/.test_results/editor.json"
	if [ -f "$J" ] && python3 -c "import json,sys; sys.exit(0 if json.load(open('$J'))['done'] else 1)"; then
		python3 - "$J" <<'PY' | tee -a "$SUMMARY"
import json, sys
d = json.load(open(sys.argv[1]))
for name, c in sorted(d["checks"].items()):
    print(("PASS" if c["ok"] else "FAIL"), "e2e_gl:" + name, c["detail"][:160].replace("\n", " "))
PY
		result PASS e2e_gl_in_process_exit "exit code $CODE ($(python3 -c "import json; d=json.load(open('$J')); print(d['renderer'], d['display'])"))"
	else
		result FAIL e2e_gl_in_process "exit code $CODE, see e2e_gl.log"
	fi
	rm -rf "$WORK"
	FLAPPY_PREFIX=("${XVFB[@]}")
	run_flappy flappy_gl --rendering-driver opengl3 --single-window
else
	result SKIP e2e_gl "xvfb-run not installed"
fi

echo "---- Summary ----"
cat "$SUMMARY"
! grep -q "^FAIL" "$SUMMARY"
