#!/usr/bin/env bash
# Standalone entity-GPU feasibility microbenchmark (#15).
# Compiles + runs a real OpenCL-vs-CPU benchmark on the system GPU.
# No server build, no applyAllPatches, no gradle daemon -- just javac/java
# against the LWJGL 3.3.6 jars from the Gradle module cache.
set -euo pipefail
cd "$(dirname "$0")"

LWJGL_VER=3.3.6
GC="${HOME}/.gradle/caches/modules-2/files-2.1/org.lwjgl"

find_jar() { # $1 = artifact dir, $2 = filename
  find "$GC/$1/$LWJGL_VER" -name "$2" 2>/dev/null | head -1
}

CORE_U=$(find_jar lwjgl       "lwjgl-${LWJGL_VER}.jar")
NAT_U=$(find_jar  lwjgl       "lwjgl-${LWJGL_VER}-natives-windows.jar")
OCL_U=$(find_jar  lwjgl-opencl "lwjgl-opencl-${LWJGL_VER}.jar")

if [[ -z "$CORE_U" || -z "$OCL_U" || -z "$NAT_U" ]]; then
  echo "ERROR: LWJGL $LWJGL_VER jars not found in $GC" >&2
  echo "  core=$CORE_U  opencl=$OCL_U  natives=$NAT_U" >&2
  echo "Run any gradle task that pulls lwjgl-opencl:$LWJGL_VER first, then re-run." >&2
  exit 1
fi

# Windows JVM needs Windows-style paths in the classpath.
if command -v cygpath >/dev/null 2>&1; then
  CORE=$(cygpath -w "$CORE_U"); NAT=$(cygpath -w "$NAT_U"); OCL=$(cygpath -w "$OCL_U")
  OUT=$(cygpath -w "$(pwd)/out"); SEP=';'
else
  CORE="$CORE_U"; NAT="$NAT_U"; OCL="$OCL_U"; OUT="$(pwd)/out"; SEP=':'
fi

mkdir -p out
echo ">> compiling..."
javac -d out -cp "${CORE}${SEP}${OCL}" src/EntityGpuFeasibility.java
echo ">> running on real OpenCL GPU device..."
java -cp "${OUT}${SEP}${CORE}${SEP}${NAT}${SEP}${OCL}" EntityGpuFeasibility
