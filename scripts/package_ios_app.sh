#!/usr/bin/env bash
# Links the editor library into an iPadOS application bundle and (optionally) an IPA.
# Usage: scripts/package_ios_app.sh device|simulator [output dir]
#
# Signing (device builds): set IOS_SIGN_IDENTITY (e.g. "Apple Development: Name (TEAMID)") and
# IOS_PROVISIONING_PROFILE (path to a .mobileprovision for the bundle id). Without them, the app is
# only ad-hoc signed: it runs in the Simulator, and the IPA must be re-signed (Xcode, AltStore,
# Sideloadly, ...) before it can be installed on an iPad.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
GODOT="${GODOT_DIR:-$ROOT/godot}"
VARIANT="${1:-device}"
OUT="${2:-$ROOT/build/$VARIANT}"

EXECUTABLE=Podot
BUNDLE_ID="${IOS_BUNDLE_ID:-io.github.sigivb72-netizen.podot}"
DISPLAY_NAME="${IOS_DISPLAY_NAME:-Podot}"
MIN_OS=14.0
source "$ROOT/UPSTREAM"
VERSION="${GODOT_TAG%-stable}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"

if [ "$VARIANT" = "simulator" ]; then
	SDK=iphonesimulator
	TARGET="arm64-apple-ios$MIN_OS-simulator"
	LIB="$GODOT/bin/libgodot.ios.editor.arm64.simulator.a"
	SUPPORTED_PLATFORM=iPhoneSimulator
else
	SDK=iphoneos
	TARGET="arm64-apple-ios$MIN_OS"
	LIB="$GODOT/bin/libgodot.ios.editor.arm64.a"
	SUPPORTED_PLATFORM=iPhoneOS
fi
[ -f "$LIB" ] || { echo "error: $LIB not found, run scripts/build_ios_editor.sh $VARIANT first" >&2; exit 1; }

SDK_PATH="$(xcrun --sdk "$SDK" --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk "$SDK" --show-sdk-version)"
APP="$OUT/$EXECUTABLE.app"
rm -rf "$APP"
mkdir -p "$APP" "$OUT/obj"

# The application entry point (SwiftUI @main) and all of the engine and editor are in the library;
# swiftc is used as the linker driver so that the Swift runtime is linked as well.
echo "import Foundation" > "$OUT/obj/link_stub.swift"
xcrun --sdk "$SDK" clang++ -target "$TARGET" -isysroot "$SDK_PATH" -Os -c "$ROOT/app/plugins_stub.cpp" -o "$OUT/obj/plugins_stub.o"
FRAMEWORKS=(Foundation UIKit SwiftUI QuartzCore Metal OpenGLES AVFoundation AVFAudio AudioToolbox
	CoreAudio CoreMIDI CoreMotion CoreHaptics CoreText CoreGraphics CoreVideo CoreMedia
	GameController UniformTypeIdentifiers Security)
FW_ARGS=()
for fw in "${FRAMEWORKS[@]}"; do FW_ARGS+=(-framework "$fw"); done
xcrun --sdk "$SDK" swiftc -parse-as-library -target "$TARGET" -sdk "$SDK_PATH" -Osize \
	"$OUT/obj/link_stub.swift" "$OUT/obj/plugins_stub.o" "$LIB" -o "$APP/$EXECUTABLE" \
	"${FW_ARGS[@]}" -Xlinker -weak_framework -Xlinker MetalFX \
	-lc++ -lz \
	-Xlinker -ObjC -Xlinker -dead_strip \
	-Xlinker -rpath -Xlinker @executable_path/Frameworks
xcrun strip -x "$APP/$EXECUTABLE"

sed -e "s|@DISPLAY_NAME@|$DISPLAY_NAME|g" -e "s|@EXECUTABLE@|$EXECUTABLE|g" -e "s|@BUNDLE_ID@|$BUNDLE_ID|g" \
	-e "s|@VERSION@|$VERSION|g" -e "s|@BUILD_NUMBER@|$BUILD_NUMBER|g" -e "s|@SUPPORTED_PLATFORM@|$SUPPORTED_PLATFORM|g" \
	-e "s|@PLATFORM_NAME@|$SDK|g" -e "s|@SDK_VERSION@|$SDK_VERSION|g" -e "s|@MIN_OS@|$MIN_OS|g" \
	"$ROOT/app/Info.plist.in" > "$APP/Info.plist"
plutil -convert binary1 "$APP/Info.plist"
cp "$ROOT"/app/icons/*.png "$APP/"
cp "$GODOT/misc/dist/apple_embedded_xcode/PrivacyInfo.xcprivacy" "$APP/" 2>/dev/null || true
printf 'APPL????' > "$APP/PkgInfo"

if [ "$VARIANT" = "device" ] && [ -n "${IOS_SIGN_IDENTITY:-}" ] && [ -n "${IOS_PROVISIONING_PROFILE:-}" ]; then
	cp "$IOS_PROVISIONING_PROFILE" "$APP/embedded.mobileprovision"
	# Entitlements: the profile's (application-identifier, team) merged with the app's.
	security cms -D -i "$IOS_PROVISIONING_PROFILE" > "$OUT/obj/profile.plist"
	/usr/libexec/PlistBuddy -x -c "Print :Entitlements" "$OUT/obj/profile.plist" > "$OUT/obj/entitlements.plist"
	if [ "${IOS_INCREASED_MEMORY:-1}" = "1" ]; then
		/usr/libexec/PlistBuddy -c "Add :com.apple.developer.kernel.increased-memory-limit bool true" "$OUT/obj/entitlements.plist" 2>/dev/null || true
	fi
	codesign --force --sign "$IOS_SIGN_IDENTITY" --entitlements "$OUT/obj/entitlements.plist" --timestamp=none "$APP"
	SIGNED=1
else
	# Ad-hoc signature (sufficient for the Simulator; must be re-signed for devices).
	codesign --force --sign - --timestamp=none "$APP"
	SIGNED=0
fi
codesign --verify --verbose=2 "$APP"

if [ "$VARIANT" = "device" ]; then
	rm -rf "$OUT/Payload" && mkdir -p "$OUT/Payload"
	cp -R "$APP" "$OUT/Payload/"
	IPA="$OUT/$EXECUTABLE-$VERSION$([ $SIGNED = 1 ] || echo -unsigned).ipa"
	(cd "$OUT" && rm -f "$IPA" && zip -qry "$IPA" Payload)
	rm -rf "$OUT/Payload"
	echo "IPA: $IPA (signed: $SIGNED)"
fi
du -sh "$APP"
echo "App: $APP"
