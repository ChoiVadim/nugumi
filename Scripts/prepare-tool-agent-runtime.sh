#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/ToolAgent"
RUNTIME_ROOT="$ROOT/.build/tool-agent-runtime/arm64"
CACHE_ROOT="$ROOT/.build/tool-agent-downloads"
NODE_VERSION_REQUIRED="22.19.0"
PNPM_VERSION_REQUIRED="11.17.0"
NODE_ARCHIVE="node-v$NODE_VERSION_REQUIRED-darwin-arm64.tar.gz"
NODE_ARCHIVE_SHA256_REQUIRED="c59006db713c770d6ec63ae16cb3edc11f49ee093b5c415d667bb4f436c6526d"
NODE_SIGNING_FINGERPRINT="5BE8A3F6C8A5C01D106C0AD820B1A390B168D356"
NODE_RELEASE_URL="https://nodejs.org/dist/v$NODE_VERSION_REQUIRED"

fail() {
    echo "tool agent runtime: $*" >&2
    exit 1
}

[ "$(/usr/bin/uname -m)" = "arm64" ] ||
    fail "only the arm64 runtime is currently proven"
for command in curl gpg jq rsync shasum tar; do
    command -v "$command" >/dev/null ||
        fail "$command is required"
done
for file in package.json pnpm-lock.yaml pnpm-workspace.yaml; do
    [ -f "$SOURCE/$file" ] || fail "ToolAgent/$file is missing"
done

mkdir -p "$ROOT/.build" "$CACHE_ROOT"
WORK_ROOT="$(/usr/bin/mktemp -d "$ROOT/.build/tool-agent-runtime.XXXXXX")"
trap '/bin/rm -rf "$WORK_ROOT"' EXIT
GPG_HOME="$WORK_ROOT/gnupg"
BUILD_SOURCE="$WORK_ROOT/source"
DEPLOY_ROOT="$WORK_ROOT/deploy"
STAGED_RUNTIME="$WORK_ROOT/runtime"
mkdir -p "$GPG_HOME" "$BUILD_SOURCE" "$STAGED_RUNTIME"
chmod 700 "$GPG_HOME"

download() {
    local url="$1"
    local destination="$2"
    if [ ! -s "$destination" ]; then
        /usr/bin/curl \
            --fail \
            --location \
            --silent \
            --show-error \
            --output "$WORK_ROOT/download" \
            "$url"
        mv "$WORK_ROOT/download" "$destination"
    fi
}

NODE_ARCHIVE_PATH="$CACHE_ROOT/$NODE_ARCHIVE"
SHASUMS_SIGNATURE_PATH="$CACHE_ROOT/SHASUMS256-v$NODE_VERSION_REQUIRED.txt.asc"
SIGNING_KEY_PATH="$CACHE_ROOT/$NODE_SIGNING_FINGERPRINT.asc"
download "$NODE_RELEASE_URL/$NODE_ARCHIVE" "$NODE_ARCHIVE_PATH"
download "$NODE_RELEASE_URL/SHASUMS256.txt.asc" "$SHASUMS_SIGNATURE_PATH"
download \
    "https://keys.openpgp.org/vks/v1/by-fingerprint/$NODE_SIGNING_FINGERPRINT" \
    "$SIGNING_KEY_PATH"

GPG_EXECUTABLE="$(command -v gpg)"
"$GPG_EXECUTABLE" \
    --homedir "$GPG_HOME" \
    --batch \
    --quiet \
    --import "$SIGNING_KEY_PATH"
IMPORTED_FINGERPRINT="$(
    "$GPG_EXECUTABLE" \
        --homedir "$GPG_HOME" \
        --batch \
        --with-colons \
        --list-keys |
        /usr/bin/awk -F: '
            $1 == "pub" { wantFingerprint = 1; next }
            wantFingerprint && $1 == "fpr" { print $10; exit }
        '
)"
[ "$IMPORTED_FINGERPRINT" = "$NODE_SIGNING_FINGERPRINT" ] ||
    fail "Node signing key fingerprint does not match the pinned fingerprint"

GPG_STATUS="$WORK_ROOT/gpg-status"
"$GPG_EXECUTABLE" \
    --homedir "$GPG_HOME" \
    --batch \
    --status-fd 1 \
    --verify "$SHASUMS_SIGNATURE_PATH" \
    >"$GPG_STATUS"
VALID_SIGNATURES="$(
    /usr/bin/awk \
        -v fingerprint="$NODE_SIGNING_FINGERPRINT" \
        '$1 == "[GNUPG:]" && $2 == "VALIDSIG" &&
         ($3 == fingerprint || $12 == fingerprint) { count += 1 }
         END { print count + 0 }' \
        "$GPG_STATUS"
)"
[ "$VALID_SIGNATURES" = "1" ] ||
    fail "SHASUMS256.txt.asc was not signed by the pinned Node signing key"
VERIFIED_SHASUMS_PATH="$WORK_ROOT/SHASUMS256.txt"
"$GPG_EXECUTABLE" \
    --homedir "$GPG_HOME" \
    --batch \
    --quiet \
    --output "$VERIFIED_SHASUMS_PATH" \
    --decrypt "$SHASUMS_SIGNATURE_PATH"

SIGNED_ARCHIVE_SHA256="$(
    /usr/bin/awk -v archive="$NODE_ARCHIVE" \
        '$2 == archive { print $1 }' "$VERIFIED_SHASUMS_PATH"
)"
[ "$SIGNED_ARCHIVE_SHA256" = "$NODE_ARCHIVE_SHA256_REQUIRED" ] ||
    fail "signed Node archive digest does not match the pinned digest"
NODE_ARCHIVE_SHA256="$(
    /usr/bin/shasum -a 256 "$NODE_ARCHIVE_PATH" |
        /usr/bin/awk '{print $1}'
)"
[ "$NODE_ARCHIVE_SHA256" = "$NODE_ARCHIVE_SHA256_REQUIRED" ] ||
    fail "downloaded Node archive digest does not match the pinned digest"

/usr/bin/tar -xzf "$NODE_ARCHIVE_PATH" -C "$WORK_ROOT"
NODE_DISTRIBUTION="$WORK_ROOT/node-v$NODE_VERSION_REQUIRED-darwin-arm64"
NODE_EXECUTABLE="$NODE_DISTRIBUTION/bin/node"
[ -x "$NODE_EXECUTABLE" ] || fail "Node executable is missing from the archive"
NODE_VERSION="$("$NODE_EXECUTABLE" --version)"
NODE_VERSION="${NODE_VERSION#v}"
[ "$NODE_VERSION" = "$NODE_VERSION_REQUIRED" ] ||
    fail "Node $NODE_VERSION_REQUIRED is required, found $NODE_VERSION"
/usr/bin/file -b "$NODE_EXECUTABLE" | /usr/bin/grep -q 'Mach-O.*arm64' ||
    fail "Node executable is not an arm64 Mach-O"

/usr/bin/rsync -a \
    --exclude dist \
    --exclude node_modules \
    "$SOURCE/" "$BUILD_SOURCE/"

PACKAGE_MANAGER="$(
    /usr/bin/jq -er '.packageManager' "$BUILD_SOURCE/package.json"
)"
[ "$PACKAGE_MANAGER" = "pnpm@$PNPM_VERSION_REQUIRED" ] ||
    fail "ToolAgent packageManager must be pnpm@$PNPM_VERSION_REQUIRED"
PACKAGE_NODE_VERSION="$(
    /usr/bin/jq -er '.engines.node' "$BUILD_SOURCE/package.json"
)"
[ "$PACKAGE_NODE_VERSION" = "$NODE_VERSION_REQUIRED" ] ||
    fail "ToolAgent Node engine must be $NODE_VERSION_REQUIRED"

COREPACK_CLI="$NODE_DISTRIBUTION/lib/node_modules/corepack/dist/corepack.js"
[ -f "$COREPACK_CLI" ] || fail "Corepack is missing from the Node archive"
export COREPACK_HOME="$CACHE_ROOT/corepack"
export COREPACK_ENABLE_DOWNLOAD_PROMPT=0
export PATH="$NODE_DISTRIBUTION/bin:/usr/bin:/bin:/usr/sbin:/sbin"
PNPM_COMMAND=("$NODE_EXECUTABLE" "$COREPACK_CLI" pnpm)
PNPM_VERSION="$(
    cd "$BUILD_SOURCE"
    "${PNPM_COMMAND[@]}" --version
)"
[ "$PNPM_VERSION" = "$PNPM_VERSION_REQUIRED" ] ||
    fail "pnpm $PNPM_VERSION_REQUIRED is required, found $PNPM_VERSION"

(
    cd "$BUILD_SOURCE"
    "${PNPM_COMMAND[@]}" install --frozen-lockfile
    "${PNPM_COMMAND[@]}" run build
    "${PNPM_COMMAND[@]}" \
        --filter nugumi-tool-agent \
        deploy --prod --legacy "$DEPLOY_ROOT"
)

[ -d "$BUILD_SOURCE/dist" ] || fail "ToolAgent build did not emit dist"
[ -f "$BUILD_SOURCE/dist/agent.mjs" ] ||
    fail "ToolAgent build did not emit dist/agent.mjs"
[ -f "$BUILD_SOURCE/dist/gate.mjs" ] ||
    fail "ToolAgent build did not emit dist/gate.mjs"
# The agent-tool run sidecar. Without it a packaged build looks fine until
# someone presses an agent tool, which then reports the runtime as missing.
[ -f "$BUILD_SOURCE/dist/run.mjs" ] ||
    fail "ToolAgent build did not emit dist/run.mjs"
[ -d "$DEPLOY_ROOT/node_modules" ] ||
    fail "pnpm deploy did not emit production node_modules"

cp "$NODE_EXECUTABLE" "$STAGED_RUNTIME/node"
cp "$BUILD_SOURCE/package.json" "$STAGED_RUNTIME/package.json"
cp -R "$BUILD_SOURCE/dist" "$STAGED_RUNTIME/dist"
cp -R "$DEPLOY_ROOT/node_modules" "$STAGED_RUNTIME/node_modules"
chmod 755 "$STAGED_RUNTIME/node"

while IFS= read -r -d '' symlink; do
    case "$(/usr/bin/readlink "$symlink")" in
        /*) fail "absolute symlink rejected in packaged runtime" ;;
    esac
done < <(find "$STAGED_RUNTIME" -type l -print0)

NODE_SHA256="$(
    /usr/bin/shasum -a 256 "$STAGED_RUNTIME/node" |
        /usr/bin/awk '{print $1}'
)"
AGENT_SHA256="$(
    /usr/bin/shasum -a 256 "$STAGED_RUNTIME/dist/agent.mjs" |
        /usr/bin/awk '{print $1}'
)"
GATE_SHA256="$(
    /usr/bin/shasum -a 256 "$STAGED_RUNTIME/dist/gate.mjs" |
        /usr/bin/awk '{print $1}'
)"
RUN_SHA256="$(
    /usr/bin/shasum -a 256 "$STAGED_RUNTIME/dist/run.mjs" |
        /usr/bin/awk '{print $1}'
)"
PACKAGE_JSON_SHA256="$(
    /usr/bin/shasum -a 256 "$STAGED_RUNTIME/package.json" |
        /usr/bin/awk '{print $1}'
)"
PNPM_LOCK_SHA256="$(
    /usr/bin/shasum -a 256 "$BUILD_SOURCE/pnpm-lock.yaml" |
        /usr/bin/awk '{print $1}'
)"
PI_AI_VERSION="$(
    /usr/bin/jq -er '.dependencies["@earendil-works/pi-ai"]' \
        "$BUILD_SOURCE/package.json"
)"
PI_CODING_AGENT_VERSION="$(
    /usr/bin/jq -er '.dependencies["@earendil-works/pi-coding-agent"]' \
        "$BUILD_SOURCE/package.json"
)"

/usr/bin/jq -cnS \
    --arg agentSHA256 "$AGENT_SHA256" \
    --arg architecture arm64 \
    --arg gateSHA256 "$GATE_SHA256" \
    --arg nodeArchiveSHA256 "$NODE_ARCHIVE_SHA256" \
    --arg nodeSHA256 "$NODE_SHA256" \
    --arg nodeSigningFingerprint "$NODE_SIGNING_FINGERPRINT" \
    --arg nodeVersion "$NODE_VERSION" \
    --arg packageJSONSHA256 "$PACKAGE_JSON_SHA256" \
    --arg piAIVersion "$PI_AI_VERSION" \
    --arg piCodingAgentVersion "$PI_CODING_AGENT_VERSION" \
    --arg pnpmLockSHA256 "$PNPM_LOCK_SHA256" \
    --arg pnpmVersion "$PNPM_VERSION" \
    --arg runSHA256 "$RUN_SHA256" \
    '{
        agentSHA256: $agentSHA256,
        architecture: $architecture,
        gateSHA256: $gateSHA256,
        nodeArchiveSHA256: $nodeArchiveSHA256,
        nodeSHA256: $nodeSHA256,
        nodeSigningFingerprint: $nodeSigningFingerprint,
        nodeVersion: $nodeVersion,
        packageJSONSHA256: $packageJSONSHA256,
        piAIVersion: $piAIVersion,
        piCodingAgentVersion: $piCodingAgentVersion,
        pnpmLockSHA256: $pnpmLockSHA256,
        pnpmVersion: $pnpmVersion,
        runSHA256: $runSHA256
    }' >"$STAGED_RUNTIME/runtime.json"

/usr/bin/jq -e '
    keys == [
        "agentSHA256",
        "architecture",
        "gateSHA256",
        "nodeArchiveSHA256",
        "nodeSHA256",
        "nodeSigningFingerprint",
        "nodeVersion",
        "packageJSONSHA256",
        "piAIVersion",
        "piCodingAgentVersion",
        "pnpmLockSHA256",
        "pnpmVersion",
        "runSHA256"
    ] and
    all(.[]; type == "string") and
    all(.[]; test("^/") | not)
' "$STAGED_RUNTIME/runtime.json" >/dev/null ||
    fail "runtime.json is not sorted and path-safe"

/bin/rm -rf "$RUNTIME_ROOT"
mkdir -p "$(dirname "$RUNTIME_ROOT")"
mv "$STAGED_RUNTIME" "$RUNTIME_ROOT"
echo "prepared tool agent runtime: $RUNTIME_ROOT/runtime.json"
