#!/usr/bin/env bash
# Pull the TPS + "Server tick times (avg/min/max)" lines out of a server log,
# strip ANSI colour codes, and print them as plain rows so RESULTS.md can quote
# real observed MSPT/TPS under load.
#
# Usage: ./extract-mspt.sh <server.log>
set -u
LOG="${1:?usage: extract-mspt.sh server.log}"
sed 's/\x1b\[[0-9;]*m//g' "$LOG" \
  | grep -E 'TPS from last|Server tick times|^\[[0-9:]+ INFO\]: [?¦] *[0-9]' \
  | sed -E 's/^\[[0-9:]+ INFO\]: //; s/^[?¦] /  /'
