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

The Android editor runs the game in a second process (`android:process=":GodotGame"`) shown in a
separate window next to the editor. iOS doesn't allow starting processes, so Podot runs the game
in a **second `SceneTree` inside the editor process** and shows it in a floating window on top of
the editor (`InProcessGame`, `scene/main/in_process_game.cpp`; `InProcessGameWindow`,
`editor/run/in_process_game_window.cpp`). The editor stays open and usable while the game runs.

* The game's root `Window` renders off-screen (`Window::set_offscreen_root()`): it doesn't take
  over the device screen; its viewport texture is drawn by the game window, whose size is the
  game's window size (the project's stretch settings apply as in a real window).
* `Main::iteration()` steps the game after the editor's frame (physics and process frames).
  While game code runs (loading, input, physics callbacks, frames) the engine is in *game mode*:
  `Engine::is_editor_hint()` is false and scripting is enabled, so the project's scripts get real
  instances; everything else runs in editor mode.
* The editor's physics spaces are paused while the physics servers run for the game; the project's
  input actions and autoloads are added for the game's lifetime and removed afterwards.
* Touch, mouse, trackpad and keyboard input on the game window are forwarded to the game (touches
  focus the window and skip the editor's two-finger gesture delay).
* The window can be moved, resized and maximized; **Stop** (in the window or the editor's run
  bar), **Restart**, or the game calling `get_tree().quit()` end it. Errors and prints from the game
  appear in the editor's Output dock as they happen.

Limitations of sharing the process: the game shares loaded resources with the editor (a game that
modifies a resource at runtime also changes it in the editor until it's reloaded), shares the
`Input` singleton (taps elsewhere on the screen also count for `Input.is_action_pressed()`), and a
crash in game code also closes the editor (the crash reporter shows the report on the next launch).
`Engine.get_main_loop()` returns the editor's tree. The "viewport" stretch mode is shown stretched
to the window (no letterboxing).

The previous mode, where the editor shuts down while the game runs in-process and reopens when it
quits (`EditorNode::run_game_in_process()`), is still used to relaunch the editor and project
manager (`OS::create_instance` queues them, see above).

The same mechanism can be enabled on Linux with `GODOT_IN_PROCESS_INSTANCES=1`, which is how the
flow is tested without a Mac (`scripts/run_linux_tests.sh`, `tests/projects/flappy`).

## 2. iPadOS input

UIKit reports mice, trackpads and the Apple Pencil as `UITouch`es or gesture recognizers; upstream
Godot turned all of them into screen touches. `GDTView` now routes them:

| Device | Godot events |
|---|---|
| One finger | `InputEventScreenTouch/Drag` (the editor's touch optimizations apply). In the editor, the first touch is held back for ~0.1 s so that a following second finger never selects or moves anything |
| Two-finger drag (canvas gestures) | `InputEventPanGesture`: the 2D canvas, TileMap/texture-region editors, animation and shader graphs and the 3D viewport pan **with the fingers**, like a drawing app |
| Pinch | `InputEventMagnifyGesture`: zoom around the pinch center (2D, 3D, graphs, code editor font size) |
| Two-finger tap / three-finger tap | Undo / Redo in the editor (the editor's own ⌘Z / ⇧⌘Z shortcuts) |
| Mouse / trackpad buttons (`UITouchTypeIndirectPointer`, requires `UIApplicationSupportsIndirectInputEvents`) | `InputEventMouseButton` left/right/middle, `InputEventMouseMotion` with button mask, double click |
| Pointer hover (`UIHoverGestureRecognizer`) | `InputEventMouseMotion` |
| Scroll wheel / two-finger trackpad scroll | `InputEventPanGesture` (same scale as macOS precise scrolling) |
| Trackpad pinch | `InputEventMagnifyGesture` |
| Apple Pencil | In the editor and project manager: mouse events with pressure and tilt (precise, no touch emulation lag). In projects: touches as upstream, or mouse with `input_devices/pointing/ios/pencil_as_mouse=true` |
| Hardware keyboard | `InputEventKey` (upstream) plus key repeat (UIKit doesn't report repeats), macOS key conventions for shortcuts (⌘/⌥), keyboard connect/disconnect notifications (the touch actions panel hides when a keyboard is attached) |

The canvas gestures come from `TouchGestureRecognizer` (`core/input/`), a platform-independent
recognizer fed by the iOS view; it is unit-tested on its own. They are on in the editor
(`interface/touchscreen/enable_pan_and_scale_gestures`) and opt-in for projects
(`input_devices/pointing/ios/enable_pan_and_scale_gestures`). Two upstream bugs had to be fixed for
them to feel right: `Input` dispatched every gesture event twice (so pinches and trackpad pans were
applied twice on all platforms), and `ViewPanner` didn't accept pan gestures.

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
