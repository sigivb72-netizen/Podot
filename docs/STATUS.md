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

## iPad Simulator tests (`scripts/run_simulator_tests.sh`, iPad 10th generation)

Results of CI run 18 (`1ad5bd5`). The CI Simulator renders with Apple's *software* OpenGL
renderer, which makes the editor very slow there.

| Test | Result |
|---|---|
| App installs and launches; project manager runs | ✅ |
| Project creation (empty `project.godot` initialized by the editor, `.godot/` created) | ✅ |
| Editor quits → app stays alive and returns to the project manager (in-process relaunch on iOS) | ✅ |
| Scene/node editing, undo/redo, duplicate, reparent, delete, signals & groups, physics, AnimationPlayer/AnimationTree, TileMapLayer, save & reload, GDScript compile/run/error reporting, project settings & input map, 2D/3D viewport rendering | ✅ (e2e plugin inside the real editor on the Simulator) |
| Two-finger pan and pinch zoom in the 2D and 3D viewports | ✅ |
| Asset import (texture, WAV, glTF); importing an existing demo project (37/37 assets) | ✅ |
| **Play: editor shuts down → game runs in the same process (physics, touch/key input, imported assets, rendering) → editor comes back with the project and scenes**; Reload Current Project | ✅ |
| Suspension/resumption notifications, save on focus loss, app alive after resume | ✅ |
| Touch input and hardware keyboard events | ✅ |
| Typed text reaching the script editor's text field | ❌ (keys arrive, but the text field doesn't have focus in the test setup) |
| Audio playback (CoreAudio) | ❌ on the CI Simulator the stream position stays at 0 (no audio device on the runner); not verified |
| Metal renderer on the Simulator (`simulator_metal` build) | ❌ the editor starts on the Simulator's virtual GPU (Apple2 family, below Godot's requirements) but doesn't get past the first frames within the time limit. Metal does run on devices (reported by a tester on an iPad 10th gen) |

## On-device reports

* iPad 10th generation, iPadOS 27: project manager and editor run with Metal. Pressing Play
  crashed with `abort` in `AudioServer::finish()` while the editor shut down to start the game: the
  Dummy audio driver freed its buffer again on the second in-process teardown. Fixed (regression
  test `[Podot][Audio]`); the fix awaits confirmation on the device.

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
* **Simulator rendering**: upstream Godot does not enable Metal for the iOS Simulator; the port's
  `simulator_metal` build does, but the CI Simulator's GPU is too weak for the editor. On devices,
  Metal (Forward+/Mobile) runs the editor (tester report); automated tests use Compatibility.
* **iCloud files not downloaded locally** are not fetched automatically (no `NSFileCoordinator`).
* **Signing**: see above. The *increased memory limit* entitlement requires a profile that allows it.
