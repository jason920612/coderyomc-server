#!/usr/bin/env bash
#
# coderyoMC P3.1 plugin-compat e2e driver.
# ---------------------------------------------------------------------------
# Boots the real coderyo paperclip jar headless on port 15565 with a minimal
# UNMODIFIED Bukkit test plugin (test-plugins/compat-probe/CompatProbe.jar)
# dropped into plugins/, drives a few console commands that exercise the
# compat-routed surfaces (block break, armor-stand summon), and asserts from
# the log that:
#   - the plugin loads + enables (PROBE_ENABLE),
#   - its event handlers RUN (PROBE_SERVERLOAD / PROBE_BLOCKBREAK / PROBE_ENTITYSPAWN),
#   - its repeating scheduled task RUNs and touches a world (PROBE_TASK),
#   - everything ran on a primary/tick thread (primary=true), no AsyncCatcher,
#     no "may only be triggered synchronously", no single-writer violation,
#   - server reaches Done and stops cleanly.
#
# Run for BOTH region.enabled=true (compat path) and region.enabled=false
# (vanilla baseline). Usage:
#   ./drive.sh enabled    -> region.enabled=true  compat.debug=true
#   ./drive.sh disabled   -> region.enabled=false (vanilla)
# ---------------------------------------------------------------------------
set -u
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
HARNESS="$ROOT/test-harness/e2e-harness.sh"
JAR="$ROOT/coderyo-server/build/libs/coderyo-paperclip-26.2-R0.1-SNAPSHOT.jar"
PLUGIN="$ROOT/test-plugins/compat-probe/CompatProbe.jar"

MODE="${1:-enabled}"
case "$MODE" in
  enabled)  REGION="true";  OFFSET=0; DBG="-Dcoderyo.region.debug=true -Dcoderyo.compat.debug=true";;
  disabled) REGION="false"; OFFSET=1; DBG="";;
  *) echo "usage: $0 enabled|disabled" >&2; exit 4;;
esac

RUN_DIR="$HERE/run-$MODE"
LOG="$HERE/p3-compat-$MODE.log"

[ -f "$JAR" ]    || { echo "missing jar: $JAR" >&2; exit 4; }
[ -f "$PLUGIN" ] || { echo "missing plugin jar: $PLUGIN" >&2; exit 4; }

# Fresh run dir with the plugin pre-installed (harness uses --keep-run so it
# will NOT wipe our plugins/ dir, but still writes fresh server.properties).
rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR/plugins"
cp "$PLUGIN" "$RUN_DIR/plugins/"
echo "[drive] mode=$MODE region.enabled=$REGION  run-dir=$RUN_DIR"

EXTRA_JVM="-Dcoderyo.region.enabled=$REGION -Dcoderyo.region.mergeRadius=2 $DBG"

# Region-on: forceload chunk 0,0 so a region forms over spawn; break a block and
# summon an armor stand in that region to trigger the block/entity event handlers.
"$HARNESS" \
  --jar "$JAR" \
  --port-offset "$OFFSET" \
  --run-dir "$RUN_DIR" \
  --keep-run \
  --log "$LOG" \
  --extra-jvm "$EXTRA_JVM" \
  --cmd-delay 2 \
  --cmd "forceload add 0 0" \
  --cmd "setblock 8 -60 8 minecraft:stone" \
  --cmd "summon minecraft:armor_stand 8 64 8" \
  --cmd "setblock 8 64 8 minecraft:dirt" \
  --cmd "execute as @e[type=armor_stand,limit=1] run kill @s" \
  --assert-present "PROBE_ENABLE onEnable" \
  --assert-present "PROBE_SERVERLOAD" \
  --assert-present "PROBE_TASK run#" \
  --assert-present "Done \(" \
  --assert-absent  "single-writer-per-region invariant violated" \
  --assert-absent  "may only be triggered synchronously" \
  --assert-absent  "Asynchronous .* failed main thread check" \
  --assert-absent  "Asynchronous [A-Za-z ]+!"

RC=$?
echo "[drive] harness exit=$RC  log=$LOG"
exit $RC
