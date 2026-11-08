# Podot — the real Godot 4 editor on iPadOS

Podot builds the **upstream Godot 4.7.2 editor** (not a remake, not a web view) as a native iPadOS
app. The engine and the editor are Godot's own C++ source, compiled with `platform=ios
target=editor`, plus a small set of platform patches. Projects are ordinary Godot 4.7 projects:
they open and save in the same formats as desktop Godot.

* How it works: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)
* What was tested, what works, what doesn't: [docs/STATUS.md](docs/STATUS.md)

## Repository layout

| Path | Contents |
|---|---|
| `UPSTREAM` | The pinned upstream revision (`4.7.2-stable`, `ed1daf0b`). |
| `patches/` | The port, as a `git am` patch series against upstream (core, editor, iOS platform, tests). |
| `scripts/fetch_godot.sh` | Clones upstream at the pinned revision into `godot/` and applies the patches. |
| `scripts/build_ios_editor.sh` | Builds the editor static library for iPadOS (`device`) or the iOS Simulator (`simulator`). |
| `scripts/package_ios_app.sh` | Links the library into `Podot.app`, signs it, and makes the IPA. |
| `scripts/run_simulator_tests.sh` | Runs the editor in an iPad (10th generation) Simulator and checks real workflows. |
| `scripts/run_linux_tests.sh` | Unit tests + the in-process editor → game → editor flow on a Linux editor build. |
| `app/` | Info.plist, entitlements, icons. |
| `tests/projects/e2e/` | Test project with an editor plugin that drives the editor end to end. |
| `.github/workflows/ipados-editor.yml` | CI on GitHub's macOS (Xcode) and Linux runners. |

The complete modified source is upstream + `patches/`; `scripts/fetch_godot.sh` reproduces it
exactly (`godot/` is ignored by git).

## Building (macOS with Xcode 16+)

```bash
pip3 install scons
```

```bash
scripts/fetch_godot.sh
```

```bash
scripts/build_ios_editor.sh device
```

```bash
scripts/package_ios_app.sh device build/device
```

This produces `build/device/Podot.app` and `build/device/Podot-4.7.2-unsigned.ipa`. A full build
takes about 15 minutes on an M-series Mac.

For the Simulator (Compatibility renderer only, see STATUS):

```bash
scripts/build_ios_editor.sh simulator && scripts/package_ios_app.sh simulator build/simulator
```

```bash
scripts/run_simulator_tests.sh build/simulator/Podot.app build/simulator-results
```

### Signing and installing on an iPad

iOS only installs apps signed for the device. Without credentials the scripts produce an
**unsigned** IPA (ad-hoc signature), which is what CI publishes. To install it:

* **Sign during packaging**: set `IOS_SIGN_IDENTITY` (e.g. `Apple Development: Name (TEAMID)`),
  `IOS_PROVISIONING_PROFILE` (path to a `.mobileprovision` for the bundle id) and, if needed,
  `IOS_BUNDLE_ID`, then run `scripts/package_ios_app.sh device`. In CI, the same comes from the
  secrets `IOS_CERT_P12_BASE64`, `IOS_CERT_PASSWORD`, `IOS_PROFILE_BASE64`, `IOS_SIGN_IDENTITY`.
* **Re-sign the unsigned IPA** with a sideloading tool that uses your Apple ID (e.g. AltStore,
  Sideloadly) or with Xcode's *Devices and Simulators* window after re-signing with `codesign`.

The app asks for the *increased memory limit* entitlement (useful on 4 GB iPads); remove it from
the entitlements if your provisioning profile doesn't allow it (`IOS_INCREASED_MEMORY=0`).

### Linux (tests of the shared code)

```bash
scripts/fetch_godot.sh && (cd godot && scons platform=linuxbsd target=editor tests=yes -j$(nproc))
```

```bash
scripts/run_linux_tests.sh godot/bin/godot.linuxbsd.editor.x86_64
```

## Using it

* Projects live in *Files › On My iPad › Podot* (the app's Documents folder). Copy a desktop
  project there, or use the project manager's **Import** to open a folder anywhere (iCloud Drive,
  USB drive, other apps) through the system picker; it is edited in place and stays accessible
  across launches.
* **Play** closes the editor, runs the game full-screen in the same app, and returns to the editor
  when the game quits, when you tap the floating **Stop** button, or press **F8** / **⌘.**. The
  game's output (with errors and warnings) appears in the Output dock.
* Touch, Apple Pencil, keyboard, mouse and trackpad all work; see STATUS for details.
