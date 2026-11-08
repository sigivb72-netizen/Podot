# How the port works

Podot runs the unmodified Godot editor architecture on iPadOS. Everything visible in the app — the
project manager, docks, inspector, viewports, script editor — is the regular Godot editor, compiled
for iOS (`platform=ios target=editor`). The patches only touch what iPadOS forces to be different.
They are in `patches/` (against Godot `4.7.2-stable`, see `UPSTREAM`), grouped in five commits:

| Patch | Area |
|---|---|
| 0001 | core: in-process instances, re-entrant engine core (`core/`, `main/`, `platform/linuxbsd/`) |
| 0002 | servers, scene, modules: singletons and registries cleared on teardown |
| 0003 | editor: in-process game runs, mobile adaptations, device limits, low memory |
| 0004 | iOS platform integration (`drivers/apple_embedded/`, `platform/ios/`) |
| 0005 | unit tests (`tests/podot/`) |

## 1. Running the editor, the project manager and the game in one process

Desktop Godot starts a new process for everything: the project manager starts the editor, the
editor starts the game, "Reload project" restarts the editor. iOS apps cannot create processes.

Godot already funnels all of these through `OS::create_instance()`. The port adds *in-process
instances* to `OS`:

* When enabled, `OS::create_instance(args)` queues `args` instead of spawning a process.
* When the main loop quits (`Main::iteration()` returns `true`), the platform calls
  `Main::cleanup()`, then `Main::setup()` again with the next queued arguments, so the next
  instance (editor, game, project manager) starts in the same process, exactly as if it had been
  launched with those command-line arguments.
* A small `OS` key/value store ("session data") survives these relaunches, e.g. the path of the
  game's log for the editor that comes back.

Making `Main` re-entrant needed three core changes:

* `StringName::cleanup()` normally frees every name, which leaves the function-local
  `static StringName` objects created by `SNAME()` dangling. With
  `StringName::preserve_static_on_cleanup` the names referenced by static StringNames are kept in
  the table (with their reference counts reset to the static count) and reused by the next setup.
* `main.cpp` keeps ~90 file-scope variables (parsed options, server pointers). They are reset to
  their initial values (`_reset_main_static_state()`) before a repeated setup, as are the
  iteration statistics and the timer sync.
* Loggers added by `Main::setup()` (e.g. `--log-file`) are removed again on cleanup
  (`CompositeLogger::truncate_loggers()`), otherwise they would accumulate.
* Class registration: every `GDCLASS` used a function-static `initialized` flag and a static
  `GDType` pointer, so after `ClassDB::cleanup()` the classes were never registered again (and the
  freed `GDType`s were dereferenced). Registration now tracks a ClassDB generation counter that
  `ClassDB::cleanup()` increments.
* `ObjectDB::cleanup()` freed its slot table but kept the pointer and counters.
* About 60 singletons (core, servers, scene, editor, modules; found with a scan for constructors
  that set `singleton = this` and with AddressSanitizer) kept a dangling pointer after their
  destructor; they now clear it (`if (singleton == this) singleton = nullptr;`). The rendering
  server's globals (`RSG::*`) are cleared after the renderer is finalized.
* Static registries filled on every setup (movie writers, idle callbacks, editor plugin
  factories, editor init callbacks) are cleared or de-duplicated.
* The editor changes process-wide state for editor mode (resource load/save callbacks,
  placeholder instancing, missing-resource handling, error notifiers, file dialog defaults, ...).
  `~EditorNode` restores the defaults, so a game started next in the same process behaves exactly
  like a game started on its own.

All of this is verified by running the editor → game → editor → restart cycle under
AddressSanitizer, headless and with the real OpenGL ES 3 renderer and X11 display server
(`scripts/run_linux_tests.sh`).

### Running the game ("Play")

`EditorRun::run()` checks `OS::is_in_process_instances_enabled()` and calls
`EditorNode::run_game_in_process()`:

1. The scenes are saved (as before running on desktop, `run/auto_save/save_before_running`).
2. The game's arguments are the regular ones, minus `--remote-debug`/`--editor-pid` (the editor is
   not running while the game runs), plus `--log-file <editor cache>/in_process_game.log`.
3. The game, then the editor (same project, same edited scene) are queued, and the editor exits
   normally (`_exit_editor()`: layout saved, plugins unloaded).
4. The game runs with the whole device memory available. It ends when it calls
   `get_tree().quit()`, when the user taps the floating **Stop** button (native UIKit control
   added by the iOS platform code), or presses **F8** / **⌘.** on a hardware keyboard.
5. The editor is set up again, reopens the project and scenes, and prints the game's output into
   the Output dock with errors and warnings classified, plus the exit code and run time.

If iPadOS terminates the app while the game runs (crash, memory pressure, app closed), a marker
file makes the next launch go straight back to that project's editor and report it.

The same mechanism can be enabled on Linux with `GODOT_IN_PROCESS_INSTANCES=1`, which is how the
flow is tested without a Mac (`scripts/run_linux_tests.sh`).

## 2. iPadOS input

UIKit reports mice, trackpads and the Apple Pencil as `UITouch`es or gesture recognizers; upstream
Godot turned all of them into screen touches. `GDTView` now routes them:

| Device | Godot events |
|---|---|
| Finger | `InputEventScreenTouch/Drag` (unchanged; the editor's touch optimizations apply) |
| Mouse / trackpad buttons (`UITouchTypeIndirectPointer`, requires `UIApplicationSupportsIndirectInputEvents`) | `InputEventMouseButton` left/right/middle, `InputEventMouseMotion` with button mask, double click |
| Pointer hover (`UIHoverGestureRecognizer`) | `InputEventMouseMotion` |
| Scroll wheel / two-finger trackpad scroll | `InputEventPanGesture` (same scale as macOS precise scrolling) |
| Trackpad pinch | `InputEventMagnifyGesture` |
| Apple Pencil | In the editor and project manager: mouse events with pressure and tilt (precise, no touch emulation lag). In projects: touches as upstream, or mouse with `input_devices/pointing/ios/pencil_as_mouse=true` |
| Hardware keyboard | `InputEventKey` (upstream) plus key repeat (UIKit doesn't report repeats), macOS key conventions for shortcuts (⌘/⌥), keyboard connect/disconnect notifications (the touch actions panel hides when a keyboard is attached) |

The pointer shape follows `DisplayServer::cursor_set_shape()` through `UIPointerInteraction`
(I-beam in text, resize beams on splitters, ...).

## 3. Files

* Projects live in the app's `Documents` folder by default, which the Files app shows under
  *On My iPad › Podot* (`UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`). Godot's own
  file dialogs browse it like any folder.
* Opening a file or folder from the filesystem (project manager *Import*/*Scan*, editor file
  dialogs with filesystem access) uses the system document picker, so projects on iCloud Drive,
  external USB drives or other apps' storage can be opened and edited **in place**. The picked
  locations are kept as security-scoped bookmarks and re-opened at every launch.
* "Show in File Manager" opens the folder in the Files app (`shareddocuments://`).

## 4. Lifecycle, memory and storage

* Background/foreground notifications are upstream's (`NOTIFICATION_APPLICATION_PAUSED/RESUMED`,
  focus in/out). The editor's *Save on focus loss* is enabled by default on iPadOS, because a
  suspended app can be terminated without notice.
* `NOTIFICATION_OS_MEMORY_WARNING` (from `applicationDidReceiveMemoryWarning`) makes the editor drop
  its in-memory thumbnail cache and warn the user.
* Before opening a project, the project manager estimates whether it fits the device
  (`ProjectDeviceLimits`): asset size vs. RAM, the largest single file vs. RAM, free storage vs.
  the first import, file count. It shows a clear explanation and lets the user open it anyway.
* The app requests the *increased memory limit* entitlement when the signing profile allows it.

## 5. Rendering

Device builds include Metal (Forward+ and Mobile renderers) and OpenGL ES 3 (Compatibility).
The editor defaults new projects to the Mobile renderer (as the Android editor does). Upstream
Godot does not enable Metal for the iOS Simulator, so Simulator builds only run the Compatibility
renderer. When the editor and the game use different rendering drivers, the rendering layer is
re-created on each relaunch (`-[GDTView releaseRenderingLayer]`).

## 6. Editor features that are unavailable because of iPadOS

These upstream features need to start external programs or a second process, which iOS forbids.
They are hidden on iPadOS (as most of them already are in the Android editor): *Open in Terminal*,
*Open in External Program*, *Open User Data Folder*, FBX2glTF configuration (the built-in ufbx FBX
importer still works), the *Game* workspace (embedding the running game next to the editor needs a
second process). Running several instances at once starts only one (with a warning). The
off-by-default settings that point to external tools (external script editor, Blender path) are
still listed, as in the Android editor; enabling them results in an error message when used.
