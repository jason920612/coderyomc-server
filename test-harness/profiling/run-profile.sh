#!/usr/bin/env bash
# coderyoMC real-tick profiling driver (#21-adjacent).
#
# Boots the real paperclip jar on port 15565 with region.enabled+region.debug
# and a CONTINUOUS JFR recording (settings=profile, method sampling). Generates
# sustained realistic tick load (forceloaded chunks + ~1400 mobs across 2 well-
# separated regionizer regions + redstone + flowing fluids), lets world GEN
# settle, then ticks steadily for the profile window.
#
# Because JFR runs from boot, the analyzer (analyze-jfr.sh) filters samples to
# the STEADY-STATE window using the epoch markers this script writes to
# run-prof/steady.window, so one-shot worldgen does NOT pollute the hot-spot
# ranking.
#
# Command delivery: the proven subshell-emit | java-stdin pattern, run in the
# FOREGROUND (backgrounding the pipeline breaks Paper's stdin console reader).
#
# Usage: ./run-profile.sh [profile_seconds]
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
WT="$(cd "$HERE/../.." && pwd)"
JAR="$WT/coderyo-server/build/libs/coderyo-paperclip-26.2-R0.1-SNAPSHOT.jar"
RUN="$WT/run-prof"
LOG="$RUN/server.log"
JFR="$RUN/tick.jfr"
WIN="$RUN/steady.window"
PROFILE_SECS="${1:-240}"
PORT=15565

[ -f "$JAR" ] || { echo "FATAL: jar missing: $JAR"; exit 4; }
[ "$PORT" = "25565" ] && { echo "FATAL: refuse 25565"; exit 4; }

rm -f "$LOG" "$JFR" "$WIN"
rm -rf "$RUN/world" "$RUN/world_nether" "$RUN/world_the_end"

# Continuous JFR from boot; dumped to tick.jfr on clean `stop`.
JFRARGS="-XX:StartFlightRecording=name=tick,filename=$JFR,settings=profile,dumponexit=true"

emit_commands() {
  for i in $(seq 1 180); do
    grep -qE 'Done \(|For help, type' "$LOG" 2>/dev/null && break
    sleep 1
  done
  sleep 3

  echo "gamerule doMobSpawning false"
  echo "gamerule randomTickSpeed 3"
  echo "gamerule spawnRadius 0"
  echo "gamerule doFireTick false"
  echo "difficulty hard"
  echo "time set day"
  echo "forceload add -80 -80 80 80"
  echo "forceload add 2920 -80 3080 80"
  sleep 10

  spawn_pack() {
    local cx="$1" cz="$2" entity="$3" n="$4" k dx dz
    for k in $(seq 1 "$n"); do
      dx=$(( (RANDOM % 60) - 30 )); dz=$(( (RANDOM % 60) - 30 ))
      echo "summon $entity $((cx+dx)) 80 $((cz+dz))"
    done
  }
  # Moderated counts: heavy enough that entity AI/path/collision/tracking
  # dominate the tick, but below the threshold where the WorkStealing region
  # scheduler hits a concurrent mid-tick pollTask race (NoSuchElementException
  # crash observed at ~1400 mobs). ~360/region => ~720 total live entities.
  spawn_pack 0 0 minecraft:zombie 140
  spawn_pack 0 0 minecraft:skeleton 110
  spawn_pack 0 0 minecraft:cow 60
  spawn_pack 0 0 minecraft:sheep 50
  sleep 6
  spawn_pack 3000 0 minecraft:zombie 140
  spawn_pack 3000 0 minecraft:skeleton 90
  spawn_pack 3000 0 minecraft:villager 40
  spawn_pack 3000 0 minecraft:chicken 60
  sleep 6

  echo "setblock 5 82 5 minecraft:water"
  echo "setblock 8 82 5 minecraft:water"
  echo "setblock 11 82 5 minecraft:lava"
  echo "setblock 2940 82 5 minecraft:water"
  echo "setblock 2960 82 5 minecraft:lava"
  echo "setblock 0 80 20 minecraft:redstone_block"
  echo "setblock 0 80 21 minecraft:redstone_lamp"
  echo "setblock 0 80 22 minecraft:repeater"
  echo "setblock 0 80 23 minecraft:redstone_torch"

  # Settle so worldgen/light finish before the steady window.
  echo "[prof-timeline] settling 25s" 1>&2
  sleep 25

  # ---- steady-state window: record epoch start (ms) for the analyzer ----
  local START_MS; START_MS=$(( $(date +%s) * 1000 ))
  echo "START_MS=$START_MS" > "$WIN"
  echo "[prof-timeline] STEADY START ${PROFILE_SECS}s (epoch_ms=$START_MS)" 1>&2

  local elapsed=0 step=10
  while [ "$elapsed" -lt "$PROFILE_SECS" ]; do
    echo "tps"; echo "mspt"; echo "list"
    if [ $(( elapsed % 40 )) -eq 0 ] && [ "$elapsed" -gt 0 ]; then
      spawn_pack 0 0 minecraft:zombie 30
      spawn_pack 3000 0 minecraft:skeleton 30
    fi
    sleep "$step"
    elapsed=$(( elapsed + step ))
  done

  local END_MS; END_MS=$(( $(date +%s) * 1000 ))
  echo "END_MS=$END_MS" >> "$WIN"
  echo "[prof-timeline] STEADY END (epoch_ms=$END_MS)" 1>&2

  echo "save-off"
  echo "tps"; echo "mspt"
  echo "stop"
  sleep 8
}

echo "[prof] booting paperclip on $PORT (region.enabled=true region.debug=true, JFR=profile, ${PROFILE_SECS}s steady window)"
emit_commands | java -Xms3G -Xmx6G -XX:+UseG1GC \
  -Dcoderyo.region.enabled=true -Dcoderyo.region.debug=true \
  -Dterminal.jline=false -Dcom.mojang.eula.agree=true \
  $JFRARGS \
  -jar "$JAR" --nogui --port "$PORT" > "$LOG" 2>&1

echo "[prof] server exited."
echo "[prof] steady window:"; cat "$WIN" 2>&1
echo "[prof] JFR file:"; ls -la "$JFR" 2>&1
echo "[prof] done."
