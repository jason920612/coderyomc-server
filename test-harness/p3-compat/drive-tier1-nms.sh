#!/usr/bin/env bash
#
# coderyoMC P3.3 Tier-1 NMS-setBlock auto-marshal e2e driver.
# ---------------------------------------------------------------------------
# Builds on the P3.2 driver (drive-tier1.sh). The GAP P3.2 left: WorldEdit's
# //set, vanilla /setblock and /fill, and most NMS-level plugin edits call
# net.minecraft.world.level.Level.setBlock(...) DIRECTLY, bypassing CraftBlock,
# so the P3.2 CraftBlock hook never marshaled them. P3.3 hooks the NMS setBlock
# funnel itself.
#
# This driver forceloads TWO DISJOINT regions (A = chunk 0,0; B = chunk 40,40,
# 40 chunks apart, mergeRadius=2 -> two separate regions), then drives
# CROSS-REGION writes through the NMS path ONLY (no Bukkit-API probe writes):
#   - vanilla  /setblock  into region B (and A)
#   - vanilla  /fill      spanning region B
#   - WorldEdit //set     into region B  (PaperweightAdapter -> NMS setBlock)
# All of these run on the orchestrator main thread ("Server thread"), OUTSIDE
# level.tick() (command dispatch) -> coderyoNmsExternalWriteContext()==true ->
# they target a region the Server thread does NOT own -> the P3.3 NMS hook
# MARSHALS each write (Tier 1, fire-and-forget) to the owning region's inbound
# queue. /probeverify then re-reads (after the region drains) to prove the
# marshaled writes LANDED.
#
# Asserts:
#   - "block write MARSHALED (Tier 1)" fires for the NMS writes (the P3.3 proof),
#   - PROBE_VERIFY shows the blocks LANDED in BOTH regions,
#   - NO single-writer violation / AsyncCatcher / sync-event error (no deadlock,
#     no tick-thread block),
#   - server reaches Done + clean shutdown.
#
# Usage:  ./drive-tier1-nms.sh enabled | disabled
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

RUN_DIR="$HERE/run-tier1-nms-$MODE"
LOG="$HERE/p3-tier1-nms-$MODE.log"

[ -f "$JAR" ] || { echo "missing jar: $JAR" >&2; exit 4; }
[ -d "$CORPUS" ] || { echo "missing corpus jars dir: $CORPUS (run plugin-corpus/download.sh)" >&2; exit 4; }

PROBE="$ROOT/test-plugins/compat-probe/CompatProbe.jar"

rm -rf "$RUN_DIR"
mkdir -p "$RUN_DIR/plugins"
cp "$CORPUS/WorldEdit-7.4.4-beta-01.jar" "$RUN_DIR/plugins/" || { echo "WorldEdit jar missing" >&2; exit 4; }
cp "$PROBE" "$RUN_DIR/plugins/" || { echo "CompatProbe jar missing: $PROBE" >&2; exit 4; }
echo "[drive] mode=$MODE region.enabled=$REGION run-dir=$RUN_DIR"

EXTRA_JVM="-Dcoderyo.region.enabled=$REGION -Dcoderyo.region.mergeRadius=2 $DBG"

# Region A around chunk (0,0); Region B around chunk (40,40). Cross-region writes
# from the console (Server thread, external context) through the NMS path:
#   /setblock 8 70 8       -> region A (chunk 0,0)
#   /setblock 648 70 648   -> region B (chunk 40,40)
#   /fill 648 71 648 650 71 650 -> region B (spans chunk 40,40)
#   //set (WorldEdit) at 640..650 -> region B (NMS PaperweightAdapter)
# Then /probeverify reads back both regions after the owning regions drain.
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
  --cmd "op CONSOLE" \
  --cmd "setblock 8 70 8 minecraft:diamond_block" \
  --cmd "setblock 648 70 648 minecraft:emerald_block" \
  --cmd "fill 648 71 648 650 71 650 minecraft:gold_block" \
  --cmd "//pos1 646,72,646" \
  --cmd "//pos2 650,72,650" \
  --cmd "//set minecraft:netherite_block" \
  --cmd "probeverify 8 70 8 648 70 648" \
  --cmd "probeverify 649 71 649 648 72 648" \
  --assert-present "Done \(" \
  --assert-present "block write MARSHALED \(Tier 1\)" \
  --assert-present "PROBE_VERIFY region" \
  --assert-absent  "single-writer-per-region invariant violated" \
  --assert-absent  "may only be triggered synchronously" \
  --assert-absent  "Asynchronous .* failed main thread check" \
  --assert-absent  "Asynchronous [A-Za-z ]+!"

RC=$?
echo "[drive] harness exit=$RC  log=$LOG"
exit $RC
