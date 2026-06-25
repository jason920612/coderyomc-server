#!/usr/bin/env bash
# Drive the consolidation benchmark: N repeats per (scenario,config,count),
# collect the RESULT lines, print mean/stdev of settled MSPT per cell.
# Usage: ./run-all.sh <scenario> <mobs> [repeats]   (runs FULL and VANILLA)
set -u
SCN="${1:?scenario}"; MOBS="${2:?mobs}"; REP="${3:-3}"
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/results-$SCN-$MOBS.tsv"
: > "$OUT"
for MODE in VANILLA FULL; do
  for r in $(seq 1 "$REP"); do
    echo "=== $SCN $MODE $MOBS run $r/$REP ==="
    LINE=$("$HERE/bench.sh" "$SCN" "$MODE" "$MOBS" 2>&1 | grep -E '^RESULT' | tail -1)
    echo "$LINE"
    M=$(echo "$LINE" | grep -oE 'mspt_mean=[0-9.]+' | cut -d= -f2)
    A=$(echo "$LINE" | grep -oE 'alive=[0-9]+' | cut -d= -f2)
    C=$(echo "$LINE" | grep -oE 'crashes=[0-9]+' | cut -d= -f2)
    printf "%s\t%s\t%s\t%s\t%s\t%s\n" "$SCN" "$MODE" "$MOBS" "$M" "$A" "$C" >> "$OUT"
  done
done
echo "=== SUMMARY ($SCN @ $MOBS) ==="
awk -F'\t' '{s[$2]+=$4; ss[$2]+=$4*$4; n[$2]++; al[$2]=$5; cr[$2]+=$6}
END{for(m in s){mean=s[m]/n[m]; sd=sqrt(ss[m]/n[m]-mean*mean);
  printf "%-8s MSPT mean=%.2f stdev=%.2f ms  alive=%s crashes=%d (n=%d)\n",m,mean,sd,al[m],cr[m],n[m]}}' "$OUT"
