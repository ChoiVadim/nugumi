#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNTIME_ROOT="$ROOT/.build/tool-worker-runtime/arm64"
PYTHON_INSTALL_DIR="$RUNTIME_ROOT/python"
SITE_PACKAGES="$RUNTIME_ROOT/site-packages"
MANIFEST="$RUNTIME_ROOT/runtime.json"
UV_VERSION_REQUIRED="0.11.26"
PYTHON_VERSION_REQUIRED="3.12.11"
DEPENDENCY_VERSION_REQUIRED="3.10"

fail() {
    echo "tool worker runtime: $*" >&2
    exit 1
}

[ "$(/usr/bin/uname -m)" = "arm64" ] ||
    fail "only the arm64 runtime is currently proven"

UV_EXECUTABLE="$(command -v uv || true)"
[ -n "$UV_EXECUTABLE" ] || fail "uv $UV_VERSION_REQUIRED is required"
UV_VERSION="$("$UV_EXECUTABLE" --version | /usr/bin/awk '{print $2}')"
[ "$UV_VERSION" = "$UV_VERSION_REQUIRED" ] ||
    fail "uv $UV_VERSION_REQUIRED is required, found $UV_VERSION"

mkdir -p "$RUNTIME_ROOT"
export UV_PYTHON_INSTALL_DIR="$PYTHON_INSTALL_DIR"
"$UV_EXECUTABLE" python install \
    "$PYTHON_VERSION_REQUIRED" \
    --no-bin \
    --no-progress
PYTHON_EXECUTABLE="$(
    "$UV_EXECUTABLE" python find \
        --managed-python \
        --resolve-links \
        "$PYTHON_VERSION_REQUIRED"
)"
PYTHON_MANAGED_ROOT="$(
    dirname "$(dirname "$(dirname "$PYTHON_EXECUTABLE")")"
)"
[ "$PYTHON_MANAGED_ROOT" -ef "$PYTHON_INSTALL_DIR" ] ||
    fail "uv resolved Python outside the managed runtime directory"
MANAGED_ALIAS="$PYTHON_INSTALL_DIR/cpython-3.12-macos-aarch64-none"
if [ -L "$MANAGED_ALIAS" ]; then
    unlink "$MANAGED_ALIAS"
fi

PYTHON_VERSION="$(
    "$PYTHON_EXECUTABLE" -I -c \
        'import platform; print(platform.python_version())'
)"
[ "$PYTHON_VERSION" = "$PYTHON_VERSION_REQUIRED" ] ||
    fail "Python $PYTHON_VERSION_REQUIRED is required, found $PYTHON_VERSION"

rm -rf "$SITE_PACKAGES"
mkdir -p "$SITE_PACKAGES"
"$UV_EXECUTABLE" pip install \
    "idna==$DEPENDENCY_VERSION_REQUIRED" \
    --no-build \
    --no-deps \
    --target "$SITE_PACKAGES" \
    --python "$PYTHON_EXECUTABLE" \
    --no-progress

DEPENDENCY_VERSION="$(
    "$PYTHON_EXECUTABLE" -I -c \
        'import sys; sys.path.insert(0, sys.argv[1]); import idna; print(idna.__version__)' \
        "$SITE_PACKAGES"
)"
[ "$DEPENDENCY_VERSION" = "$DEPENDENCY_VERSION_REQUIRED" ] ||
    fail "idna $DEPENDENCY_VERSION_REQUIRED is required, found $DEPENDENCY_VERSION"

METADATA="$SITE_PACKAGES/idna-$DEPENDENCY_VERSION_REQUIRED.dist-info/METADATA"
[ -f "$METADATA" ] || fail "idna wheel metadata is missing"
PYTHON_SHA256="$(
    /usr/bin/shasum -a 256 "$PYTHON_EXECUTABLE" |
        /usr/bin/awk '{print $1}'
)"
METADATA_SHA256="$(
    /usr/bin/shasum -a 256 "$METADATA" |
        /usr/bin/awk '{print $1}'
)"

/usr/bin/jq -cnS \
    --arg architecture arm64 \
    --arg uvVersion "$UV_VERSION" \
    --arg pythonVersion "$PYTHON_VERSION" \
    --arg pythonSHA256 "$PYTHON_SHA256" \
    --arg dependencyVersion "$DEPENDENCY_VERSION" \
    --arg dependencyMetadataSHA256 "$METADATA_SHA256" \
    '{
        architecture: $architecture,
        dependencyMetadataSHA256: $dependencyMetadataSHA256,
        dependencyVersion: $dependencyVersion,
        pythonSHA256: $pythonSHA256,
        pythonVersion: $pythonVersion,
        uvVersion: $uvVersion
    }' >"$MANIFEST"

echo "prepared tool worker runtime: $MANIFEST"
