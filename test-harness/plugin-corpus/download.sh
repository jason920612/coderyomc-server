#!/usr/bin/env bash
#
# download.sh -- fetch the real-plugin compat corpus jars from manifest.tsv
# into a gitignored jars/ dir. Idempotent: skips files already present.
#
# The jars are deliberately NOT committed (licensing + size). This script is
# the reproducible way to rebuild the corpus on any machine.
#
# Usage:
#   ./download.sh            # download all into ./jars/
#   ./download.sh --force    # re-download even if present
#   ./download.sh --list     # just print what would be fetched
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$HERE/manifest.tsv"
JARS="$HERE/jars"

FORCE=0
LIST=0
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    --list)  LIST=1 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $a" >&2; exit 2 ;;
  esac
done

[ -f "$MANIFEST" ] || { echo "manifest not found: $MANIFEST" >&2; exit 1; }
mkdir -p "$JARS"

# columns: plugin version declared_mc_support declares_26_2 source url notes
n=0
fail=0
# skip header (NR>1)
while IFS=$'\t' read -r plugin version mcsup decl26 source url notes; do
  [ "$plugin" = "plugin" ] && continue   # header guard
  [ -z "${plugin:-}" ] && continue
  n=$((n+1))
  out="$JARS/${plugin}-${version}.jar"
  if [ "$LIST" = "1" ]; then
    printf '%-16s %-24s 26.2=%-3s  %s\n' "$plugin" "$version" "$decl26" "$url"
    continue
  fi
  if [ -f "$out" ] && [ "$FORCE" = "0" ]; then
    echo "[skip] $plugin $version (already present)"
    continue
  fi
  echo "[get ] $plugin $version  <- $url"
  if curl -fsSL --retry 3 -o "$out.tmp" "$url"; then
    mv "$out.tmp" "$out"
    sz=$(wc -c < "$out" 2>/dev/null || echo '?')
    echo "       -> $out (${sz} bytes)"
  else
    echo "       !! FAILED to fetch $plugin $version" >&2
    rm -f "$out.tmp"
    fail=$((fail+1))
  fi
done < "$MANIFEST"

if [ "$LIST" = "1" ]; then exit 0; fi
echo "----"
echo "done: $((n-fail))/$n fetched into $JARS  (failures: $fail)"
[ "$fail" -eq 0 ]
