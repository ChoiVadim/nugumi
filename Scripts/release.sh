#!/usr/bin/env bash
# Release helper for Gizmate.
#
# Usage: UNIVERSAL=0 bash Scripts/release.sh <version>
#   version: semver string, e.g. 0.1.0
#
# UNIVERSAL=0 is mandatory for now: build-app-bundle.sh refuses a universal build
# until an x86_64 tool-worker runtime is proven, so the plain form only errors.
# The resulting DMG is arm64-only.
#
# What it does:
#   1. Updates CFBundleShortVersionString and CFBundleVersion in Info.plist.
#   2. Builds dist/Gizmate.app and dist/Gizmate.dmg via build-app-bundle.sh.
#   3. Calls Sparkle's sign_update to produce an EdDSA signature for the dmg.
#   4. Appends a new <item> to appcast-gizmate.xml.
#   5. Prints next steps (commit, tag, push, GitHub Release upload).
#
# Prereqs (one-time):
#   - Generate Sparkle EdDSA keys:  /path/to/Sparkle/bin/generate_keys
#     The private key lives in your macOS Keychain.
#     Replace SUPublicEDKey in Resources/Info.plist with the printed public key.
#   - Make Sparkle's bin/sign_update available in PATH, OR set SPARKLE_BIN
#     to the directory that contains it (e.g. /opt/homebrew/Caskroom/sparkle).
#
# After this script (it prints the same commands with the version filled in):
#   - git add appcast-gizmate.xml Resources/Info.plist
#   - git commit -m "Release Gizmate X.Y.Z"
#   - git tag gizmate-vX.Y.Z && git push --tags
#   - gh release create gizmate-vX.Y.Z dist/Gizmate-X.Y.Z.dmg --prerelease ...

set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "usage: $0 <version>  (e.g. 0.2.0)" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="$ROOT/Resources/Info.plist"
# appcast-gizmate.xml, not appcast.xml. The latter is the frozen com.nugumi.app
# feed that every installed Nugumi still polls daily; appending there would push
# a beta at users who never asked for one.
APPCAST="$ROOT/appcast-gizmate.xml"
DMG_PATH="$ROOT/dist/Gizmate.dmg"
DMG_URL_BASE="https://github.com/ChoiVadim/nugumi/releases/download"

# Find sign_update.
SIGN_UPDATE=""
if command -v sign_update >/dev/null 2>&1; then
    SIGN_UPDATE="$(command -v sign_update)"
elif [ -n "${SPARKLE_BIN:-}" ] && [ -x "$SPARKLE_BIN/sign_update" ]; then
    SIGN_UPDATE="$SPARKLE_BIN/sign_update"
else
    # Try Homebrew Cellar / common Sparkle locations.
    for candidate in \
        /opt/homebrew/Caskroom/sparkle/*/bin/sign_update \
        /usr/local/Caskroom/sparkle/*/bin/sign_update \
        "$ROOT/.build/checkouts/Sparkle/bin/sign_update"; do
        if [ -x "$candidate" ]; then
            SIGN_UPDATE="$candidate"
            break
        fi
    done
fi

if [ -z "$SIGN_UPDATE" ]; then
    echo "sign_update not found. Install Sparkle from https://github.com/sparkle-project/Sparkle/releases" >&2
    echo "and either add it to PATH or set SPARKLE_BIN to the directory containing sign_update." >&2
    exit 1
fi

# 1. Bump version in Info.plist.
echo "Updating Info.plist to version $VERSION"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
EXISTING_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$INFO_PLIST")"
NEW_BUILD=$((EXISTING_BUILD + 1))
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" "$INFO_PLIST"

# 2. Build .app + .dmg.
echo "Building .app and .dmg…"
bash "$ROOT/Scripts/build-app-bundle.sh"

if [ ! -f "$DMG_PATH" ]; then
    echo "Build did not produce $DMG_PATH" >&2
    exit 1
fi

# 3. Sign the dmg.
echo "Signing $DMG_PATH with EdDSA key…"
SIGN_OUTPUT="$("$SIGN_UPDATE" "$DMG_PATH")"
# sign_update prints a line like:
#   sparkle:edSignature="…" length="123456"
echo "$SIGN_OUTPUT"

# 4. Append item to the appcast.
#
# The tag is `gizmate-vX.Y.Z`, not `vX.Y.Z`, and that is not decoration. The
# Gizmate line restarts its numbering at 0.1.0 while v0.2.0 through v0.17.0 are
# already taken by Yaku and Nugumi releases that still exist and still serve
# DMGs. Without the prefix the *second* Gizmate release would collide with Yaku
# 0.2.0, and forcing it would overwrite a release people can still download.
DMG_FILENAME="Gizmate-$VERSION.dmg"
TAG="gizmate-v$VERSION"
DMG_URL="$DMG_URL_BASE/$TAG/$DMG_FILENAME"
PUB_DATE="$(date -u +"%a, %d %b %Y %H:%M:%S +0000")"

ITEM_BLOCK=$(cat <<EOF
        <item>
            <title>Version $VERSION</title>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:version>$NEW_BUILD</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
            <enclosure
                url="$DMG_URL"
                type="application/octet-stream"
                $SIGN_OUTPUT />
        </item>
EOF
)

# Insert before </channel>.
TMP_APPCAST="$ROOT/.build/appcast.tmp"
ITEM_BLOCK="$ITEM_BLOCK" perl -0pe 's#^[ \t]*</channel>#$ENV{ITEM_BLOCK}\n    </channel>#m' "$APPCAST" > "$TMP_APPCAST"
mv "$TMP_APPCAST" "$APPCAST"

# Rename the dmg so the GitHub Release URL matches.
mv "$DMG_PATH" "$ROOT/dist/$DMG_FILENAME"

echo
echo "Gizmate $VERSION prepared (build $NEW_BUILD, tag $TAG)."
echo
echo "Next steps:"
echo "  git add Resources/Info.plist appcast-gizmate.xml"
echo "  git commit -m \"Release Gizmate $VERSION\""
echo "  git tag $TAG && git push origin main --tags"
echo "  gh release create $TAG dist/$DMG_FILENAME --prerelease \\"
echo "      --title \"Gizmate $VERSION\" --notes \"...\""
echo
echo "--prerelease keeps /releases/latest resolving to the frozen Nugumi 0.17.0."
