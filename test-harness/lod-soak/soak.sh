#!/usr/bin/env bash
# coderyoMC SIMULATION-LOD LONG SOAK — production-readiness "does LOD hold up over a long window?"
#
# region.enabled=true + LOD ON (los + dab + policy + extended), -Xms3G -Xmx6G, port 15565.
# Sustained MIXED load held for the WHOLE soak:
#   * MULTI-REGION hostiles : dense persistent zombies in 3 far-apart forceloaded areas -> parallel regions.
#   * NEAR full-fidelity horde: zombies right on the bot (NEAR band, never throttled).
#   * FAR/idle throttled band : zombies ringed 64-110 blocks from the bot (FAR band -> LOD throttles).
#   * EXEMPT timing-sensitive : villagers + breeding cows/sheep (the classic DAB-complaint contraption
#                               entities) in a far band -> must stay vanilla cadence (skip 0.000).
#   * REDSTONE contraption    : self-running face-to-face observer clocks -> continuous scheduled-tick
#                               / redstone load held for the whole window.
#   * protocol-776 MiniBot present at the central region.
#
# Holds steady for WINDOW seconds (default 1260 = 21 min) after a settle, sampling /mspt + /tps every
# SAMPLE seconds and the per-class LOD tally; GC logged to gc.log (post-GC heap = leak watch).
#
# Usage: ./soak.sh                 (defaults: WINDOW=1260 SAMPLE=15 SETTLE=45)
# Env:   WINDOW SAMPLE SETTLE BOOT SEED
set -u
WINDOW="${WINDOW:-1260}"   # measured steady-state window (s)  -> 21 min
SAMPLE="${SAMPLE:-15}"     # sample period (s)
SETTLE="${SETTLE:-45}"     # settle after spawn before measuring (s)
BOOT="${BOOT:-180}"
SEED="${SEED:-lodsoak2026}"

HERE="$(cd "$(dirname "$0")" && pwd)"
WT="$(cd "$HERE/../.." && pwd)"
JAR="$WT/coderyo-server/build/libs/coderyo-paperclip-26.2-R0.1-SNAPSHOT.jar"
PORT=15565
[ "$PORT" = "25565" ] && { echo "FATAL refuse 25565"; exit 4; }
[ -f "$JAR" ] || { echo "FATAL jar missing: $JAR"; exit 4; }

RUN="$HERE/run-soak"; LOG="$RUN/server.log"; BOTLOG="$RUN/bot.log"; GCLOG="$RUN/gc.log"
rm -rf "$RUN"; mkdir -p "$RUN"
javac -d "$RUN" "$HERE/../benchmark-vs-vanilla/MiniBot.java" 2>/dev/null || { echo "FATAL javac"; exit 1; }
cat > "$RUN/server.properties" <<EOF
online-mode=false
server-port=$PORT
level-seed=$SEED
spawn-protection=0
view-distance=10
simulation-distance=10
network-compression-threshold=-1
EOF
echo "eula=true" > "$RUN/eula.txt"

# central region = bot area at (0,0). Other regions 3000 blocks apart (disjoint).
PX=0; PY=100; PZ=0

build_world() {
  # central area floor for the bot + near/far horde
  echo "forceload add $((PX-120)) $((PZ-120)) $((PX+120)) $((PZ+120))"
  echo "forceload add 2920 -120 3120 120"      # region B
  echo "forceload add -3120 -120 -2920 120"    # region C
  sleep 3
  echo "fill $((PX-110)) 99 $((PZ-110)) $((PX+110)) 99 $((PZ+110)) minecraft:stone"
  echo "fill $((PX-110)) 100 $((PZ-110)) $((PX+110)) 105 $((PZ+110)) minecraft:air"
  sleep 2
  echo "tp SoakBot $PX $PY $PZ"
  echo "effect give SoakBot minecraft:resistance 999999 4 true"
  echo "effect give SoakBot minecraft:regeneration 999999 4 true"
  sleep 1

  # --- self-running redstone observer clocks (continuous scheduled-tick load) ---
  # face-to-face observer pairs self-start the instant the 2nd is placed.
  local ox
  for ox in -40 -36 -32 -28; do
    echo "setblock $ox 100 -60 minecraft:observer[facing=east]"
    echo "setblock $((ox+1)) 100 -60 minecraft:observer[facing=west]"
  done
  sleep 1

  # --- NEAR full-fidelity horde: 220 zombies right on the bot (NEAR band, skip=0) ---
  python - "$PX" "$PY" "$PZ" <<'PY'
import sys,math
px,py,pz=int(sys.argv[1]),int(sys.argv[2]),int(sys.argv[3])
for k in range(220):
    ang=math.radians((k*41.0)%360.0); r=3+(k%10)
    x=int(px+r*math.cos(ang)); z=int(pz+r*math.sin(ang))
    print('summon minecraft:zombie %d %d %d {PersistenceRequired:1b,attributes:[{id:"minecraft:follow_range",base:160.0}]}'%(x,py,z))
PY
  sleep 2
  # --- FAR/idle throttled band: 300 zombies ringed 64..108 from the bot (FAR band) ---
  python - "$PX" "$PY" "$PZ" <<'PY'
import sys,math
px,py,pz=int(sys.argv[1]),int(sys.argv[2]),int(sys.argv[3])
for k in range(300):
    ang=math.radians((k*37.0)%360.0); r=64+(k%44)
    x=int(px+r*math.cos(ang)); z=int(pz+r*math.sin(ang))
    print('summon minecraft:zombie %d %d %d {PersistenceRequired:1b,attributes:[{id:"minecraft:follow_range",base:160.0}]}'%(x,py,z))
PY
  sleep 2
  # --- EXEMPT timing-sensitive contraption entities (villagers + breeding animals), far band ---
  python - "$PX" "$PY" "$PZ" <<'PY'
import sys,math
px,py,pz=int(sys.argv[1]),int(sys.argv[2]),int(sys.argv[3])
for k in range(40):
    ang=math.radians((k*53.0)%360.0); r=70+(k%30)
    x=int(px+r*math.cos(ang)); z=int(pz+r*math.sin(ang))
    print('summon minecraft:villager %d %d %d {PersistenceRequired:1b}'%(x,py,z))
# breeding animals in-love (slow cadence): cows + sheep
for k in range(40):
    ang=math.radians((k*61.0+20)%360.0); r=72+(k%28)
    x=int(px+r*math.cos(ang)); z=int(pz+r*math.sin(ang))
    sp='minecraft:cow' if k%2==0 else 'minecraft:sheep'
    print('summon %s %d %d %d {InLove:600,PersistenceRequired:1b}'%(sp,x,py,z))
PY
  sleep 2
  # --- MULTI-REGION hostiles: dense packs in regions B and C (parallel-region load) ---
  python - <<'PY'
import sys
for cx,cz in ((3000,0),(-3000,0)):
    for i in range(220):
        import random
        x=cx+random.randint(-90,90); z=cz+random.randint(-90,90)
        print('summon minecraft:zombie %d 80 %d {PersistenceRequired:1b,attributes:[{id:"minecraft:follow_range",base:64.0}]}'%(x,z))
PY
  echo "[soak] mixed load spawned (near220 far300 exempt80 +2x220 multiregion + redstone clocks)" 1>&2
}

emit() {
  for i in $(seq 1 "$BOOT"); do grep -qE 'Done \(' "$LOG" 2>/dev/null && break; sleep 1; done
  sleep 2
  ( cd "$RUN" && java -cp . MiniBot 127.0.0.1 $PORT SoakBot $((WINDOW+SETTLE+300)) > "$BOTLOG" 2>&1 ) &
  BOTPID=$!
  for i in $(seq 1 40); do grep -q "joined the game" "$LOG" 2>/dev/null && break; sleep 1; done
  sleep 2
  echo "gamerule doMobSpawning false"; echo "gamerule doDaylightCycle false"
  echo "gamerule randomTickSpeed 3"; echo "gamerule mobGriefing false"; echo "gamerule doFireTick false"
  echo "difficulty hard"; echo "time set 18000"
  sleep 1
  build_world
  echo "[soak] settling ${SETTLE}s" 1>&2
  sleep "$SETTLE"
  echo "[soak] >>> MEASURE WINDOW START $(date +%s)" 1>&2
  echo "===SOAK_WINDOW_START $(date +%s)==="
  local elapsed=0
  while [ "$elapsed" -lt "$WINDOW" ]; do
    echo "tp SoakBot $PX $PY $PZ"   # keep bot pinned, near-horde stays NEAR
    echo "mspt"; echo "tps"
    echo "===SOAK_T $elapsed $(date +%s)==="
    sleep "$SAMPLE"; elapsed=$((elapsed+SAMPLE))
  done
  echo "===SOAK_WINDOW_END $(date +%s)==="
  echo "list"; echo "save-off"; echo "stop"
  wait $BOTPID 2>/dev/null
  sleep 8
}

echo "[soak] START WINDOW=${WINDOW}s SAMPLE=${SAMPLE}s SETTLE=${SETTLE}s seed=$SEED"
emit | ( cd "$RUN" && java -Xms3G -Xmx6G -XX:+UseG1GC \
  -Xlog:gc:file=gc.log:time,uptime:filecount=0 \
  -Dcoderyo.region.enabled=true -Dcoderyo.region.debug=true \
  -Dcoderyo.pathfinding.los.enabled=true \
  -Dcoderyo.lod.dab.enabled=true -Dcoderyo.lod.debug=true \
  -Dcoderyo.lod.policy.enabled=true -Dcoderyo.lod.extended.enabled=true \
  -Dcoderyo.lod.policy.exempt.persistent=false \
  -Dcom.mojang.eula.agree=true -Dterminal.jline=false \
  -jar "$JAR" --nogui --port $PORT --world world ) > "$LOG" 2>&1
echo "[soak] server exited."

CRASH=$(grep -ciE 'NoSuchElementException|ReportedException|Exception ticking|region tick failed|chunkSystemCrash|AsyncCatcher|NullPointerException' "$LOG")
SW=$(grep -ci 'single-writer' "$LOG")
CLEAN=$(grep -ci 'All dimensions are saved' "$LOG")
echo "[soak] crashes=$CRASH single_writer=$SW clean_shutdown=$CLEAN"
echo "[soak] analyze with: python $HERE/analyze-soak.py $RUN"
