#!/usr/bin/env bash
# Release helper for Gizmate.
#
# Usage: bash Scripts/release.sh <version>
#   version: semver string, e.g. 0.2.0
#
# What it does:
#   1. Updates CFBundleShortVersionString and CFBundleVersion in Info.plist.
#   2. Builds dist/Gizmate.app and dist/Gizmate.dmg via build-app-bundle.sh.
#   3. Calls Sparkle's sign_update to produce an EdDSA signature for the dmg.
#   4. Appends a new <item> to appcast.xml.
#   5. Prints next steps (commit, tag, push, GitHub Release upload).
#
# Prereqs (one-time):
#   - Generate Sparkle EdDSA keys:  /path/to/Sparkle/bin/generate_keys
#     The private key lives in your macOS Keychain.
#     Replace SUPublicEDKey in Resources/Info.plist with the printed public key.
#   - Make Sparkle's bin/sign_update available in PATH, OR set SPARKLE_BIN
#     to the directory that contains it (e.g. /opt/homebrew/Caskroom/sparkle).
#
# After this script:
#   - git add VERSION? appcast.xml Resources/Info.plist
#   - git commit -m "Release vX.Y.Z"
#   - git tag vX.Y.Z && git push --tags
#   - gh release create vX.Y.Z dist/Gizmate.dmg --title "vX.Y.Z" --notes "..."

set -euo pipefail

VERSION="${1:-}"
if [ -z "$VERSION" ]; then
    echo "usage: $0 <version>  (e.g. 0.2.0)" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="$ROOT/Resources/Info.plist"
APPCAST="$ROOT/appcast.xml"
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

# 4. Append item to appcast.xml.
DMG_FILENAME="Gizmate-$VERSION.dmg"
DMG_URL="$DMG_URL_BASE/v$VERSION/$DMG_FILENAME"
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
echo "Release v$VERSION prepared."
echo
echo "Next steps:"
echo "  git add Resources/Info.plist appcast.xml"
echo "  git commit -m \"Release v$VERSION\""
echo "  git tag v$VERSION && git push origin main --tags"
echo "  gh release create v$VERSION dist/$DMG_FILENAME --title \"v$VERSION\" --notes \"...\""
