#!/usr/bin/env bash
# coderyoMC P2 e2e parity harness — boots the real paperclip server, generates real
# terrain from a fixed seed, captures the selected compute backend + a terrain digest.
# Usage: drive.sh <label> <gpuEnabled true|false>
# Run from a working dir containing eula.txt + server.properties + this script + the
# paperclip jar at ../../coderyo-server/build/libs/ (or adjust JAR below).
set -u
LABEL="$1"; GPU="$2"
JAR="${JAR:-../../coderyo-server/build/libs/coderyo-paperclip-26.2-R0.1-SNAPSHOT.jar}"
LOG="server-${LABEL}.log"

rm -rf world world_nether world_the_end; rm -f "$LOG"
echo "[harness] booting label=$LABEL gpu.worldgen.enabled=$GPU"

{
  for i in $(seq 1 180); do grep -qE 'Done \(|For help, type' "$LOG" 2>/dev/null && break; sleep 1; done
  sleep 2
  echo "forceload add -64 -64 64 64"
  sleep 25
  echo "save-all flush"
  sleep 8
  echo "stop"
  sleep 5
} | java -Xms1G -Xmx2G -Dterminal.jline=false \
      -Dgpu.worldgen.enabled="$GPU" -Dgpu.worldgen.debug=true \
      -jar "$JAR" --nogui > "$LOG" 2>&1

echo "[harness] === compute log lines (${LABEL}) ==="
grep -iE 'coderyo-compute|\[compute\]|GPU worldgen|parity|backend|OpenCL' "$LOG" | head -25

REGION_DIR="world/dimensions/minecraft/overworld/region"
if [ -d "$REGION_DIR" ]; then
  echo "[harness] computing terrain digest for $LABEL ..."
  python terrain_digest.py "$REGION_DIR" 4 | sed "s/^/[harness][$LABEL] /"
else
  echo "[harness] NO region dir produced for $LABEL"
fi
