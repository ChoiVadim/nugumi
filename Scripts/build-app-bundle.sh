#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT/dist/Gizmate.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICNS_PATH="$ROOT/Resources/AppIcon.icns"
DMG_BG_PATH="$ROOT/Resources/dmg-background.png"
DMG_PATH="$ROOT/dist/Gizmate.dmg"
DMG_RW_PATH="$ROOT/.build/Gizmate.rw.dmg"
DMG_STAGE="$ROOT/.build/dmg-stage"
LOCAL_HOME="$ROOT/.build/home"
LOCAL_MODULE_CACHE="$ROOT/.build/clang-module-cache-release"
TOOL_WORKER_RUNTIME="$ROOT/.build/tool-worker-runtime/arm64"
TOOL_AGENT_RUNTIME="$ROOT/.build/tool-agent-runtime/arm64"

# Universal (arm64 + x86_64) by default; pass UNIVERSAL=0 to build host-arch only.
UNIVERSAL="${UNIVERSAL:-1}"
if [ "$UNIVERSAL" != "0" ]; then
    echo "Tool worker packaging is arm64-only until an x86_64 runtime gate is proven. Use UNIVERSAL=0." >&2
    exit 1
fi
if [ "$(/usr/bin/uname -m)" != "arm64" ]; then
    echo "Tool worker packaging currently requires an arm64 build host." >&2
    exit 1
fi

# Signing identity. Default is ad-hoc; set DEVELOPER_ID to a Developer ID
# certificate name (e.g. 'Developer ID Application: Vadim Choi (XXXXXXXXXX)')
# for distributable signed builds.
DEVELOPER_ID="${DEVELOPER_ID:-}"
if [ -n "$DEVELOPER_ID" ]; then
    SIGN_IDENTITY="$DEVELOPER_ID"
else
    SIGN_IDENTITY="-"
fi

# Notarization. Set NOTARIZE_PROFILE to a keychain profile name created via
# `xcrun notarytool store-credentials` to enable submit + staple. Requires
# DEVELOPER_ID to also be set (Apple notary rejects ad-hoc binaries).
NOTARIZE_PROFILE="${NOTARIZE_PROFILE:-}"
if [ -n "$NOTARIZE_PROFILE" ] && [ -z "$DEVELOPER_ID" ]; then
    echo "NOTARIZE_PROFILE is set but DEVELOPER_ID is empty — Apple's notary cannot accept ad-hoc binaries." >&2
    exit 1
fi

cd "$ROOT"
mkdir -p "$LOCAL_HOME" "$LOCAL_MODULE_CACHE"
REAL_HOME="$HOME"
export HOME="$LOCAL_HOME"
export CLANG_MODULE_CACHE_PATH="$LOCAL_MODULE_CACHE"

if [ ! -f "$ICNS_PATH" ]; then
    echo "AppIcon.icns missing — regenerating."
    swift "$ROOT/Scripts/generate-icon.swift" "$ICNS_PATH"
fi
if [ ! -f "$DMG_BG_PATH" ]; then
    echo "dmg-background.png missing — regenerating."
    swift "$ROOT/Scripts/generate-dmg-background.swift" "$DMG_BG_PATH"
fi

if [ "$UNIVERSAL" = "1" ]; then
    swift build \
        -c release \
        --arch arm64 \
        --arch x86_64 \
        --disable-sandbox \
        --cache-path "$ROOT/.build/swiftpm-cache" \
        --config-path "$ROOT/.build/swiftpm-config" \
        --security-path "$ROOT/.build/swiftpm-security" \
        -Xcc "-fmodules-cache-path=$LOCAL_MODULE_CACHE"
    BINARY_PATH="$ROOT/.build/apple/Products/Release/Gizmate"
else
    swift build \
        -c release \
        --disable-sandbox \
        --cache-path "$ROOT/.build/swiftpm-cache" \
        --config-path "$ROOT/.build/swiftpm-config" \
        --security-path "$ROOT/.build/swiftpm-security" \
        -Xcc "-fmodules-cache-path=$LOCAL_MODULE_CACHE"
    BINARY_PATH="$ROOT/.build/release/Gizmate"
fi
WORKER_BINARY_PATH="$(dirname "$BINARY_PATH")/GizmateToolWorker"
WORKER_RESOURCE_BUNDLE="$(dirname "$BINARY_PATH")/Gizmate_GizmateToolWorker.bundle"

if [ ! -f "$BINARY_PATH" ]; then
    echo "Build output not found at $BINARY_PATH" >&2
    exit 1
fi
if [ ! -f "$WORKER_BINARY_PATH" ]; then
    echo "Tool worker build output not found at $WORKER_BINARY_PATH" >&2
    exit 1
fi
if [ ! -d "$WORKER_RESOURCE_BUNDLE" ]; then
    echo "Tool worker resource bundle not found at $WORKER_RESOURCE_BUNDLE" >&2
    exit 1
fi

"$ROOT/Scripts/prepare-tool-worker-runtime.sh"
"$ROOT/Scripts/prepare-tool-agent-runtime.sh"

# Restore real HOME so codesign / notarytool can find the user's keychain.
# Swift build needed the sandboxed HOME above, but signing tools look up
# `~/Library/Keychains/login.keychain-db` and would otherwise miss the
# Developer ID identity entirely.
export HOME="$REAL_HOME"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$BINARY_PATH" "$MACOS_DIR/Gizmate"
cp "$ROOT/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ICNS_PATH" "$RESOURCES_DIR/AppIcon.icns"

# SwiftPM emits target resources (the PixelifySans font, etc.) into a
# generated `Gizmate_Gizmate.bundle` next to the product binary. `Bundle.module`
# fatalErrors if it can't find this at runtime — and one of its fallbacks is a
# build-time absolute path under .build that only exists on the build machine.
# Without copying the bundle into the .app, the app launches for the builder
# but crashes on every other Mac the moment any resource is touched.
RESOURCE_BUNDLE="$(dirname "$BINARY_PATH")/Gizmate_Gizmate.bundle"
if [ ! -d "$RESOURCE_BUNDLE" ]; then
    echo "SwiftPM resource bundle not found at $RESOURCE_BUNDLE — did 'swift build' run?" >&2
    exit 1
fi
rm -rf "$RESOURCES_DIR/Gizmate_Gizmate.bundle"
cp -R "$RESOURCE_BUNDLE" "$RESOURCES_DIR/Gizmate_Gizmate.bundle"

XPC_DIR="$CONTENTS_DIR/XPCServices/GizmateToolWorker.xpc"
XPC_CONTENTS="$XPC_DIR/Contents"
XPC_MACOS="$XPC_CONTENTS/MacOS"
XPC_RESOURCES="$XPC_CONTENTS/Resources"
mkdir -p "$XPC_MACOS" "$XPC_RESOURCES/Runtime"
cp "$ROOT/Resources/GizmateToolWorker-Info.plist" "$XPC_CONTENTS/Info.plist"
cp "$WORKER_BINARY_PATH" "$XPC_MACOS/GizmateToolWorker"
cp -R "$TOOL_WORKER_RUNTIME/python" "$XPC_RESOURCES/Runtime/python"
cp -R "$TOOL_WORKER_RUNTIME/site-packages" \
    "$XPC_RESOURCES/Runtime/site-packages"
cp "$TOOL_WORKER_RUNTIME/runtime.json" "$XPC_RESOURCES/Runtime/runtime.json"
cp -R "$WORKER_RESOURCE_BUNDLE" \
    "$XPC_RESOURCES/Gizmate_GizmateToolWorker.bundle"

TOOL_AGENT_RESOURCES="$CONTENTS_DIR/Resources/ToolAgent"
PACKAGED_NODE="$CONTENTS_DIR/Helpers/ToolAgentNode"
mkdir -p "$CONTENTS_DIR/Helpers" "$TOOL_AGENT_RESOURCES"
cp "$TOOL_AGENT_RUNTIME/node" "$PACKAGED_NODE"
cp "$TOOL_AGENT_RUNTIME/package.json" "$TOOL_AGENT_RESOURCES/package.json"
cp "$TOOL_AGENT_RUNTIME/runtime.json" "$TOOL_AGENT_RESOURCES/runtime.json"
cp -R "$TOOL_AGENT_RUNTIME/dist" "$TOOL_AGENT_RESOURCES/dist"
cp -R "$TOOL_AGENT_RUNTIME/node_modules" "$TOOL_AGENT_RESOURCES/node_modules"

# SwiftPM-built binaries don't auto-embed @executable_path/../Frameworks in
# their rpath, so dyld can't locate Sparkle.framework. Add it explicitly.
install_name_tool -add_rpath "@executable_path/../Frameworks" "$MACOS_DIR/Gizmate" 2>/dev/null || true

# --- Sparkle.framework bundling ---
# Sparkle.framework is fetched as a SwiftPM binary xcframework. Prefer the
# universal slice for distribution; fall back to whatever is in .build.
SPARKLE_FRAMEWORK_PATH=""
for candidate in \
    "$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" \
    "$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos/Sparkle.framework"; do
    if [ -d "$candidate" ]; then
        SPARKLE_FRAMEWORK_PATH="$candidate"
        break
    fi
done
if [ -z "$SPARKLE_FRAMEWORK_PATH" ]; then
    SPARKLE_FRAMEWORK_PATH="$(find "$ROOT/.build" -name "Sparkle.framework" -type d -not -path '*/checkouts/*' | head -n1 || true)"
fi
if [ -z "$SPARKLE_FRAMEWORK_PATH" ]; then
    echo "Sparkle.framework not found under .build — make sure swift build resolved Sparkle." >&2
    exit 1
fi

mkdir -p "$CONTENTS_DIR/Frameworks"
rm -rf "$CONTENTS_DIR/Frameworks/Sparkle.framework"
cp -R "$SPARKLE_FRAMEWORK_PATH" "$CONTENTS_DIR/Frameworks/Sparkle.framework"

xattr -cr "$APP_DIR"
PACKAGED_PYTHON="$XPC_RESOURCES/Runtime/python/cpython-3.12.11-macos-aarch64-none/bin/python3.12"
PYTHON_ENTITLEMENTS="$ROOT/.build/tool-worker-python-entitlements.plist"
if [ "$SIGN_IDENTITY" = "-" ]; then
    /usr/bin/jq -n '{
        "com.apple.security.app-sandbox": true,
        "com.apple.security.cs.disable-library-validation": true,
        "com.apple.security.inherit": true
    }' |
        /usr/bin/plutil -convert xml1 -o "$PYTHON_ENTITLEMENTS" -
else
    /usr/bin/jq -n '{
        "com.apple.security.app-sandbox": true,
        "com.apple.security.inherit": true
    }' |
        /usr/bin/plutil -convert xml1 -o "$PYTHON_ENTITLEMENTS" -
fi

# Sign every runtime Mach-O before sealing the worker and its XPC bundle.
# Sorting by path length signs the deepest files first.
while IFS= read -r runtime_file; do
    if [ "$runtime_file" != "$PACKAGED_PYTHON" ] &&
        /usr/bin/file -b "$runtime_file" | /usr/bin/grep -q '^Mach-O'; then
        codesign \
            --force \
            --sign "$SIGN_IDENTITY" \
            --options runtime \
            "$runtime_file"
    fi
done < <(
    find "$XPC_RESOURCES/Runtime" -type f -print |
        /usr/bin/awk '{ print length($0), $0 }' |
        /usr/bin/sort -rn |
        /usr/bin/cut -d' ' -f2-
)

codesign \
    --force \
    --sign "$SIGN_IDENTITY" \
    --options runtime \
    --entitlements "$PYTHON_ENTITLEMENTS" \
    "$PACKAGED_PYTHON"
PACKAGED_PYTHON_SHA="$(
    /usr/bin/shasum -a 256 "$PACKAGED_PYTHON" |
        /usr/bin/awk '{print $1}'
)"
PACKAGED_MANIFEST="$XPC_RESOURCES/Runtime/runtime.json"
/usr/bin/jq -cS \
    --arg pythonSHA256 "$PACKAGED_PYTHON_SHA" \
    '.pythonSHA256 = $pythonSHA256' \
    "$PACKAGED_MANIFEST" >"$PACKAGED_MANIFEST.tmp"
mv "$PACKAGED_MANIFEST.tmp" "$PACKAGED_MANIFEST"

while IFS= read -r runtime_file; do
    if /usr/bin/file -b "$runtime_file" | /usr/bin/grep -q '^Mach-O'; then
        codesign \
            --force \
            --sign "$SIGN_IDENTITY" \
            --options runtime \
            "$runtime_file"
    fi
done < <(
    find "$TOOL_AGENT_RESOURCES/node_modules" -type f \
        \( -name '*.node' -o -name '*.dylib' -o -name '*.so' \) -print |
        /usr/bin/awk '{ print length($0), $0 }' |
        /usr/bin/sort -rn |
        /usr/bin/cut -d' ' -f2-
)
if [ "$SIGN_IDENTITY" = "-" ]; then
    NODE_ENTITLEMENTS="$ROOT/.build/tool-agent-node-entitlements.plist"
    /usr/bin/jq -n '{
        "com.apple.security.cs.allow-jit": true,
        "com.apple.security.cs.disable-library-validation": true
    }' |
        /usr/bin/plutil -convert xml1 -o "$NODE_ENTITLEMENTS" -
    codesign \
        --force \
        --sign "$SIGN_IDENTITY" \
        --options runtime \
        --entitlements "$NODE_ENTITLEMENTS" \
        "$PACKAGED_NODE"
else
    NODE_ENTITLEMENTS="$ROOT/.build/tool-agent-node-entitlements.plist"
    /usr/bin/jq -n '{
        "com.apple.security.cs.allow-jit": true
    }' |
        /usr/bin/plutil -convert xml1 -o "$NODE_ENTITLEMENTS" -
    codesign \
        --force \
        --sign "$SIGN_IDENTITY" \
        --options runtime \
        --entitlements "$NODE_ENTITLEMENTS" \
        "$PACKAGED_NODE"
fi
PACKAGED_NODE_SHA="$(
    /usr/bin/shasum -a 256 "$PACKAGED_NODE" |
        /usr/bin/awk '{print $1}'
)"
TOOL_AGENT_MANIFEST="$TOOL_AGENT_RESOURCES/runtime.json"
/usr/bin/jq -cS \
    --arg nodeSHA256 "$PACKAGED_NODE_SHA" \
    '.nodeSHA256 = $nodeSHA256' \
    "$TOOL_AGENT_MANIFEST" >"$TOOL_AGENT_MANIFEST.tmp"
mv "$TOOL_AGENT_MANIFEST.tmp" "$TOOL_AGENT_MANIFEST"

codesign \
    --force \
    --sign "$SIGN_IDENTITY" \
    --options runtime \
    "$XPC_MACOS/GizmateToolWorker"
codesign \
    --force \
    --sign "$SIGN_IDENTITY" \
    --options runtime \
    --entitlements "$ROOT/Resources/GizmateToolWorker.entitlements" \
    "$XPC_DIR"

XPC_ENTITLEMENTS="$ROOT/.build/tool-worker-xpc-entitlements.plist"
codesign -d --entitlements :- "$XPC_DIR" >"$XPC_ENTITLEMENTS" 2>/dev/null
if ! /usr/bin/plutil -convert json -o - "$XPC_ENTITLEMENTS" |
    /usr/bin/jq -e '
        keys == ["com.apple.security.app-sandbox"] and
        .["com.apple.security.app-sandbox"] == true
    ' >/dev/null; then
    echo "Packaged tool worker entitlements are not App Sandbox-only." >&2
    exit 1
fi

# Sign each Sparkle component explicitly with --options runtime so the whole
# load chain (XPC services → framework → app) shares the same hardened-runtime
# flags. Mixed runtime/non-runtime signatures make dyld reject the framework
# with "different Team IDs" on launch. Order matters: deepest first.
SPARKLE_VERSIONS_B="$CONTENTS_DIR/Frameworks/Sparkle.framework/Versions/B"
for component in \
    "$SPARKLE_VERSIONS_B/XPCServices/Downloader.xpc" \
    "$SPARKLE_VERSIONS_B/XPCServices/Installer.xpc" \
    "$SPARKLE_VERSIONS_B/Updater.app" \
    "$SPARKLE_VERSIONS_B/Autoupdate"; do
    if [ -e "$component" ]; then
        codesign --force --sign "$SIGN_IDENTITY" --options runtime "$component"
    fi
done
codesign --force --sign "$SIGN_IDENTITY" --options runtime "$CONTENTS_DIR/Frameworks/Sparkle.framework"

# The designated requirement stays pinned to the pre-rename identifier
# com.nugumi.app so accessibility / screen-recording grants survive rebuilds.
# Must stay in sync with CFBundleIdentifier in Resources/Info.plist.
codesign \
    --force \
    --sign "$SIGN_IDENTITY" \
    --options runtime \
    --entitlements "$ROOT/Resources/Gizmate.entitlements" \
    --requirements '=designated => identifier "com.nugumi.app"' \
    "$APP_DIR"

xattr -cr "$APP_DIR"
/usr/bin/codesign --verify --deep --strict --verbose=4 "$APP_DIR"

# Notarize and staple the .app *before* it is dropped into the DMG. That way
# the DMG's contents already carry the notarization ticket so Gatekeeper can
# verify offline.
if [ -n "$NOTARIZE_PROFILE" ]; then
    NOTARIZE_ZIP="$ROOT/.build/Gizmate-notarize.zip"
    rm -f "$NOTARIZE_ZIP"
    /usr/bin/ditto -c -k --keepParent "$APP_DIR" "$NOTARIZE_ZIP"
    echo "Submitting Gizmate.app to Apple notary…"
    xcrun notarytool submit "$NOTARIZE_ZIP" \
        --keychain-profile "$NOTARIZE_PROFILE" \
        --wait
    echo "Stapling notarization ticket to Gizmate.app…"
    xcrun stapler staple "$APP_DIR"
    rm -f "$NOTARIZE_ZIP"
fi

echo "Built $APP_DIR"

if [ "${SKIP_DMG:-0}" = "1" ]; then
    exit 0
fi

# --- Styled DMG packaging ---

# Detach only leftover Gizmate DMG mounts so we land at /Volumes/Gizmate exactly.
# Preserve spaces in mount paths and avoid detaching unrelated volumes whose
# path merely contains the word "Gizmate".
/sbin/mount | /usr/bin/awk -F' on ' '{sub(/ \(.*$/, "", $2); print $2}' |
while IFS= read -r stale; do
    case "$stale" in
        /Volumes/Gizmate|/Volumes/Gizmate\ [0-9]*)
            /usr/bin/hdiutil detach "$stale" -force >/dev/null 2>&1 || true
            ;;
    esac
done

rm -rf "$DMG_STAGE" "$DMG_PATH" "$DMG_RW_PATH"
mkdir -p "$DMG_STAGE/.background"
cp "$DMG_BG_PATH" "$DMG_STAGE/.background/dmg-background.png"
cp -R "$APP_DIR" "$DMG_STAGE/Gizmate.app"

# Pre-size the DMG with some headroom over the staged content.
STAGE_SIZE_KB="$(/usr/bin/du -sk "$DMG_STAGE" | awk '{print $1}')"
DMG_SIZE_MB=$(( STAGE_SIZE_KB / 1024 * 5 / 4 + 64 ))

/usr/bin/hdiutil create \
    -volname "Gizmate" \
    -srcfolder "$DMG_STAGE" \
    -ov \
    -fs HFS+ \
    -format UDRW \
    -size "${DMG_SIZE_MB}m" \
    "$DMG_RW_PATH" >/dev/null

ATTACH_OUTPUT="$(/usr/bin/hdiutil attach "$DMG_RW_PATH" -nobrowse -noautoopen -readwrite)"
MOUNT_DEVICE="$(echo "$ATTACH_OUTPUT" | awk '/^\/dev\// {print $1; exit}')"
MOUNT_POINT="$(echo "$ATTACH_OUTPUT" | awk -F'\t' '/Apple_HFS/ {print $NF; exit}')"
if [ -z "$MOUNT_POINT" ]; then
    MOUNT_POINT="/Volumes/Gizmate"
fi
echo "Mounted at $MOUNT_POINT"

# Hide the .background folder using all available mechanisms so Finder ignores it.
/usr/bin/chflags hidden "$MOUNT_POINT/.background" || true
SETFILE_BIN="$(/usr/bin/xcrun -f SetFile 2>/dev/null || true)"
if [ -n "$SETFILE_BIN" ] && [ -x "$SETFILE_BIN" ]; then
    "$SETFILE_BIN" -a V "$MOUNT_POINT/.background" || true
fi

sleep 1

osascript <<APPLESCRIPT
tell application "Finder"
    set volumeFolder to POSIX file "$MOUNT_POINT"
    set applicationsFolder to POSIX file "/Applications"
    try
        delete item "Applications" of volumeFolder
    end try
    make new alias file at volumeFolder to applicationsFolder with properties {name:"Applications"}
    tell disk "Gizmate"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {400, 100, 940, 512}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 104
        set text size of theViewOptions to 12
        set background picture of theViewOptions to file ".background:dmg-background.png"
        set position of item "Gizmate.app" of container window to {145, 176}
        set position of item "Applications" of container window to {395, 176}
        try
            set position of item ".background" of container window to {2000, 2000}
        end try
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

sync
sleep 1

# Detach with retries — Finder sometimes still holds the volume briefly.
for attempt in 1 2 3 4 5; do
    if /usr/bin/hdiutil detach "$MOUNT_POINT" -quiet; then
        break
    fi
    if [ "$attempt" -eq 5 ]; then
        /usr/bin/hdiutil detach "$MOUNT_POINT" -force
    else
        sleep 2
    fi
done

/usr/bin/hdiutil convert "$DMG_RW_PATH" \
    -format UDZO \
    -imagekey zlib-level=9 \
    -ov \
    -o "$DMG_PATH" >/dev/null
rm -f "$DMG_RW_PATH"
rm -rf "$DMG_STAGE"

# Sign + notarize + staple the DMG itself when a Developer ID is provided.
# Stapling the DMG lets Gatekeeper verify the download offline before mount.
if [ -n "$DEVELOPER_ID" ]; then
    codesign --force --sign "$SIGN_IDENTITY" "$DMG_PATH"
fi
if [ -n "$NOTARIZE_PROFILE" ]; then
    echo "Submitting DMG to Apple notary…"
    xcrun notarytool submit "$DMG_PATH" \
        --keychain-profile "$NOTARIZE_PROFILE" \
        --wait
    echo "Stapling notarization ticket to DMG…"
    xcrun stapler staple "$DMG_PATH"
fi

echo "Packaged $DMG_PATH"

ARCHS_OUT="$(/usr/bin/lipo -archs "$MACOS_DIR/Gizmate" 2>/dev/null || echo unknown)"
DMG_SIZE="$(/usr/bin/du -h "$DMG_PATH" | cut -f1)"
echo "Architectures: $ARCHS_OUT"
echo "DMG size: $DMG_SIZE"
if [ -n "$DEVELOPER_ID" ]; then
    echo "Signed by: $DEVELOPER_ID"
fi
if [ -n "$NOTARIZE_PROFILE" ]; then
    echo "Notarized + stapled."
fi
