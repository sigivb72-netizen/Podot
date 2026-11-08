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
if grep -q "Running the project in-process" "$RESULTS/e2e.log" && grep -q "\[game\] done, quitting" "$RESULTS/e2e.log" && grep -q "\[e2e\] editor is back after running the game" "$RESULTS/e2e.log"; then
	result PASS in_process_editor_game_editor "editor -> game -> editor in one process"
else
	result FAIL in_process_editor_game_editor "see e2e.log"
fi
if grep -q -- "--- Game session finished" "$RESULTS/e2e.log"; then
	result PASS game_output_shown_in_editor_log
else
	result FAIL game_output_shown_in_editor_log
fi
rm -rf "$WORK"

echo "---- Summary ----"
cat "$SUMMARY"
! grep -q "^FAIL" "$SUMMARY"
