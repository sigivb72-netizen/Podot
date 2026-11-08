#!/usr/bin/env bash
# Runs the iPadOS editor in an iPad (10th generation) Simulator and checks real editor workflows.
# Usage: scripts/run_simulator_tests.sh <path to Podot.app built for the simulator> [results dir]
#
# Every test writes a line "PASS|FAIL|SKIP <name> <detail>" to <results dir>/summary.txt, and the
# screenshots, logs and JSON results of each step are kept in <results dir>.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${1:?path to Podot.app}"
RESULTS="${2:-$ROOT/build/simulator-results}"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Info.plist")"
mkdir -p "$RESULTS"
SUMMARY="$RESULTS/summary.txt"
: > "$SUMMARY"

result() { echo "$1 $2 ${3:-}" | tee -a "$SUMMARY"; }

# --- Simulator setup -----------------------------------------------------------------------------
RUNTIME="$(xcrun simctl list runtimes -j | python3 -c '
import json,sys
rts=[r for r in json.load(sys.stdin)["runtimes"] if r["platform"]=="iOS" and r["isAvailable"]]
print(sorted(rts,key=lambda r:[int(x) for x in r["version"].split(".")])[-1]["identifier"])')"
DEVTYPE="$(xcrun simctl list devicetypes -j | python3 -c '
import json,sys
ts=json.load(sys.stdin)["devicetypes"]
pref=[t for t in ts if t["name"]=="iPad (10th generation)"] or [t for t in ts if t["name"].startswith("iPad (")] or [t for t in ts if t["name"].startswith("iPad")]
print(pref[0]["identifier"])')"
echo "Runtime: $RUNTIME, device type: $DEVTYPE"
UDID="$(xcrun simctl create podot-test "$DEVTYPE" "$RUNTIME")"
cleanup() { xcrun simctl shutdown "$UDID" >/dev/null 2>&1; xcrun simctl delete "$UDID" >/dev/null 2>&1; }
trap cleanup EXIT
xcrun simctl boot "$UDID"
xcrun simctl bootstatus "$UDID" -b >/dev/null
# The Simulator UI is needed for injecting real touches and key presses.
open -a Simulator --args -CurrentDeviceUDID "$UDID" || true
sleep 10
xcrun simctl install "$UDID" "$APP" && result PASS install || { result FAIL install; exit 1; }

DATA="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)"
DOCS="$DATA/Documents"
mkdir -p "$DOCS"
echo "App data container: $DATA"

app_running() { xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -q "$BUNDLE_ID"; }
launch() { # launch <log name> [godot args...]
	local name="$1"; shift
	xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
	sleep 2
	xcrun simctl launch "$UDID" "$BUNDLE_ID" --log-file "$DOCS/logs/$name.log" "$@"
}
shot() { xcrun simctl io "$UDID" screenshot "$RESULTS/$1.png" >/dev/null 2>&1; }
copy_log() { cp "$DOCS/logs/$1.log" "$RESULTS/$1.log" 2>/dev/null; }
wait_for_file() { # wait_for_file <file> <timeout s> [python condition on json "d"]
	local f="$1" t="$2" cond="${3:-True}" i=0
	while [ $i -lt "$t" ]; do
		if [ -f "$f" ] && python3 -c "import json,sys; d=json.load(open('$f')); sys.exit(0 if ($cond) else 1)" 2>/dev/null; then
			return 0
		fi
		sleep 2; i=$((i + 2))
	done
	return 1
}
mkdir -p "$DOCS/logs"

# --- 1. Application startup (project manager) ----------------------------------------------------
launch startup
sleep 45
shot 01_project_manager
if app_running && grep -q "Godot Engine v" "$DOCS/logs/startup.log" 2>/dev/null; then
	result PASS startup "project manager running"
else
	result FAIL startup "app not running or no log"
fi
copy_log startup

# --- 2. Project creation (an empty project.godot is initialized by the editor) ---------------------
mkdir -p "$DOCS/NewProject" && : > "$DOCS/NewProject/project.godot"
launch create_project --editor --path "$DOCS/NewProject" --quit-after 2400
sleep 50
shot 02_new_project_editor
sleep 20
if grep -q "config_version=5" "$DOCS/NewProject/project.godot" && [ -d "$DOCS/NewProject/.godot" ]; then
	result PASS project_creation "project.godot initialized"
else
	result FAIL project_creation "$(head -c 300 "$DOCS/NewProject/project.godot")"
fi
copy_log create_project
app_running && result PASS quit_returns_to_project_manager "app still alive after the editor quit" || result FAIL quit_returns_to_project_manager

# --- 3. End-to-end editor scenario, including running the game in-process ---------------------------
rm -rf "$DOCS/e2e" && cp -R "$ROOT/tests/projects/e2e" "$DOCS/e2e"
mkdir -p "$DOCS/e2e/.test_results" && touch "$DOCS/e2e/.test_results/PODOT_E2E"
launch e2e --editor --path "$DOCS/e2e"
for i in 1 2 3 4 5 6; do sleep 30; shot "03_e2e_$i"; done
if wait_for_file "$DOCS/e2e/.test_results/editor.json" 900 'd["done"]'; then
	python3 - "$DOCS/e2e/.test_results/editor.json" <<'PY' | tee -a "$SUMMARY"
import json, sys
d = json.load(open(sys.argv[1]))
for name, c in sorted(d["checks"].items()):
    print(("PASS" if c["ok"] else "FAIL"), "e2e:" + name, c["detail"][:160].replace("\n", " "))
PY
else
	result FAIL e2e "did not finish; partial: $(cat "$DOCS/e2e/.test_results/editor.json" 2>/dev/null | head -c 2000)"
fi
cp -R "$DOCS/e2e/.test_results" "$RESULTS/e2e_results" 2>/dev/null
copy_log e2e
cp "$DATA/Library/Caches/in_process_game.log" "$RESULTS/" 2>/dev/null
find "$DATA" -name "in_process_game.log" -exec cp {} "$RESULTS/" \; 2>/dev/null

# --- 4. Application suspension and resumption -------------------------------------------------------
rm -rf "$DOCS/e2e/.test_results" && mkdir -p "$DOCS/e2e/.test_results" && touch "$DOCS/e2e/.test_results/PODOT_LIFECYCLE"
launch lifecycle --editor --path "$DOCS/e2e"
if wait_for_file "$DOCS/e2e/.test_results/lifecycle.json" 300 'd.get("ready")'; then
	xcrun simctl launch "$UDID" com.apple.Preferences >/dev/null
	sleep 10
	shot 04_backgrounded
	xcrun simctl launch "$UDID" "$BUNDLE_ID" >/dev/null # Brings the running app back to the foreground.
	sleep 15
	shot 04_resumed
	L="$DOCS/e2e/.test_results/lifecycle.json"
	cp "$L" "$RESULTS/lifecycle.json"
	python3 - "$L" <<'PY' | tee -a "$SUMMARY"
import json, sys
d = json.load(open(sys.argv[1]))
print(("PASS" if d["paused"] >= 1 else "FAIL"), "suspend_notification", d)
print(("PASS" if d["resumed"] >= 1 else "FAIL"), "resume_notification", d["resumed"])
print(("PASS" if d.get("saved_on_suspend") else "FAIL"), "save_on_focus_loss", d.get("save_on_focus_loss"))
PY
	app_running && result PASS alive_after_resume || result FAIL alive_after_resume
else
	result FAIL lifecycle "editor did not become ready"
fi
copy_log lifecycle

# --- 5. Real touch and hardware keyboard input through the Simulator ----------------------------------
rm -rf "$DOCS/e2e/.test_results" && mkdir -p "$DOCS/e2e/.test_results" && touch "$DOCS/e2e/.test_results/PODOT_INPUT"
launch input --editor --path "$DOCS/e2e"
I="$DOCS/e2e/.test_results/input.json"
if wait_for_file "$I" 300 'd.get("ready")'; then
	osascript -e 'tell application "Simulator" to activate' >/dev/null 2>&1
	sleep 2
	# Click in the middle of the simulated screen (the Simulator turns it into a touch).
	BOUNDS="$(osascript -e 'tell application "System Events" to tell process "Simulator" to get {position, size} of window 1' 2>/dev/null | tr -d ' ')"
	if [ -n "$BOUNDS" ] && command -v cliclick >/dev/null; then
		IFS=, read -r X Y W H <<<"$BOUNDS"
		cliclick "c:$((X + W / 2)),$((Y + H / 2))" || true
		sleep 2
	fi
	# Type on the Mac keyboard: forwarded to the app as a hardware keyboard (UIPress events).
	osascript -e 'tell application "System Events" to keystroke "podot"' >/dev/null 2>&1
	sleep 5
	shot 05_input
	cp "$I" "$RESULTS/input.json"
	python3 - "$I" "$BOUNDS" <<'PY' | tee -a "$SUMMARY"
import json, sys
d = json.load(open(sys.argv[1]))
if sys.argv[2]:
    print(("PASS" if d["touch"] >= 1 or d["mouse_button"] >= 1 else "FAIL"), "touch_input", {k: d[k] for k in ("touch", "mouse_button")})
else:
    print("SKIP touch_input could not locate the Simulator window (UI scripting unavailable)")
print(("PASS" if d["key"] >= 5 else "FAIL"), "hardware_keyboard_input", d["key"])
print(("PASS" if "podot" in d.get("text", "") else "FAIL"), "keyboard_typing_in_script_editor", repr(d.get("text", ""))[-80:])
PY
else
	result FAIL input "editor did not become ready"
fi
copy_log input

# --- 6. Existing project from the official demo collection -------------------------------------------
if git clone --depth 1 https://github.com/godotengine/godot-demo-projects.git "$RESULTS/../demos" >/dev/null 2>&1; then
	rm -rf "$DOCS/platformer" && cp -R "$RESULTS/../demos/2d/platformer" "$DOCS/platformer"
	launch existing_project --editor --path "$DOCS/platformer" --quit-after 3600
	sleep 75
	shot 06_existing_project
	sleep 15
	IMPORTED="$(find "$DOCS/platformer/.godot/imported" -type f 2>/dev/null | wc -l | tr -d ' ')"
	if [ "${IMPORTED:-0}" -gt 10 ]; then
		result PASS existing_project_import "$IMPORTED imported files"
	else
		result FAIL existing_project_import "${IMPORTED:-0} imported files"
	fi
	copy_log existing_project
else
	result SKIP existing_project_import "could not download godot-demo-projects"
fi

xcrun simctl terminate "$UDID" "$BUNDLE_ID" >/dev/null 2>&1
echo "---- Summary ----"
cat "$SUMMARY"
! grep -q "^FAIL" "$SUMMARY"
