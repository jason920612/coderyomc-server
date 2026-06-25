#!/usr/bin/env bash
#
# determinism-e2e.sh -- worldgen determinism e2e for issue #8.
#
# Boots the REAL coderyo paperclip server (production path, no mocks) with a
# FIXED level-seed, forceloads + fully generates a FIXED area, flushes the world
# to disk, stops, then digests the generated region files (terrain_digest.py).
#
# It does this TWICE per configuration in two FRESH worlds (same seed) and
# compares the two digests:
#   - region.enabled=false  -> is the BASELINE (upstream Moonrise) deterministic?
#   - region.enabled=true   -> does our regionization change determinism?
#
# Same seed + deterministic worldgen  =>  identical digests across both boots.
#
# Usage: determinism-e2e.sh --jar <paperclip.jar> [--seed N] [--port-offset N]
#                           [--mode both|false|true] [--radius R]
set -u
set -o pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
JAR=""
SEED="8888424242"
PORT_OFFSET=0
MODE="both"
RADIUS=3            # forceload square -R..R chunks => (2R+1)^2 chunks generated
BOOT_TIMEOUT=300
GEN_WAIT=45         # seconds to let generation + save complete
JAVA_BIN="java"
HEAP_MB=3072

die() { echo "[det][FATAL] $*" >&2; exit 4; }
log() { echo "[det] $*" >&2; }

while [ $# -gt 0 ]; do
  case "$1" in
    --jar)          JAR="${2:?}"; shift 2;;
    --seed)         SEED="${2:?}"; shift 2;;
    --port-offset)  PORT_OFFSET="${2:?}"; shift 2;;
    --mode)         MODE="${2:?}"; shift 2;;
    --radius)       RADIUS="${2:?}"; shift 2;;
    --gen-wait)     GEN_WAIT="${2:?}"; shift 2;;
    --java)         JAVA_BIN="${2:?}"; shift 2;;
    --heap)         HEAP_MB="${2:?}"; shift 2;;
    *) die "unknown arg: $1";;
  esac
done
[ -n "$JAR" ] || die "--jar required"
[ -f "$JAR" ] || die "jar not found: $JAR"
JAR="$(cd "$(dirname "$JAR")" && pwd)/$(basename "$JAR")"

PORT=$(( 15565 + PORT_OFFSET ))
[ "$PORT" -eq 25565 ] && die "refusing port 25565"

PY=python
command -v python >/dev/null 2>&1 || PY=py

# Boot one server, generate the fixed area, digest. Args: <run-dir> <enabled 0|1>
# Echoes the digest line to stdout (TERRAIN_DIGEST <hex>).
boot_and_digest() {
  local run_dir="$1" enabled="$2"
  rm -rf "$run_dir"; mkdir -p "$run_dir"
  cat > "$run_dir/server.properties" <<EOF
server-port=$PORT
online-mode=false
level-name=world
level-seed=$SEED
max-players=2
spawn-protection=0
view-distance=6
simulation-distance=6
sync-chunk-writes=true
EOF
  echo "eula=true" > "$run_dir/eula.txt"

  local log_file="$run_dir/server.log"
  : > "$log_file"

  # Build the forceload commands: a (2R+1) x (2R+1) square around 0,0.
  local lo=$(( -RADIUS )) hi=$(( RADIUS ))
  local cmds_file="$run_dir/.cmds"
  : > "$cmds_file"
  echo "forceload add ${lo} ${lo} ${hi} ${hi}" >> "$cmds_file"
  # give generation time, then flush to disk so the region files are complete.
  echo "save-off" >> "$cmds_file"
  echo "save-all flush" >> "$cmds_file"

  local jvm_flag=""
  if [ "$enabled" -eq 1 ]; then
    jvm_flag="-Dcoderyo.region.enabled=true"
  else
    jvm_flag="-Dcoderyo.region.enabled=false"
  fi

  log "boot ($([ "$enabled" -eq 1 ] && echo ENABLED || echo disabled)) seed=$SEED run=$run_dir"

  feeder() {
    local i
    for ((i=0; i<BOOT_TIMEOUT; i++)); do
      grep -qE 'Done \(' "$log_file" 2>/dev/null && break
      sleep 1
    done
    # forceload
    printf 'forceload add %d %d %d %d\n' "$lo" "$lo" "$hi" "$hi"
    # let generation run
    sleep "$GEN_WAIT"
    printf 'save-all flush\n'
    sleep 8
    printf 'stop\n'
    sleep 3
  }

  (
    cd "$run_dir" || exit 4
    feeder | "$JAVA_BIN" -Xms$((HEAP_MB/2))M -Xmx${HEAP_MB}M -Djava.awt.headless=true \
        $jvm_flag -jar "$JAR" --nogui --port "$PORT"
  ) >>"$log_file" 2>&1 &
  local pid=$!

  # wait for boot
  local booted=0
  for ((i=0; i<BOOT_TIMEOUT; i++)); do
    grep -qE 'Done \(' "$log_file" 2>/dev/null && { booted=1; break; }
    kill -0 "$pid" 2>/dev/null || break
    sleep 1
  done
  [ "$booted" -eq 1 ] || { log "boot FAILED ($run_dir)"; tail -25 "$log_file" >&2; }

  # wait for the pipeline / JVM to exit (port released)
  local waited=0 maxw=$(( GEN_WAIT + 120 ))
  for ((i=0; i<maxw; i++)); do
    local pp
    pp="$(netstat -ano 2>/dev/null | grep -E "[:.]$PORT[[:space:]].*LISTENING" | awk '{print $NF}' | head -1)"
    if [ -z "$pp" ] && ! kill -0 "$pid" 2>/dev/null; then waited=1; break; fi
    sleep 1
  done
  if [ "$waited" -ne 1 ]; then
    # force kill by port so we never orphan a server on the test port
    local pp
    pp="$(netstat -ano 2>/dev/null | grep -E "[:.]$PORT[[:space:]].*LISTENING" | awk '{print $NF}' | head -1)"
    [ -n "${pp:-}" ] && taskkill //F //PID "$pp" >/dev/null 2>&1 || true
    sleep 2
  fi

  # sanity: region tokens should appear iff enabled
  if [ "$enabled" -eq 1 ]; then
    grep -qE 'coderyoMC/region|RegionMerger|WorkStealingRegion|region R[0-9]' "$log_file" 2>/dev/null \
      && log "  (region tokens present, as expected)" \
      || log "  WARN: no region tokens in ENABLED run"
  else
    if grep -qE 'coderyo-region-worker|WorkStealingRegion|region R[0-9]+ formed' "$log_file" 2>/dev/null; then
      log "  WARN: region tokens present in DISABLED run (should be vanilla)"
    fi
  fi
  # single-writer violations
  local sw
  sw="$(grep -cE 'single-writer' "$log_file" 2>/dev/null || echo 0)"
  log "  single-writer lines: $sw"

  # digest the generated world (26.2 dimension layout:
  # world/dimensions/minecraft/overworld/region). Digest the overworld terrain.
  local regdir="$run_dir/world/dimensions/minecraft/overworld/region"
  [ -d "$regdir" ] || regdir="$run_dir/world/region"
  local dg
  dg="$("$PY" "$HERE/terrain_digest.py" "$regdir")"
  echo "$dg" | sed 's/^/  /' >&2
  echo "$dg" | grep '^TERRAIN_DIGEST ' | awk '{print $2}'
}

run_mode() {
  local enabled="$1" label="$2"
  log "================= MODE: $label ================="
  local d1 d2
  d1="$(boot_and_digest "$HERE/run-det-${label}-A" "$enabled")"
  d2="$(boot_and_digest "$HERE/run-det-${label}-B" "$enabled")"
  log "----- $label digests -----"
  log "  boot A: ${d1:-<none>}"
  log "  boot B: ${d2:-<none>}"
  if [ -n "$d1" ] && [ "$d1" = "$d2" ]; then
    log "  RESULT_${label}_DETERMINISTIC  (identical across two fixed-seed boots)"
    eval "DIG_${label}=$d1"
    return 0
  else
    log "  RESULT_${label}_NONDETERMINISTIC  (digests differ across boots!)"
    eval "DIG_${label}=DIFF"
    return 1
  fi
}

DIG_false=""; DIG_true=""
rc=0
case "$MODE" in
  false) run_mode 0 false || rc=1;;
  true)  run_mode 1 true  || rc=1;;
  both)
    run_mode 0 false || rc=1
    run_mode 1 true  || rc=1
    log "================= SUMMARY ================="
    log "  baseline (region.enabled=false): ${DIG_false}"
    log "  regionized (region.enabled=true): ${DIG_true}"
    if [ "$DIG_false" != "DIFF" ] && [ "$DIG_true" != "DIFF" ] && [ -n "$DIG_false" ] && [ "$DIG_false" = "$DIG_true" ]; then
      log "  RESULT_BASELINE_MATCHES_REGIONIZED  (enabled produces the SAME terrain as disabled)"
    fi
    ;;
  *) die "bad --mode: $MODE";;
esac

exit $rc
