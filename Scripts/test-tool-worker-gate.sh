#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/dist/Gizmate.app"
MAIN_EXECUTABLE="$APP/Contents/MacOS/Gizmate"
XPC="$APP/Contents/XPCServices/GizmateToolWorker.xpc"
WORKER_EXECUTABLE="$XPC/Contents/MacOS/GizmateToolWorker"
RUNTIME="$XPC/Contents/Resources/Runtime"
GATE_DIR="$ROOT/.build/tool-worker-gate"
FIRST_REPORT="$GATE_DIR/report-first.json"
REPORT="$GATE_DIR/report.json"
ENTITLEMENTS="$GATE_DIR/worker-entitlements.plist"
PYTHON_ENTITLEMENTS="$GATE_DIR/python-entitlements.plist"

fail() {
    echo "tool worker gate: $*" >&2
    exit 1
}

require_value() {
    local report="$1"
    local key="$2"
    local expected="$3"
    local actual
    actual="$(/usr/bin/jq -r "$key" "$report")"
    [ "$actual" = "$expected" ] ||
        fail "$key expected $expected, got $actual"
}

validate_report() {
    local report="$1"
    /usr/bin/jq -e '
        (keys | sort) == ["gatePassed", "result"] and
        (.result | keys | sort) == [
            "dependencyVersion",
            "hostReadDenied",
            "hostWriteDenied",
            "mediatedNetworkSucceeded",
            "pythonVersion",
            "rawNetworkDenied",
            "runID",
            "stderrBounded",
            "stdoutBounded",
            "timedOutProcessGroupTerminated",
            "workspaceWriteSucceeded"
        ]
    ' "$report" >/dev/null || fail "report schema exposes unexpected data"

    require_value "$report" '.gatePassed' true
    require_value "$report" '.result.pythonVersion' 3.12.11
    require_value "$report" '.result.dependencyVersion' 3.10
    require_value "$report" '.result.workspaceWriteSucceeded' true
    require_value "$report" '.result.hostReadDenied' true
    require_value "$report" '.result.hostWriteDenied' true
    require_value "$report" '.result.rawNetworkDenied' true
    require_value "$report" '.result.mediatedNetworkSucceeded' true
    require_value "$report" '.result.stdoutBounded' true
    require_value "$report" '.result.stderrBounded' true
    require_value "$report" '.result.timedOutProcessGroupTerminated' true
}

run_probe() {
    local report="$1"
    rm -f "$report"
    if ! "$MAIN_EXECUTABLE" --tool-worker-probe --report "$report"; then
        [ ! -f "$report" ] || /bin/cat "$report" >&2
        fail "packaged probe failed"
    fi
    [ -f "$report" ] || fail "packaged probe did not write $report"
    validate_report "$report"
}

assert_no_probe_processes() {
    local attempt
    for attempt in 1 2 3 4 5; do
        if ! /usr/bin/pgrep -f "$WORKER_EXECUTABLE" >/dev/null &&
            ! /usr/bin/pgrep -f "$RUNTIME/python/.*/bin/python3.12" >/dev/null; then
            return
        fi
        /bin/sleep 1
    done
    fail "packaged worker or Python descendant survived the probe"
}

cd "$ROOT"
UNIVERSAL=0 "$ROOT/Scripts/build-app-bundle.sh"
mkdir -p "$GATE_DIR"

[ -x "$WORKER_EXECUTABLE" ] || fail "XPC worker executable is not embedded"
[ -f "$RUNTIME/runtime.json" ] || fail "runtime manifest is not embedded"
[ -d "$RUNTIME/site-packages/idna-3.10.dist-info" ] ||
    fail "idna 3.10 metadata is not embedded"

/usr/bin/codesign --verify --deep --strict --verbose=4 "$APP"

ARCHITECTURES="$(/usr/bin/lipo -archs "$WORKER_EXECUTABLE")"
[ "$ARCHITECTURES" = "arm64" ] ||
    fail "worker architectures expected arm64, got $ARCHITECTURES"

/usr/bin/codesign -d --entitlements :- "$XPC" >"$ENTITLEMENTS" 2>/dev/null
/usr/bin/plutil -lint "$ENTITLEMENTS" >/dev/null
/usr/bin/plutil -convert json -o - "$ENTITLEMENTS" |
    /usr/bin/jq -e '
        keys == ["com.apple.security.app-sandbox"] and
        .["com.apple.security.app-sandbox"] == true
    ' >/dev/null || fail "XPC entitlements are not App Sandbox-only"

MANIFEST="$RUNTIME/runtime.json"
PACKAGED_PYTHON="$RUNTIME/python/cpython-3.12.11-macos-aarch64-none/bin/python3.12"
/usr/bin/codesign -d --entitlements :- "$PACKAGED_PYTHON" \
    >"$PYTHON_ENTITLEMENTS" 2>/dev/null
/usr/bin/plutil -lint "$PYTHON_ENTITLEMENTS" >/dev/null
/usr/bin/plutil -convert json -o - "$PYTHON_ENTITLEMENTS" |
    /usr/bin/jq -e '
        (keys | sort) == [
            "com.apple.security.app-sandbox",
            "com.apple.security.cs.disable-library-validation",
            "com.apple.security.inherit"
        ] and
        .["com.apple.security.app-sandbox"] == true and
        .["com.apple.security.cs.disable-library-validation"] == true and
        .["com.apple.security.inherit"] == true
    ' >/dev/null || fail "ad-hoc Python child entitlements are not exact"

require_value "$MANIFEST" '.architecture' arm64
require_value "$MANIFEST" '.uvVersion' 0.11.26
require_value "$MANIFEST" '.pythonVersion' 3.12.11
require_value "$MANIFEST" '.dependencyVersion' 3.10

EXPECTED_PYTHON_SHA="$(/usr/bin/jq -r '.pythonSHA256' "$MANIFEST")"
ACTUAL_PYTHON_SHA="$(/usr/bin/shasum -a 256 \
    "$PACKAGED_PYTHON" |
    /usr/bin/awk '{print $1}')"
[ "$ACTUAL_PYTHON_SHA" = "$EXPECTED_PYTHON_SHA" ] ||
    fail "embedded Python hash does not match runtime.json"

EXPECTED_METADATA_SHA="$(/usr/bin/jq -r '.dependencyMetadataSHA256' "$MANIFEST")"
ACTUAL_METADATA_SHA="$(/usr/bin/shasum -a 256 \
    "$RUNTIME/site-packages/idna-3.10.dist-info/METADATA" |
    /usr/bin/awk '{print $1}')"
[ "$ACTUAL_METADATA_SHA" = "$EXPECTED_METADATA_SHA" ] ||
    fail "embedded idna metadata hash does not match runtime.json"

run_probe "$FIRST_REPORT"
assert_no_probe_processes
run_probe "$REPORT"
assert_no_probe_processes

FIRST_RUN_ID="$(/usr/bin/jq -r '.result.runID' "$FIRST_REPORT")"
SECOND_RUN_ID="$(/usr/bin/jq -r '.result.runID' "$REPORT")"
[ -n "$FIRST_RUN_ID" ] && [ "$FIRST_RUN_ID" != "$SECOND_RUN_ID" ] ||
    fail "two packaged probes reused the same runID"

echo "tool worker gate passed: $REPORT"
