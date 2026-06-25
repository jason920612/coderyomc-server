#!/usr/bin/env bash
# coderyoMC CPU SIMD/SoA/branch feasibility probe (#21) - standalone, no server build.
# Requires Temurin JDK 25 (jdk.incubator.vector present). Windows Git Bash or any *nix.
set -euo pipefail
cd "$(dirname "$0")"

echo "== java version =="
java -version

echo "== compile =="
javac --add-modules jdk.incubator.vector SimdFeasibility.java

echo "== run (best-of-N internal trials; run a few times to confirm stability) =="
# -XX:-TieredStopAtLevel keeps full C2; default is fine. We keep flags minimal & honest.
java --add-modules jdk.incubator.vector SimdFeasibility

echo
echo "Done. See RESULTS.md for the recorded numbers on the reference machine."
