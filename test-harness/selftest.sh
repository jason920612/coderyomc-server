#!/usr/bin/env bash
#
# coderyoMC e2e-harness self-test (issue #5)
# ---------------------------------------------------------------------------
# Proves the harness end-to-end against the REAL createPaperclipJar output on
# port 15565 with a trivial scenario:
#   boot -> /forceload add 0 0 -> assert `Done (` present -> stop.
# No mocks. Exits non-zero if the harness self-test fails.
#
# Usage:
#   ./selftest.sh [path-to-paperclip.jar]
#
# If no jar path is given, it auto-discovers the newest
#   coderyo-server/build/libs/*paperclip*.jar  (createPaperclipJar output)
# relative to the repo root (this script's ../).
# ---------------------------------------------------------------------------
set -u
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/.." && pwd)"
HARNESS="$HERE/e2e-harness.sh"

JAR="${1:-}"
if [ -z "$JAR" ]; then
  JAR="$(ls -t "$REPO_ROOT"/coderyo-server/build/libs/*paperclip*.jar 2>/dev/null | head -1 || true)"
fi

if [ -z "$JAR" ] || [ ! -f "$JAR" ]; then
  echo "[selftest][FATAL] no paperclip jar found." >&2
  echo "  Build it first:  ./gradlew applyAllPatches && ./gradlew createPaperclipJar" >&2
  echo "  Or pass an explicit jar path:  ./selftest.sh /path/to/coderyo-paperclip-*.jar" >&2
  exit 4
fi

echo "[selftest] using jar: $JAR"
echo "[selftest] scenario: boot -> /forceload add 0 0 -> assert 'Done (' -> stop"
echo "[selftest] port: 15565 (offset 0)"
echo ""

RUN_DIR="$REPO_ROOT/run-e2e-selftest"

bash "$HARNESS" \
  --jar "$JAR" \
  --port-offset 0 \
  --run-dir "$RUN_DIR" \
  --heap 2048 \
  --cmd "forceload add 0 0" \
  --assert-present 'Done \(' \
  --assert-absent 'Failed to bind to port' \
  --boot-timeout 300 \
  --stop-timeout 120 \
  --cmd-delay 2

rc=$?
echo ""
if [ "$rc" -eq 0 ]; then
  echo "[selftest] SELFTEST_PASS (harness exited 0)"
else
  echo "[selftest] SELFTEST_FAIL (harness exited $rc)"
fi
exit "$rc"
