#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/Gizmate.app"
MAIN_EXECUTABLE="$APP/Contents/MacOS/Gizmate"
HELPER="$APP/Contents/Resources/ToolAgent"
NODE="$APP/Contents/Helpers/ToolAgentNode"
AGENT_ENTRYPOINT="$HELPER/dist/agent.mjs"
GATE_ENTRYPOINT="$HELPER/dist/gate.mjs"
RUN_ENTRYPOINT="$HELPER/dist/run.mjs"
MANIFEST="$HELPER/runtime.json"
XPC="$APP/Contents/XPCServices/GizmateToolWorker.xpc"
WORKER_EXECUTABLE="$XPC/Contents/MacOS/GizmateToolWorker"
PYTHON_RUNTIME="$XPC/Contents/Resources/Runtime/python"
GATE_DIR="$ROOT/.build/pi-tool-agent-gate"
FIRST_REPORT="$GATE_DIR/report-first.json"
SECOND_REPORT="$GATE_DIR/report-second.json"
TOOLS_STORAGE="$HOME/Library/Application Support/Gizmate/Tools"
GIZMATE_SUPPORT="$HOME/Library/Application Support/Gizmate"
BAD_FINGERPRINT="304feb5fccc7394bb9bb2294ca65e7a1bad47c37faa0833f4fbdb41a955ca640"
REPAIRED_FINGERPRINT="3c28f8691996f4f67863d79f69a763d10f1d415446704feebb8fb5dcc5779667"

fail() {
    echo "pi tool agent gate: $*" >&2
    exit 1
}

require_value() {
    local file="$1"
    local expression="$2"
    local expected="$3"
    local actual
    actual="$(/usr/bin/jq -r "$expression" "$file")"
    [ "$actual" = "$expected" ] ||
        fail "$expression did not match the required value"
}

require_digest() {
    local file="$1"
    local expression="$2"
    local expected
    local actual
    expected="$(/usr/bin/jq -er "$expression" "$MANIFEST")"
    actual="$(/usr/bin/shasum -a 256 "$file" | /usr/bin/awk '{print $1}')"
    [ "$actual" = "$expected" ] ||
        fail "$expression does not match the embedded artifact"
}

snapshot_tools() {
    if [ -e "$TOOLS_STORAGE" ]; then
        /usr/bin/tar -cf - -C "$GIZMATE_SUPPORT" Tools 2>/dev/null |
            /usr/bin/shasum -a 256 |
            /usr/bin/awk '{print $1}'
    else
        echo absent
    fi
}

snapshot_ring_layout() {
    if /usr/bin/defaults read com.gizmate.app ringLayout >/dev/null 2>&1; then
        /usr/bin/defaults read com.gizmate.app ringLayout 2>/dev/null |
            /usr/bin/shasum -a 256 |
            /usr/bin/awk '{print $1}'
    else
        echo absent
    fi
}

validate_report() {
    local report="$1"
    /usr/bin/jq -e \
        --arg bad "$BAD_FINGERPRINT" \
        --arg repaired "$REPAIRED_FINGERPRINT" '
        (keys | sort) == [
            "attemptCount",
            "counters",
            "entrypoint",
            "finalCandidateID",
            "finalFingerprint",
            "finalState",
            "firstAttempt",
            "gatePassed",
            "modelRequestCount",
            "runID",
            "schemaVersion",
            "secondAttempt"
        ] and
        (.firstAttempt | keys | sort) == [
            "candidateID",
            "failure",
            "fingerprint",
            "outcome"
        ] and
        (.secondAttempt | keys | sort) == [
            "candidateID",
            "fingerprint",
            "outcome",
            "passingFingerprint"
        ] and
        (.counters | keys | sort) == [
            "modelTurns",
            "repairs",
            "toolCalls"
        ] and
        .schemaVersion == 1 and
        .gatePassed == true and
        .entrypoint == "gate.mjs" and
        .modelRequestCount == 0 and
        .attemptCount == 2 and
        .firstAttempt.outcome == "failed" and
        .firstAttempt.failure == "wrongOutput" and
        .firstAttempt.fingerprint == $bad and
        .secondAttempt.outcome == "passed" and
        .secondAttempt.fingerprint == $repaired and
        .secondAttempt.passingFingerprint == $repaired and
        .finalState == "candidateReady" and
        .finalCandidateID == .secondAttempt.candidateID and
        .finalFingerprint == $repaired and
        .firstAttempt.candidateID != .secondAttempt.candidateID and
        .counters == {"modelTurns": 0, "repairs": 1, "toolCalls": 6} and
        (.runID | test(
            "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$"
        )) and
        (.firstAttempt.candidateID | test(
            "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$"
        )) and
        (.secondAttempt.candidateID | test(
            "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-5][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$"
        ))
    ' "$report" >/dev/null ||
        fail "report schema or exact repair attestation is invalid"

    local compact
    local sorted
    compact="$(/bin/cat "$report")"
    sorted="$(/usr/bin/jq -cS . "$report")"
    [ "$compact" = "$sorted" ] ||
        fail "report is not canonical sorted JSON"
}

run_gate() {
    local report="$1"
    /bin/rm -f "$report"
    "$MAIN_EXECUTABLE" --pi-tool-agent-gate --report "$report" ||
        fail "packaged deterministic gate failed"
    [ -f "$report" ] || fail "packaged gate did not atomically publish a report"
    validate_report "$report"
}

assert_no_gate_processes() {
    local attempt
    for attempt in 1 2 3 4 5; do
        if ! /usr/bin/pgrep -f "$NODE" >/dev/null &&
            ! /usr/bin/pgrep -f "$WORKER_EXECUTABLE" >/dev/null &&
            ! /usr/bin/pgrep -f "$PYTHON_RUNTIME/.*/bin/python3.12" >/dev/null; then
            return
        fi
        /bin/sleep 1
    done
    fail "Node, XPC worker, or Python descendant survived the gate"
}

cd "$ROOT"
if [ "${SKIP_BUILD:-0}" != "1" ]; then
    UNIVERSAL=0 SKIP_DMG=1 "$ROOT/Scripts/build-app-bundle.sh"
fi
mkdir -p "$GATE_DIR"

[ -x "$MAIN_EXECUTABLE" ] || fail "packaged app executable is missing"
[ -x "$NODE" ] || fail "embedded Node executable is missing"
[ -f "$AGENT_ENTRYPOINT" ] || fail "live agent entrypoint is missing"
[ -f "$GATE_ENTRYPOINT" ] || fail "deterministic gate entrypoint is missing"
[ -f "$MANIFEST" ] || fail "tool agent runtime manifest is missing"
[ -f "$HELPER/package.json" ] || fail "tool agent package metadata is missing"
[ -d "$HELPER/node_modules" ] || fail "tool agent production dependencies are missing"
[ -x "$WORKER_EXECUTABLE" ] || fail "sandbox XPC worker is missing"

/usr/bin/codesign --verify --deep --strict --verbose=4 "$APP"
[ "$("$NODE" --version)" = "v22.19.0" ] ||
    fail "embedded Node version is not 22.19.0"
[ "$(/usr/bin/lipo -archs "$NODE")" = "arm64" ] ||
    fail "embedded Node is not arm64-only"

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
' "$MANIFEST" >/dev/null ||
    fail "runtime manifest schema exposes unexpected data"
require_value "$MANIFEST" '.architecture' arm64
require_value "$MANIFEST" '.nodeVersion' 22.19.0
require_value \
    "$MANIFEST" \
    '.nodeSigningFingerprint' \
    5BE8A3F6C8A5C01D106C0AD820B1A390B168D356
require_value "$MANIFEST" '.pnpmVersion' 11.17.0
require_value "$MANIFEST" '.piAIVersion' 0.82.1
require_value "$MANIFEST" '.piCodingAgentVersion' 0.82.1
require_value \
    "$MANIFEST" \
    '.nodeArchiveSHA256' \
    c59006db713c770d6ec63ae16cb3edc11f49ee093b5c415d667bb4f436c6526d
require_digest "$NODE" '.nodeSHA256'
require_digest "$AGENT_ENTRYPOINT" '.agentSHA256'
require_digest "$GATE_ENTRYPOINT" '.gateSHA256'
require_digest "$RUN_ENTRYPOINT" '.runSHA256'
require_digest "$HELPER/package.json" '.packageJSONSHA256'

SOURCE_LOCK_SHA="$(
    /usr/bin/shasum -a 256 "$ROOT/ToolAgent/pnpm-lock.yaml" |
        /usr/bin/awk '{print $1}'
)"
require_value "$MANIFEST" '.pnpmLockSHA256' "$SOURCE_LOCK_SHA"

while IFS= read -r -d '' symlink; do
    target="$(/usr/bin/readlink "$symlink")"
    case "$target" in
        /*) fail "packaged dependency contains an absolute symlink" ;;
    esac
    resolved="$(
        /usr/bin/python3 -c \
            'import os, sys; print(os.path.realpath(sys.argv[1]))' \
            "$symlink"
    )"
    case "$resolved" in
        "$HELPER"/*) ;;
        *) fail "packaged dependency symlink escapes the helper" ;;
    esac
done < <(find "$HELPER" -type l -print0)

TOOLS_BEFORE="$(snapshot_tools)"
RING_BEFORE="$(snapshot_ring_layout)"
run_gate "$FIRST_REPORT"
assert_no_gate_processes
run_gate "$SECOND_REPORT"
assert_no_gate_processes
TOOLS_AFTER="$(snapshot_tools)"
RING_AFTER="$(snapshot_ring_layout)"

[ "$TOOLS_BEFORE" = "$TOOLS_AFTER" ] ||
    fail "Tools storage changed during the deterministic gate"
[ "$RING_BEFORE" = "$RING_AFTER" ] ||
    fail "ringLayout defaults changed during the deterministic gate"

FIRST_RUN_ID="$(/usr/bin/jq -r '.runID' "$FIRST_REPORT")"
SECOND_RUN_ID="$(/usr/bin/jq -r '.runID' "$SECOND_REPORT")"
FIRST_CANDIDATE_ID="$(/usr/bin/jq -r '.finalCandidateID' "$FIRST_REPORT")"
SECOND_CANDIDATE_ID="$(/usr/bin/jq -r '.finalCandidateID' "$SECOND_REPORT")"
[ "$FIRST_RUN_ID" != "$SECOND_RUN_ID" ] ||
    fail "two packaged gates reused the same run ID"
[ "$FIRST_CANDIDATE_ID" != "$SECOND_CANDIDATE_ID" ] ||
    fail "two packaged gates reused the same candidate ID"

echo "pi tool agent gate passed"
