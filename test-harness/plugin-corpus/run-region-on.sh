#!/usr/bin/env bash
#
# run-region-on.sh -- region.enabled=true REAL-PLUGIN compat run (issue #13).
#
# Boots the REAL coderyoMC 26.2 paperclip jar headless on port 15568,
# online-mode=false, with the 7 corpus plugins (CoreProtect SKIPPED -- it
# self-disables on 26.2) and the regionization + Tier 0/2 compat layer ON:
#
#     -Dcoderyo.region.enabled=true
#     -Dcoderyo.region.debug=true
#     -Dcoderyo.compat.enabled=true
#
# ANTI-STALL design (a prior run stalled parsing console echoes):
#   * Stdin is driven by a FEEDER subshell (same proven pattern as
#     run-baseline.sh: `( ... ) | java ...`). The feeder waits for "Done (" in
#     the log up to BOOT_TIMEOUT seconds, then emits best-effort probe commands
#     (NOT looping on echoes) and finally `stop`.
#   * A WATCHDOG kills the JVM if boot never completes within BOOT_TIMEOUT, or
#     if the whole run exceeds HARD_KILL seconds. Never waits indefinitely.
#   * ONE boot with all 7 plugins.
#
# Real production path only (design-spec §8): no mocks. Run download.sh first.
#
# Usage: ./run-region-on.sh [--jar PATH] [--keep]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JARS="$HERE/jars"
RUN="$HERE/run-region-on"
PORT=15568
BOOT_TIMEOUT=180     # hard cap to reach "Done ("
CMD_WAIT=6           # per-probe settle time
HARD_KILL=300        # absolute ceiling for the JVM

JAR=""
KEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --jar) shift; JAR="${1:-}";;
    --jar=*) JAR="${1#--jar=}";;
    --keep) KEEP=1;;
  esac
  shift || true
done

if [ -z "$JAR" ]; then
  JAR="$(find "$HERE/../.." -name 'coderyo-paperclip-*.jar' -path '*build/libs*' 2>/dev/null | head -1)"
fi
[ -f "$JAR" ] || { echo "paperclip jar not found; build with ./gradlew createPaperclipJar" >&2; exit 1; }
echo "jar:  $JAR"

ls "$JARS"/*.jar >/dev/null 2>&1 || { echo "no corpus jars in $JARS; run ./download.sh first" >&2; exit 1; }

[ "$KEEP" = "1" ] || rm -rf "$RUN"
mkdir -p "$RUN/plugins"
for j in "$JARS"/*.jar; do
  case "$(basename "$j")" in
    CoreProtect-*) echo "[skip] $(basename "$j") (self-disables on 26.2)"; continue;;
  esac
  cp "$j" "$RUN/plugins/"
done
echo "plugins under test:"; ls "$RUN/plugins"

echo "eula=true" > "$RUN/eula.txt"
cat > "$RUN/server.properties" <<EOF
server-port=$PORT
online-mode=false
level-type=minecraft\:flat
spawn-protection=0
max-players=2
view-distance=4
simulation-distance=4
EOF

LOG="$RUN/region-on-server.log"
: > "$LOG"
echo "booting on port $PORT region.enabled=true region.debug=true compat.enabled=true (hard ${BOOT_TIMEOUT}s boot, ${HARD_KILL}s ceiling) ..."

cd "$RUN"

# ---------------------------------------------------------------------------
# FEEDER subshell -> java stdin. Waits for boot, runs probes, then stops.
# Writes its own status lines to the same LOG via a >> append (#FEEDER tag) so
# the grader can see boot/probe verdicts in one file.
# ---------------------------------------------------------------------------
feeder() {
  local booted=0 i
  for i in $(seq 1 "$BOOT_TIMEOUT"); do
    if grep -q 'Done (' "$LOG" 2>/dev/null; then booted=1; echo "#FEEDER BOOT-OK ~${i}s" >> "$LOG"; break; fi
    # also bail early if server already printing a fatal stop
    if grep -qi 'Stopping server' "$LOG" 2>/dev/null; then echo "#FEEDER server stopping during boot" >> "$LOG"; break; fi
    sleep 1
  done
  if [ "$booted" != "1" ]; then
    echo "#FEEDER BOOT-FAILED (no 'Done (' in ${BOOT_TIMEOUT}s)" >> "$LOG"
    # send stop anyway in case it is merely slow; watchdog will hard-kill.
    printf 'stop\n'
    return 0
  fi
  sleep 2
  # ---- best-effort, time-boxed probes (one per plugin) ----
  echo "#FEEDER probes-begin" >> "$LOG"
  for entry in \
    "LuckPerms|lp info" \
    "PlaceholderAPI|papi parse me %server_online%" \
    "WorldEdit|version WorldEdit" \
    "WorldGuard|version WorldGuard" \
    "VaultUnlocked|version Vault" \
    "EssentialsX|ess version" \
    "ViaVersion|viaversion" ; do
    label="${entry%%|*}"; cmd="${entry#*|}"
    echo "#FEEDER PROBE $label :: $cmd" >> "$LOG"
    printf '%s\n' "$cmd"
    sleep "$CMD_WAIT"
  done
  echo "#FEEDER probes-end; sending stop" >> "$LOG"
  printf 'stop\n'
  sleep 5
}

# ---------------------------------------------------------------------------
# WATCHDOG: absolute ceiling. Kills any lingering JVM for this port/props.
# ---------------------------------------------------------------------------
watchdog() {
  sleep "$HARD_KILL"
  echo "#WATCHDOG HARD_KILL ${HARD_KILL}s reached -- killing server JVM(s)" >> "$LOG"
  # Kill java procs that carry our unique region flag (do NOT touch others).
  for pid in $(cmd.exe /c "wmic process where \"name='java.exe'\" get ProcessId,CommandLine /format:csv" 2>/dev/null \
                 | grep 'coderyo.region.enabled=true' | awk -F',' '{print $NF}' | tr -d '\r'); do
    [ -n "$pid" ] && cmd.exe /c "taskkill /PID $pid /T /F" >/dev/null 2>&1
  done
}

watchdog &
WD=$!

feeder | java -Xms1024M -Xmx2048M \
  -Dcoderyo.region.enabled=true \
  -Dcoderyo.region.debug=true \
  -Dcoderyo.compat.enabled=true \
  -jar "$JAR" --nogui --port "$PORT" >> "$LOG" 2>&1

# JVM exited (clean stop, or watchdog kill). Tear down watchdog.
kill "$WD" 2>/dev/null
wait "$WD" 2>/dev/null

if grep -q '#FEEDER BOOT-OK' "$LOG"; then
  echo "---- region-on run complete (BOOT OK); log at $LOG ----"
elif grep -q '#WATCHDOG' "$LOG"; then
  echo "---- region-on run HARD-KILLED by watchdog; partial log at $LOG ----"
else
  echo "---- region-on boot FAILED; partial log at $LOG ----"
fi
