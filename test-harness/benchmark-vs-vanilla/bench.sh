#!/usr/bin/env bash
# coderyoMC CONSOLIDATION BENCHMARK — coderyoMC FULL vs VANILLA-equivalent Paper.
#
# Same paperclip jar, two JVM-flag configs:
#   VANILLA = region.enabled=false + ALL coderyo feature flags OFF  -> byte-for-byte
#             vanilla Paper 26.2 (single-thread tick).
#   FULL    = region.enabled=true + the PROVEN wins on:
#               coderyo.pathfinding.los.enabled=true
#               coderyo.lod.dab.enabled=true  (+ policy/extended default-on)
#             FALSIFIED flags (async / entitycache / neighborshare) left OFF.
#
# Three e2e scenarios (real server, port 15565, fixed seed):
#   multiregion : dense packs across 4 FAR-APART forceloaded areas -> 4 parallel
#                 regions. Regionization's cross-core parallelism vs single-thread.
#   pathbound   : a horde chasing a stationary bot across a STRUCTURED obstacle
#                 field (walls force real A*) -> LOD's -43.9% lever bites.
#   flatdense   : a dense horde near one bot on FLAT ground -> one region,
#                 entity-tick-bound. The HONEST near-parity case.
#
# For each run we summon a FIXED count of persistent zombies (stable population,
# no despawn-attrition noise), settle, then sample whole-server "Server tick times"
# MSPT + TPS for the measurement window, and report the settled mean/max + TPS held.
#
# Usage: ./bench.sh <multiregion|pathbound|flatdense> <FULL|VANILLA> <mobs>
# Env:   SECS (measurement window seconds, default 50), SEED, BOOT (boot timeout s).
set -u

SCN="${1:?scenario: multiregion|pathbound|flatdense}"
MODE="${2:?config: FULL|VANILLA}"
MOBS="${3:?mob count}"
SECS="${SECS:-50}"
BOOT="${BOOT:-180}"
SEED="${SEED:-bench2026}"

HERE="$(cd "$(dirname "$0")" && pwd)"
WT="$(cd "$HERE/../.." && pwd)"
JAR="$WT/coderyo-server/build/libs/coderyo-paperclip-26.2-R0.1-SNAPSHOT.jar"
PORT=15565
[ "$PORT" = "25565" ] && { echo "FATAL refuse 25565"; exit 4; }
[ -f "$JAR" ] || { echo "FATAL jar missing: $JAR"; exit 4; }

case "$MODE" in
  VANILLA) FLAGS="-Dcoderyo.region.enabled=false" ;;  # all coderyo features off
  FULL)    FLAGS="-Dcoderyo.region.enabled=true \
                  -Dcoderyo.pathfinding.los.enabled=true \
                  -Dcoderyo.lod.dab.enabled=true \
                  -Dcoderyo.lod.policy.enabled=true \
                  -Dcoderyo.lod.extended.enabled=true \
                  -Dcoderyo.lod.policy.exempt.persistent=false" ;;
  *) echo "bad config $MODE"; exit 2 ;;
esac

RUN="$HERE/run-$SCN-$MODE-$MOBS"; LOG="$RUN/server.log"; BOTLOG="$RUN/bot.log"
rm -rf "$RUN"; mkdir -p "$RUN"
javac -d "$RUN" "$HERE/MiniBot.java" 2>/dev/null || { echo "FATAL javac"; exit 1; }
cat > "$RUN/server.properties" <<EOF
online-mode=false
server-port=$PORT
level-seed=$SEED
spawn-protection=0
view-distance=8
simulation-distance=8
network-compression-threshold=-1
EOF
echo "eula=true" > "$RUN/eula.txt"

# ---- per-scenario world build + spawn (emitted to the live console) ----
build_world() {
  case "$SCN" in
  multiregion)
    # 4 far-apart areas => 4 disjoint regions (no merge). Dense persistent packs.
    echo "forceload add -80 -80 80 80"
    echo "forceload add 2920 -80 3080 80"
    echo "forceload add -3080 -80 -2920 80"
    echo "forceload add 2920 2920 3080 3080"
    sleep 3
    local per=$(( MOBS / 4 )) cx cz i
    for area in "0 0" "3000 0" "-3000 0" "3000 3000"; do
      set -- $area; cx=$1; cz=$2
      for i in $(seq 1 "$per"); do
        echo "summon minecraft:zombie $((cx + (RANDOM%100)-50)) 80 $((cz + (RANDOM%100)-50)) {PersistenceRequired:1b,attributes:[{id:\"minecraft:follow_range\",base:48.0}]}"
      done
    done
    echo "[bench:$SCN] spawned ~$((per*4)) across 4 regions" 1>&2
    ;;
  pathbound)
    local PX=0 PY=100 PZ=0
    echo "forceload add $((PX-100)) $((PZ-100)) $((PX+100)) $((PZ+100))"
    echo "fill $((PX-95)) 99 $((PZ-95)) $((PX+95)) 99 $((PZ+95)) minecraft:stone"
    echo "fill $((PX-95)) 100 $((PZ-95)) $((PX+95)) 104 $((PZ+95)) minecraft:air"
    sleep 2
    # obstacle wall grid -> L1 direct-walk fails, real A* dominates (path-bound)
    python - "$PX" "$PZ" <<'PY'
import sys
px,pz=int(sys.argv[1]),int(sys.argv[2])
for gx in range(px-88, px+88, 8):
    for gz in range(pz-88, pz+88, 8):
        if abs(gx-px)<7 and abs(gz-pz)<7: continue
        print('fill %d 100 %d %d 103 %d minecraft:stone'%(gx,gz,gx+4,gz))
PY
    sleep 2
    echo "tp BenchTgt $PX $PY $PZ"
    echo "effect give BenchTgt minecraft:resistance 999999 4 true"
    echo "effect give BenchTgt minecraft:regeneration 999999 4 true"
    sleep 1
    # horde across rings 12..88 -> populates all LOD bands, all chase the bot
    python - "$MOBS" "$PX" "$PY" "$PZ" <<'PY'
import sys,math
N,px,py,pz=int(sys.argv[1]),int(sys.argv[2]),int(sys.argv[3]),int(sys.argv[4])
for k in range(N):
    ang=math.radians((k*37.0)%360.0); r=12+(k%76)
    x=int(px+r*math.cos(ang)); z=int(pz+r*math.sin(ang))
    print('summon minecraft:zombie %d %d %d {PersistenceRequired:1b,attributes:[{id:"minecraft:follow_range",base:160.0}]}'%(x,py+1,z))
PY
    echo "[bench:$SCN] spawned $MOBS chasing bot on obstacle terrain" 1>&2
    ;;
  flatdense)
    local PX=0 PY=80 PZ=0
    echo "forceload add -80 -80 80 80"
    sleep 2
    echo "tp BenchTgt $PX $PY $PZ"
    echo "effect give BenchTgt minecraft:resistance 999999 4 true"
    sleep 1
    # dense near-player horde on flat ground, one region
    local i
    for i in $(seq 1 "$MOBS"); do
      echo "summon minecraft:zombie $(( (RANDOM%70)-35 )) $PY $(( (RANDOM%70)-35 )) {PersistenceRequired:1b,attributes:[{id:\"minecraft:follow_range\",base:48.0}]}"
    done
    echo "[bench:$SCN] spawned $MOBS dense near bot (flat)" 1>&2
    ;;
  *) echo "bad scenario $SCN"; exit 2 ;;
  esac
}

NEED_BOT=0
[ "$SCN" != "multiregion" ] && NEED_BOT=1

emit() {
  for i in $(seq 1 "$BOOT"); do grep -qE 'Done \(' "$LOG" 2>/dev/null && break; sleep 1; done
  sleep 2
  if [ "$NEED_BOT" = 1 ]; then
    ( cd "$RUN" && java -cp . MiniBot 127.0.0.1 $PORT BenchTgt $((SECS+120)) > "$BOTLOG" 2>&1 ) &
    BOTPID=$!
    for i in $(seq 1 40); do grep -q "joined the game" "$LOG" 2>/dev/null && break; sleep 1; done
    sleep 2
  fi
  echo "gamerule doMobSpawning false"; echo "gamerule doDaylightCycle false"
  echo "gamerule randomTickSpeed 0"; echo "gamerule mobGriefing false"; echo "gamerule doFireTick false"
  echo "difficulty hard"; echo "time set 18000"
  sleep 1
  build_world
  echo "[bench:$SCN] settling" 1>&2
  sleep 20
  local s=0
  while [ "$s" -lt "$((SECS/2))" ]; do
    [ "$NEED_BOT" = 1 ] && echo "tp BenchTgt 0 ${PY:-100} 0"
    echo "mspt"; echo "tps"
    sleep 2; s=$((s+1))
  done
  echo "list"; echo "save-off"; echo "stop"
  [ "$NEED_BOT" = 1 ] && { wait $BOTPID 2>/dev/null; }
  sleep 6
}

echo "[bench] SCN=$SCN MODE=$MODE MOBS=$MOBS SECS=$SECS"
emit | ( cd "$RUN" && java -Xms4G -Xmx8G -XX:+UseG1GC $FLAGS \
  -Dcom.mojang.eula.agree=true -Dterminal.jline=false \
  -jar "$JAR" --nogui --port $PORT --world world ) > "$LOG" 2>&1

echo "[bench] exited."
CRASH=$(grep -ciE 'NoSuchElementException|ReportedException|Exception ticking|region tick failed|chunkSystemCrash' "$LOG")
SW=$(grep -ci 'single-writer' "$LOG")
ALIVE=$(sed -r 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -oE 'There are [0-9]+' | tail -1 | grep -oE '[0-9]+')
# Settled whole-server MSPT: Paper prints "Server tick times (avg/min/max) ... : a/b/c"
# Take the avg column, drop the first 3 warmup samples, mean+max of the rest.
read MSPT_MEAN MSPT_MAX NSAMP <<EOF
$(sed -r 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -A1 "Server tick times" | grep -oE "[0-9]+\.[0-9]+/[0-9]+\.[0-9]+/[0-9]+\.[0-9]+" \
  | awk -F/ 'NR>3{a[++n]=$1} END{ for(i=1;i<=n;i++){s+=a[i]; if(a[i]>mx)mx=a[i]} if(n>0) printf "%.2f %.2f %d", s/n, mx, n; else printf "NA NA 0" }')
EOF
TPS=$(sed -r 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -iE "TPS from" | tail -1)
echo "RESULT scn=$SCN mode=$MODE mobs=$MOBS alive=$ALIVE crashes=$CRASH single_writer=$SW mspt_mean=$MSPT_MEAN mspt_max=$MSPT_MAX nsamp=$NSAMP"
echo "  $TPS"
sed -r 's/\x1b\[[0-9;]*m//g' "$LOG" | grep -iE "DAB throttle tally|CLASS tally|coderyo-region-worker" | tail -2
