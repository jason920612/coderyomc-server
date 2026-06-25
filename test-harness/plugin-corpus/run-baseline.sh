#!/usr/bin/env bash
#
# run-baseline.sh -- region.enabled=false BASELINE for the real-plugin corpus.
#
# Boots the REAL coderyoMC 26.2 paperclip jar headless on port 15567 with every
# downloaded corpus plugin in run/plugins/, online-mode=false, lets it fully
# start + enable plugins, then `stop`s it. Captures the full log so per-plugin
# load/enable status can be graded. NO mocks -- real production path (design
# §8). Run download.sh first.
#
# Usage:
#   ./run-baseline.sh [--jar PATH] [--keep]
#
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JARS="$HERE/jars"
RUN="$HERE/run"
PORT=15567

JAR=""
KEEP=0
for a in "$@"; do
  case "$a" in
    --jar) shift; JAR="${1:-}";;
    --jar=*) JAR="${a#--jar=}";;
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
cp "$JARS"/*.jar "$RUN/plugins/"
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

LOG="$RUN/baseline-server.log"
echo "booting on port $PORT (online-mode=false) ..."

# Drive: wait for Done, then stop. Use a fifo so we can inject `stop`.
cd "$RUN"
(
  # give the server up to 240s to reach "Done"; then stop.
  for i in $(seq 1 240); do
    if grep -q 'Done (' "$LOG" 2>/dev/null; then break; fi
    sleep 1
  done
  sleep 3
  echo "stop"
) | java -Xms1024M -Xmx2048M -jar "$JAR" --nogui --port "$PORT" 2>&1 | tee "$LOG"

echo "---- baseline boot complete; log at $LOG ----"
