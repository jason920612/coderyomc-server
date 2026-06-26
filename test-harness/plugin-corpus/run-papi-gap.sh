#!/usr/bin/env bash
#
# run-papi-gap.sh -- definitive PAPI-gap probe (region.enabled configurable).
#
# Boots the real coderyoMC 26.2 paperclip jar headless on port 15569,
# online-mode=false, with the corpus plugins (PlaceholderAPI + LuckPerms +
# VaultUnlocked + EssentialsX etc., CoreProtect skipped) and discriminates
# whether the PAPI "literal placeholder" result is just a missing eCloud
# expansion (operator step) or a regionization bug.
#
# Probes, in order:
#   1. papi list                         -> which expansions are registered
#   2. papi parse me %server_online%     -> Server expansion NOT bundled -> literal expected
#   3. papi ecloud download Server       -> try eCloud (may be unreachable)
#   4. papi reload
#   5. papi parse me %server_online%     -> after download attempt
#   6. papi parse me %vaultunlocked_currency%      -> SELF-registered expansion (no download)
#   7. papi parse me %vaultunlocked_currencyplural%
#   8. papi parse me %essentials_unique%           -> Essentials self-registered, console-safe
#
# Usage: ./run-papi-gap.sh [--region on|off]
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JARS="$HERE/jars"
REGION="on"
while [ $# -gt 0 ]; do
  case "$1" in
    --region) shift; REGION="${1:-on}";;
    --region=*) REGION="${1#--region=}";;
  esac
  shift || true
done
RUN="$HERE/run-papi-${REGION}"
PORT=15569
BOOT_TIMEOUT=180
CMD_WAIT=6
HARD_KILL=320

if [ "$REGION" = "on" ]; then REGFLAG=true; else REGFLAG=false; fi

JAR="$(find "$HERE/../.." -name 'coderyo-paperclip-*.jar' -path '*build/libs*' 2>/dev/null | head -1)"
[ -f "$JAR" ] || { echo "paperclip jar not found" >&2; exit 1; }
echo "jar:  $JAR"
echo "region: $REGION (coderyo.region.enabled=$REGFLAG)"

ls "$JARS"/*.jar >/dev/null 2>&1 || { echo "no corpus jars; run ./download.sh" >&2; exit 1; }

rm -rf "$RUN"
mkdir -p "$RUN/plugins"
for j in "$JARS"/*.jar; do
  case "$(basename "$j")" in
    CoreProtect-*) echo "[skip] $(basename "$j")"; continue;;
  esac
  cp "$j" "$RUN/plugins/"
done
echo "plugins:"; ls "$RUN/plugins"

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

LOG="$RUN/papi-${REGION}-server.log"
: > "$LOG"
echo "booting on $PORT region.enabled=$REGFLAG ..."
cd "$RUN"

feeder() {
  local booted=0 i
  for i in $(seq 1 "$BOOT_TIMEOUT"); do
    if grep -q 'Done (' "$LOG" 2>/dev/null; then booted=1; echo "#FEEDER BOOT-OK ~${i}s" >> "$LOG"; break; fi
    if grep -qi 'Stopping server' "$LOG" 2>/dev/null; then echo "#FEEDER stopping during boot" >> "$LOG"; break; fi
    sleep 1
  done
  if [ "$booted" != "1" ]; then
    echo "#FEEDER BOOT-FAILED (${BOOT_TIMEOUT}s)" >> "$LOG"
    printf 'stop\n'; return 0
  fi
  sleep 3
  echo "#FEEDER probes-begin" >> "$LOG"
  probe() { echo "#FEEDER PROBE :: $1" >> "$LOG"; printf '%s\n' "$1"; sleep "${2:-$CMD_WAIT}"; }
  probe "papi list"
  probe "papi parse me %server_online%"
  probe "papi ecloud download Server" 14
  probe "papi reload" 8
  probe "papi list"
  probe "papi parse --null %server_online%"
  probe "papi parse --null %server_tps%"
  probe "papi parse --null %server_name%"
  probe "papi parse --null %vaultunlocked_currency%"
  probe "papi parse --null %vaultunlocked_currencyplural%"
  probe "papi parse me %server_online%"
  echo "#FEEDER probes-end; stop" >> "$LOG"
  printf 'stop\n'; sleep 5
}

watchdog() {
  sleep "$HARD_KILL"
  echo "#WATCHDOG HARD_KILL ${HARD_KILL}s" >> "$LOG"
  for pid in $(cmd.exe /c "wmic process where \"name='java.exe'\" get ProcessId,CommandLine /format:csv" 2>/dev/null \
                 | grep "coderyo.papi.tag=gap-${REGION}" | awk -F',' '{print $NF}' | tr -d '\r'); do
    [ -n "$pid" ] && cmd.exe /c "taskkill /PID $pid /T /F" >/dev/null 2>&1
  done
}
watchdog & WD=$!

feeder | java -Xms1024M -Xmx2048M \
  -Dcoderyo.region.enabled=$REGFLAG \
  -Dcoderyo.region.debug=true \
  -Dcoderyo.compat.enabled=true \
  -Dcoderyo.papi.tag=gap-${REGION} \
  -jar "$JAR" --nogui --port "$PORT" >> "$LOG" 2>&1

kill "$WD" 2>/dev/null; wait "$WD" 2>/dev/null

if grep -q '#FEEDER BOOT-OK' "$LOG"; then
  echo "---- papi-${REGION} run complete (BOOT OK); log: $LOG ----"
else
  echo "---- papi-${REGION} boot FAILED/killed; log: $LOG ----"
fi
