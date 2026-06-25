#!/usr/bin/env bash
# Aggregate jdk.ExecutionSample stacks from a JFR recording into a ranked
# CPU hot-spot table (top methods + top leaf packages/subsystems).
#
# Usage: ./analyze-jfr.sh <tick.jfr> [topN]
set -u
JFR="${1:?usage: analyze-jfr.sh tick.jfr [topN]}"
TOPN="${2:-25}"
JFRBIN="${JFR_BIN:-jfr}"

[ -f "$JFR" ] || { echo "no such jfr: $JFR"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Dump execution samples with deep stacks.
"$JFRBIN" print --events jdk.ExecutionSample --stack-depth 64 "$JFR" > "$TMP/raw.txt" 2>/dev/null

# Optional steady-state window filter: keep only sample blocks whose startTime
# epoch falls in [START_MS, END_MS]. Window comes from $WINDOW_FILE (the
# run-prof/steady.window the driver writes) or env START_MS/END_MS. This excludes
# one-shot worldgen so the ranking reflects the steady running tick only.
WINDOW_FILE="${WINDOW_FILE:-}"
if [ -n "$WINDOW_FILE" ] && [ -f "$WINDOW_FILE" ]; then
  # shellcheck disable=SC1090
  . "$WINDOW_FILE"
fi
START_MS="${START_MS:-0}"
END_MS="${END_MS:-99999999999999}"

if [ "$START_MS" != "0" ]; then
  echo "(filtering samples to steady window: START_MS=$START_MS END_MS=$END_MS)" 1>&2
  awk -v s="$START_MS" -v e="$END_MS" '
    function flush(){ if(keep && block!="") printf "%s", block; block=""; keep=0; }
    /^jdk\.ExecutionSample/ { flush(); block=$0 ORS; intop=1; keep=0; next }
    intop && /startTime[ ]*=/ {
      # jfr print local format: "startTime = 21:06:49.614 (2026-06-25)"
      line2=$0;
      hh=0;mm=0;ss=0;frac=0;yr=1970;mo=1;dy=1;
      if (match(line2,/[0-9][0-9]:[0-9][0-9]:[0-9][0-9]\.[0-9]+/)) {
        t=substr(line2,RSTART,RLENGTH);
        hh=substr(t,1,2); mm=substr(t,4,2); ss=substr(t,7,2);
        frac=substr(t,10,3);
      }
      if (match(line2,/\(20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]\)/)) {
        dpart=substr(line2,RSTART+1,10);
        yr=substr(dpart,1,4); mo=substr(dpart,6,2); dy=substr(dpart,9,2);
      }
      spec=yr" "mo" "dy" "hh" "mm" "ss;
      ep=mktime(spec);          # LOCAL epoch seconds (matches driver date +%s)
      if (ep<0) { keep=1 } else { epms=ep*1000+frac+0; keep=(epms>=s && epms<=e) }
    }
    { if (block!="") block=block $0 ORS; else print }
    END{ flush() }
  ' "$TMP/raw.txt" > "$TMP/samples.txt"
  # mktime uses LOCAL tz; JFR Z is UTC. If everything got filtered out, the tz
  # offset broke it -> fall back to unfiltered so we never produce an empty set.
  if [ "$(grep -cE '^jdk\.ExecutionSample' "$TMP/samples.txt")" -eq 0 ]; then
    echo "(window filter matched 0 samples -- tz mismatch; using FULL recording)" 1>&2
    cp "$TMP/raw.txt" "$TMP/samples.txt"
  fi
else
  cp "$TMP/raw.txt" "$TMP/samples.txt"
fi

TOTAL=$(grep -cE '^jdk\.ExecutionSample' "$TMP/samples.txt")
RAWTOTAL=$(grep -cE '^jdk\.ExecutionSample' "$TMP/raw.txt")
echo "=== JFR: $JFR ==="
echo "Total jdk.ExecutionSample events (window/raw): $TOTAL / $RAWTOTAL"
echo

# --- 1) Hottest LEAF method (top-of-stack) = where the CPU actually is ---
# In `jfr print`, each sample lists its stack; the first frame after the
# "stackTrace = [" line is the leaf (on-CPU) frame.
awk '
  /stackTrace = \[/ { instack=1; first=1; next }
  instack && first {
    line=$0; gsub(/^[ \t]+/,"",line); gsub(/[ \t]+$/,"",line);
    # strip line-number suffix " line: NNN" and trailing args descriptors
    sub(/ line: [0-9]+.*/,"",line);
    if (line != "" && line !~ /^\]/) { print line; }
    first=0; instack=0;
  }
' "$TMP/samples.txt" > "$TMP/leaves.txt"

echo "=== TOP $TOPN ON-CPU LEAF METHODS (by sample count) ==="
sort "$TMP/leaves.txt" | uniq -c | sort -rn | head -n "$TOPN" | \
  awk -v t="$TOTAL" '{c=$1; $1=""; sub(/^ /,""); pct=(t>0)?100*c/t:0; printf "%6d  %5.1f%%  %s\n", c, pct, $0}'
echo

# --- 2) Aggregate by class (leaf) ---
echo "=== TOP $TOPN ON-CPU CLASSES (leaf frame) ==="
sed -E 's/\.[a-zA-Z0-9_<>$]+\(.*$//' "$TMP/leaves.txt" | sort | uniq -c | sort -rn | head -n "$TOPN" | \
  awk -v t="$TOTAL" '{c=$1; $1=""; sub(/^ /,""); pct=(t>0)?100*c/t:0; printf "%6d  %5.1f%%  %s\n", c, pct, $0}'
echo

# --- 3) Subsystem categorization (regex buckets over the FULL stack of each
#         sample: a sample counts toward a bucket if any frame matches) ---
echo "=== SUBSYSTEM ATTRIBUTION (sample counted if ANY frame matches; non-exclusive) ==="
# Read the (already window-filtered) sample set so buckets honour the window.
awk -v total="$TOTAL" '
  BEGIN{
    n=split("pathfinding:PathNavigation|PathFinder|Node[A-Z]|\\.path\\.;ai_goal:goal\\.|Goal\\.|GoalSelector|Brain|Behavior|sensing|Sensor;entity_tick:Entity\\.tick|LivingEntity\\.|Mob\\.|aiStep|serverAiStep|baseTick;movement_collision:collide|getCollisions|EntityCollision|Shapes\\.|VoxelShape|moveRelative|move\\(;block_entity:BlockEntity|tickBlockEntities;redstone_leveltick:LevelTicks|RedstoneWire|signal|NeighborUpdater|scheduledTick;fluid:Fluid|fluid\\.;light:LightEngine|lightengine|Light[A-Z];tracking_net:ChunkMap|TrackedEntity|broadcast|ServerEntity|Packet|Connection|Network;chunk_system:ChunkHolder|ChunkMap|ServerChunkCache|chunk\\.|Chunk[A-Z]|PoiManager;region_sched:com\\.coderyo\\.region|RegionScheduler|RegionTick|Regionized|WorkStealing;gc:GC|gc\\.|Reference|Cleaner;jit_vm:Compiler|CompileBroker|Interpreter", buckets, ";");
    for(i=1;i<=n;i++){ split(buckets[i],kv,":"); name[i]=kv[1]; rx[i]=kv[2]; cnt[i]=0; }
  }
  /^jdk\.ExecutionSample/ { if(seen){ flush(); } seen=1; delete hit; instack=0; next }
  /stackTrace = \[/ { instack=1; next }
  instack && /^[[:space:]]*\]/ { instack=0; next }
  instack {
    line=$0;
    for(i=1;i<=n;i++){ if(match(line, rx[i])) hit[i]=1; }
    next
  }
  END{ flush(); for(i=1;i<=n;i++){ pct=(total>0)?100*cnt[i]/total:0; printf "%-18s %6d  %5.1f%%\n", name[i], cnt[i], pct } }
  function flush(){ for(i=1;i<=n;i++) if(hit[i]) cnt[i]++; }
' "$TMP/samples.txt" | sort -k2 -rn
echo
echo "(Subsystem buckets are non-exclusive: deep stacks span multiple subsystems,"
echo " so percentages sum > 100%. Use leaf tables above for exclusive on-CPU time.)"
