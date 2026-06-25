#!/usr/bin/env bash
# bench-worldgen.sh -- real worldgen pregeneration benchmark for issue #21 (CPU SIMD noise).
#
# Boots the REAL coderyo paperclip server (production path, no mocks), fixed seed, online-mode
# off, port 15565, region.enabled=false. Forceloads a fresh GRID x GRID tiling of 16x16-chunk
# blocks (the vanilla forceload cap is 256 chunks/command, args are BLOCK coords) FAR from spawn,
# so every chunk is freshly generated. Times wall-clock from the first forceload command until
# the freshly generated chunk count is stable, then stops the server.
#
# Robustness: hard-kills any prior bench server (by unique sysprop signature) before each run,
# fresh unique run dir per run, and counts ONLY the region files covering the generated area.
#
# Runs RUNS times each for -Dcoderyo.worldgen.simd.enabled=false (scalar) vs =true (SIMD/FMA),
# discards the first (warmup) of each, reports chunks/sec medians + speedup.
set -u
JAR="${1:?usage: bench-worldgen.sh <paperclip.jar>}"
JAR="$(cd "$(dirname "$JAR")" && pwd)/$(basename "$JAR")"
HERE="$(cd "$(dirname "$0")" && pwd)"
SEED=${SEED:-515151512121}
PORT=15565
GRID=${GRID:-3}                 # GRIDxGRID tiles of 16x16 chunks => (16*GRID)^2 chunks. 3 => 48x48 = 2304
RUNS=${RUNS:-4}
BOOT_TIMEOUT=180
GEN_TIMEOUT=300
JAVA_BIN=java
HEAP_MB=4096
SIG="CODERYO_SIMD_BENCH_MARKER"
[ "$PORT" -eq 25565 ] && { echo "refusing 25565"; exit 4; }
# Far-from-spawn origin in CHUNK coords (multiple of 16 for clean tiles, multiple of 32 for region).
BASE_CHUNK=${BASE_CHUNK:-512}   # chunk 512 = block 8192; region 16; far from spawn
TILES_PER=16                    # 16x16 chunks = 256 (the forceload cap)
SIDE_CHUNKS=$(( GRID * TILES_PER ))
TOTAL=$(( SIDE_CHUNKS * SIDE_CHUNKS ))
TARGET=$(( TOTAL * 90 / 100 ))
# region indices covering [BASE_CHUNK, BASE_CHUNK+SIDE_CHUNKS-1]
RLO=$(( BASE_CHUNK / 32 )); RHI=$(( (BASE_CHUNK + SIDE_CHUNKS - 1) / 32 ))

kill_bench() { powershell.exe -NoProfile -Command "Get-CimInstance Win32_Process -Filter \"Name='java.exe'\" | Where-Object { \$_.CommandLine -like '*$SIG*' } | ForEach-Object { Stop-Process -Id \$_.ProcessId -Force }" >/dev/null 2>&1; }
wait_port_free() { local i; for ((i=0;i<60;i++)); do netstat -ano 2>/dev/null | grep -q ":$PORT .*LISTENING" || return 0; sleep 1; done; }

count_fresh() {
  python - "$1/dimensions/minecraft/overworld/region" "$RLO" "$RHI" <<'PY' 2>/dev/null
import sys,os
d=sys.argv[1]; rlo,rhi=int(sys.argv[2]),int(sys.argv[3]); t=0
for rx in range(rlo,rhi+1):
  for rz in range(rlo,rhi+1):
    f=os.path.join(d,f"r.{rx}.{rz}.mca")
    if not os.path.exists(f): continue
    with open(f,'rb') as fh: h=fh.read(4096)
    t+=sum(1 for i in range(0,4096,4) if h[i:i+4]!=b'\x00\x00\x00\x00')
print(t)
PY
}

run_once() {  # <run-dir> <enabled 0|1> -> "MS <ms> CH <chunks>"
  local run_dir="$1" en="$2"
  kill_bench; wait_port_free
  rm -rf "$run_dir" 2>/dev/null; mkdir -p "$run_dir"
  cat > "$run_dir/server.properties" <<EOF
server-port=$PORT
online-mode=false
level-name=world
level-seed=$SEED
max-players=1
spawn-protection=0
view-distance=4
simulation-distance=4
sync-chunk-writes=true
EOF
  echo "eula=true" > "$run_dir/eula.txt"
  local log="$run_dir/server.log"; : > "$log"
  local tsf="$run_dir/.ts"; : > "$tsf"; rm -f "$tsf.start" "$tsf.end"
  local simd; [ "$en" -eq 1 ] && simd="-Dcoderyo.worldgen.simd.enabled=true" || simd="-Dcoderyo.worldgen.simd.enabled=false"

  feeder() {
    local i
    for ((i=0;i<BOOT_TIMEOUT;i++)); do grep -qE 'Done \(' "$log" 2>/dev/null && break; sleep 1; done
    if ! grep -qE 'Done \(' "$log" 2>/dev/null; then echo "BOOTFAIL" >> "$tsf"; printf 'stop\n'; sleep 2; return; fi
    sleep 2
    date +%s%3N > "$tsf.start"
    # tile GRIDxGRID forceload commands of 16x16-chunk (256-chunk) blocks, in BLOCK coords
    local gx gz
    for ((gx=0;gx<GRID;gx++)); do
      for ((gz=0;gz<GRID;gz++)); do
        local cx0=$(( (BASE_CHUNK + gx*TILES_PER) ))
        local cz0=$(( (BASE_CHUNK + gz*TILES_PER) ))
        local bx0=$(( cx0*16 ))           bz0=$(( cz0*16 ))
        local bx1=$(( (cx0+TILES_PER)*16 - 1 ))  bz1=$(( (cz0+TILES_PER)*16 - 1 ))
        printf 'forceload add %d %d %d %d\n' "$bx0" "$bz0" "$bx1" "$bz1"
        sleep 0.3
      done
    done
    local j prev=-1 stable=0
    for ((j=0;j<GEN_TIMEOUT;j++)); do
      printf 'save-all flush\n'
      sleep 2
      local c; c=$(count_fresh "$run_dir/world"); c=${c:-0}
      echo "poll $j chunks=$c" >> "$tsf"
      if [ "$c" -ge "$TARGET" ]; then
        [ "$c" -eq "$prev" ] && stable=$((stable+1)) || stable=0
        prev=$c
        [ "$stable" -ge 2 ] && break
      else
        prev=$c
      fi
    done
    date +%s%3N > "$tsf.end"
    sleep 1; printf 'stop\n'; sleep 2
  }

  ( cd "$run_dir" && feeder | "$JAVA_BIN" -Xms$((HEAP_MB/2))M -Xmx${HEAP_MB}M -Djava.awt.headless=true \
      -D${SIG}=1 -Dcoderyo.region.enabled=false $simd -jar "$JAR" --nogui --port "$PORT" ) >>"$log" 2>&1
  kill_bench

  local s e c
  s=$(cat "$tsf.start" 2>/dev/null); e=$(cat "$tsf.end" 2>/dev/null)
  c=$(count_fresh "$run_dir/world"); c=${c:-0}
  if [ -n "$s" ] && [ -n "$e" ] && [ "$c" -ge "$TARGET" ]; then echo "MS $(( e - s )) CH $c"; else echo "MS -1 CH $c"; fi
}

declare -a SCALAR SIMD
echo "config: GRID=$GRID side=${SIDE_CHUNKS}ch total=$TOTAL target=$TARGET regions r.[$RLO..$RHI]"
for cfg in 0 1; do
  tag=$([ $cfg -eq 1 ] && echo simd || echo scalar)
  for ((r=1;r<=RUNS;r++)); do
    out=$(run_once "$HERE/run-$tag-$r" "$cfg")
    ms=$(echo "$out" | awk '{print $2}'); ch=$(echo "$out" | awk '{print $4}')
    echo ">>> cfg=$tag run=$r ms=$ms chunks=$ch/$TOTAL"
    [ "$r" -eq 1 ] && continue
    [ "$ms" -gt 0 ] 2>/dev/null && { [ "$cfg" -eq 0 ] && SCALAR+=("$ms") || SIMD+=("$ms"); }
  done
done

med() { printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:int((a[NR/2]+a[NR/2+1])/2)}'; }
[ ${#SCALAR[@]} -gt 0 ] && [ ${#SIMD[@]} -gt 0 ] || { echo "INSUFFICIENT DATA scalar=(${SCALAR[*]:-}) simd=(${SIMD[*]:-})"; exit 1; }
ms_s=$(med "${SCALAR[@]}"); ms_v=$(med "${SIMD[@]}")
cps_s=$(python -c "print(f'{$TOTAL/($ms_s/1000.0):.1f}')"); cps_v=$(python -c "print(f'{$TOTAL/($ms_v/1000.0):.1f}')")
spd=$(python -c "print(f'{$ms_s/$ms_v:.3f}')")
echo "================ RESULT ($TOTAL fresh chunks, seed $SEED, GRID=$GRID @ chunk $BASE_CHUNK) ================"
echo "scalar  median ms=$ms_s  chunks/sec=$cps_s   samples=(${SCALAR[*]})"
echo "simd    median ms=$ms_v  chunks/sec=$cps_v   samples=(${SIMD[*]})"
echo "speedup (scalar_ms / simd_ms) = ${spd}x"
