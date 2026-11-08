# Status: what works, what was tested, what doesn't

Last updated from CI run 9 (`d900965`) and local runs on the same patches. "Tested" below means an
automated test exercised it and passed; everything else is marked as *built, not verified* or as a
limitation. No physical iPad was available during development: device behaviour was tested in the
iPad (10th generation) Simulator, and the editor/engine flow additionally on Linux.

## Build and packaging

| Item | Result |
|---|---|
| Full Godot 4.7.2 editor compiled for iPadOS arm64 (Metal + OpenGL ES 3) | ✅ CI (`ios-device` job), ~15 min clean on a GitHub macOS runner |
| Same for the arm64 iOS Simulator (OpenGL ES 3) | ✅ CI (`ios-simulator` job) |
| App bundle linked, code-signed (ad-hoc), IPA created | ✅ CI artifact `podot-ipados-ipa` (~63 MB zipped) |
| Signed, installable IPA | ❌ Not produced: no Apple signing certificate / provisioning profile was available. The CI job signs automatically when the `IOS_*` secrets are set (see README). The unsigned IPA must be re-signed before installing on an iPad. |
| Patch series applies cleanly to upstream `4.7.2-stable` | ✅ every CI run |

## iPad Simulator tests (`scripts/run_simulator_tests.sh`, iPad 10th generation, iOS 26.2)

Results of CI run 8 (`f82ba5d`) unless noted. The CI Simulator renders with Apple's *software*
OpenGL renderer, which makes the editor very slow there; timeouts were raised in run 9.

| Test | Result |
|---|---|
| App installs and launches; project manager runs | ✅ |
| Project creation (empty `project.godot` initialized by the editor, `.godot/` created) | ✅ |
| Editor quits → app stays alive and returns to the project manager (in-process relaunch on iOS) | ✅ |
| Scene/node editing, undo/redo, duplicate, reparent, delete, signals & groups, physics, AnimationPlayer/AnimationTree, TileMapLayer, save & reload, GDScript compile/run/error reporting, project settings & input map | ✅ (e2e plugin inside the real editor on the Simulator) |
| Suspension → `NOTIFICATION_APPLICATION_PAUSED` / focus out; resumption → `RESUMED` / focus in; app alive after resume | ✅ |
| Save on focus loss when the app goes to the background (unsaved scene saved to disk) | ✅ |
| Hardware keyboard key events delivered to the editor (UIPress → `InputEventKey`, 5/5 keys) | ✅ |
| Asset import (texture, WAV, glTF) and importing an existing demo project | ❌ in run 8: the FileSystem scan did not finish within the time limits on the software renderer, and editor settings were written to the read-only app bundle (fixed in run 9: Application Support). See run 9. |
| Typed text reaching the script editor's text field | ❌ in run 8 (keys arrived, but the text field did not have focus; test setup fixed in run 9) |
| Touch injected through the Simulator window (`cliclick`) | ❌ no touch events arrived; most likely the CI runner does not grant the UI-scripting permission that `cliclick` needs. Touch input is therefore **not verified on iOS**; it uses upstream's unchanged touch path. |
| Running the game in-process on iOS and returning to the editor | ⚠️ not verified on the Simulator yet (the e2e scenario did not reach the game step in run 8 because of the import timeouts above); verified on Linux (below). |

## Linux tests of the shared code (`scripts/run_linux_tests.sh`)

Run locally with an AddressSanitizer build and in CI with a release build. **All pass**:

* 6 new unit test cases (in-process instance queue, session data, logger truncation, static
  StringName handling, project device-limit warnings, project scanning).
* End-to-end, headless, with `GODOT_IN_PROCESS_INSTANCES=1` (the iPadOS process model), 46/46 checks:
  scene creation and modification through the editor's undo/redo, duplication, reparenting,
  deletion, signals, groups, physics bodies/shapes, AnimationPlayer + AnimationTree, TileMapLayer,
  texture/WAV/glTF import, GDScript compile/run/errors, script editor (open, syntax highlighter,
  edit, save), project settings, input map, **Play → the editor shuts down → the game runs in the
  same process** (loads the editor-imported texture and saved scene, physics runs, touch/key input
  events processed) **→ the editor comes back** with the same scenes open and the game output in
  the Output dock (`--- Game session finished (exit code 0, ran for 1.3 s) ---`), then *Reload
  Current Project* relaunches the editor in-process again. AddressSanitizer reports no errors over
  the three teardowns.

## Features

Everything the desktop editor has is compiled in and runs: scene tree and node management,
inspector, resources, FileSystem dock, script editor with GDScript highlighting, completion and
error reporting, 2D and 3D editors, animation editors, TileMap/TileSet editors, physics, audio
buses, importers, project settings, input map, signals/groups, debugger UI, export dialog. The
items above say which of them were exercised by tests.

iPadOS-specific (implemented; see ARCHITECTURE.md):

* In-process project manager → editor → game → editor workflow, Stop button, F8 / ⌘.
* Mouse/trackpad buttons, hover, scrolling, pinch, pointer shapes — *built, not verified* (needs a device or a Simulator with pointer input).
* Apple Pencil as precise mouse with pressure/tilt in the editor — *built, not verified* (no Pencil in the Simulator).
* Hardware keyboard: key events ✅ tested; key repeat and connect/disconnect handling *built, not verified*.
* Files app integration, system document picker with persisted security-scoped bookmarks — *built, not verified* (needs interactive picking).
* Multitasking (Split View / Slide Over, all orientations): enabled in Info.plist; the editor ran in portrait on the Simulator ✅.
* Project size/storage warning before opening, low-memory handling — unit-tested logic ✅; on-device behaviour *not verified*.

## Known limitations

* **Debugger while the game runs**: the editor is not running while the game runs (one process,
  one engine instance at a time), so breakpoints, the remote scene tree and live editing don't
  work for games started on the iPad. Errors, warnings and prints are shown in the Output dock
  afterwards. The debugger still works for a game running on *another* device that connects to
  the iPad's editor (upstream remote debugging), not verified.
* **Game workspace / embedded game**: not available (needs a second process).
* **Several instances at once**: only one instance is started.
* **External tools**: no terminal, external script editor, Blender importer, FBX2glTF (the built-in
  ufbx FBX importer works), or iOS export (needs Xcode). Other export platforms run their
  upstream code paths; untested.
* **Simulator rendering**: upstream Godot does not enable Metal for the iOS Simulator, so only
  the Compatibility renderer works there. On devices, Metal (Forward+/Mobile) is compiled in but
  untested here.
* **iCloud files not downloaded locally** are not fetched automatically (no `NSFileCoordinator`).
* **Signing**: see above. The *increased memory limit* entitlement requires a profile that allows it.
