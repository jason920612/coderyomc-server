#!/usr/bin/env bash
cd /c/Users/jason/Desktop/game/coderyoMC/test-harness/lod-soak/run-soak || exit 1
END=$(( $(date +%s) + 1300 ))
n=0
while [ "$(date +%s)" -lt "$END" ]; do
  n=$((n+1))
  java -cp . MiniBot 127.0.0.1 15565 SoakBot 120 >> botloop.log 2>&1
  echo "[botloop] reconnect #$n at $(date +%H:%M:%S)" >> botloop.log
  sleep 1
done
echo "[botloop] DONE after $n connects" >> botloop.log
