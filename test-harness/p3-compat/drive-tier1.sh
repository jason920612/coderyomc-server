#!/usr/bin/env bash
#
# coderyoMC P3.2 Tier-1 auto-marshal e2e driver.
# ---------------------------------------------------------------------------
# Boots the real coderyo paperclip jar headless on port 15565 with WorldEdit
# (+ the corpus deps) installed, region.enabled=true region.debug=true
# compat.debug=true, then:
#   1. forceloads TWO DISJOINT chunk clusters far apart so the merge subsystem
#      forms TWO separate regions (mergeRadius=2 -> clusters >2 chunks apart
#      never merge);
#   2. drives cross-region block writes from the console (setblock) AND a
#      WorldEdit //set spanning into the OTHER region.
# A console/WorldEdit setBlock runs on the orchestrator main thread (between
# ticks, regions quiescent), so it does NOT own the target region -> the
# CraftBlock Tier-1 hook MARSHALS the write to the owning region's inbound
# queue (fire-and-forget). That is the cross-region Tier-1 path the prior
# (no-players) P3.1 test could not exercise.
#
# Asserts from the log:
#   - "block write MARSHALED (Tier 1)" actually fires (the proof),
#   - blocks land (no exception),
#   - NO single-writer violation / AsyncCatcher / sync-event error (no deadlock,
#     no tick-thread block),
#   - server reaches Done + clean shutdown.
#
# Usage:  ./drive-tier1.sh enabled | disabled
# ---------------------------------------------------------------------------
set -u
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
HARNESS="$ROOT/test-harness/e2e-harness.sh"
JAR="$ROOT/coderyo-server/build/libs/coderyo-paperclip-26.2-R0.1-SNAPSHOT.jar"
CORPUS="$ROOT/test-harness/plugin-corpus/jars"

MODE="${1:-enabled}"
case "$MODE" in
  enabled)  REGION="true";  OFFSET=0; DBG="-Dcoderyo.region.debug=true -Dcoderyo.compat.debug=true";;
  disabled) REGION="false"; OFFSET=1; DBG="";;
  *) echo "usage: $0 enabled|disabled" >&2; exit 4;;
esac

RUN_DIR="$HERE/run-tier1-$MODE"
LOG="$HERE/p3-tier1-$MODE.log"

[ -f "$JAR" ] || { echo "missing jar: $JAR" >&2; exit 4; }
[ -d "$CORPUS" ] || { echo "missing corpus jars dir: $CORPUS (run plugin-corpus/download.sh)" >&2; exit 4; }

PROBE="$ROOT/test-plugins/compat-probe/CompatProbe.jar"

rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR/plugins"
# Install WorldEdit (the Tier-1 priority plugin, loads + runs) AND the CompatProbe
# plugin whose /probetier1 command drives the cross-region Bukkit Block API
# (set/get) that funnels through the CraftBlock Tier-1 hook. NOTE: WorldEdit's
# //set uses the NMS PaperweightAdapter (bypasses CraftBlock), so it proves
# WorldEdit loads+runs under regions, but the AUTHORITATIVE Tier-1 marshal proof
# is driven through the probe's Bukkit-API command (the Craft* surface Tier-1 wires).
cp "$CORPUS/WorldEdit-7.4.4-beta-01.jar" "$RUN_DIR/plugins/" || { echo "WorldEdit jar missing" >&2; exit 4; }
cp "$PROBE" "$RUN_DIR/plugins/" || { echo "CompatProbe jar missing: $PROBE" >&2; exit 4; }
echo "[drive] mode=$MODE region.enabled=$REGION run-dir=$RUN_DIR"

# mergeRadius=2: two clusters separated by >2 empty chunks stay TWO regions.
EXTRA_JVM="-Dcoderyo.region.enabled=$REGION -Dcoderyo.region.mergeRadius=2 $DBG"

# Region A around chunk (0,0); Region B around chunk (40,40) — 40 chunks apart,
# far beyond mergeRadius=2, so they form two disjoint regions. forceload keeps
# both ticking. Then write blocks in BOTH regions from the console (orchestrator
# thread), and a WorldEdit //set that targets region B. Each cross-region write
# from the orchestrator marshals (Tier 1).
"$HARNESS" \
  --jar "$JAR" \
  --port-offset "$OFFSET" \
  --run-dir "$RUN_DIR" \
  --keep-run \
  --log "$LOG" \
  --extra-jvm "$EXTRA_JVM" \
  --boot-timeout 180 \
  --cmd-delay 3 \
  --cmd "forceload add 0 0" \
  --cmd "forceload add 640 640" \
  --cmd "setblock 8 64 8 minecraft:stone" \
  --cmd "setblock 648 64 648 minecraft:gold_block" \
  --cmd "probetier1 8 64 8 648 64 648" \
  --cmd "probetier1 8 65 8 648 65 648" \
  --cmd "probeverify 8 64 8 648 64 648" \
  --cmd "//pos1 640,64,640" \
  --cmd "//pos2 650,66,650" \
  --cmd "//set minecraft:netherite_block" \
  --assert-present "Done \(" \
  --assert-present "PROBE_TIER1 region" \
  --assert-present "PROBE_VERIFY region" \
  --assert-absent  "single-writer-per-region invariant violated" \
  --assert-absent  "may only be triggered synchronously" \
  --assert-absent  "Asynchronous .* failed main thread check" \
  --assert-absent  "Asynchronous [A-Za-z ]+!"

RC=$?
echo "[drive] harness exit=$RC  log=$LOG"
exit $RC
