#!/usr/bin/env bash
# Runs the tool-generation validation set against the model configured for text
# actions, and prints where the report landed.
#
#   Scripts/tool-eval.sh                    # every case
#   Scripts/tool-eval.sh download           # only cases whose name contains it
#
# Each case is a real request through the real agent, so a full run costs real
# tokens and several minutes. The JSON report holds every candidate the model
# wrote and the diagnostic it got back — read that, not just the pass/fail line.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT="${TOOL_EVAL_REPORT:-$ROOT/.build/tool-eval/report.json}"
mkdir -p "$(dirname "$REPORT")"

ARGS=(--tool-eval --report "$REPORT")
if [ "$#" -gt 0 ]; then
    ARGS+=(--case "$1")
fi

# The sidecar is loaded from ToolAgent/dist, so a stale build silently tests the
# wrong agent.
(cd "$ROOT/ToolAgent" && npx tsc -p tsconfig.json)

cd "$ROOT"
swift run Gizmate "${ARGS[@]}"
