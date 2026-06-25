# P2 — GPU worldgen-noise e2e parity harness

Real-production-path verification for the `com.coderyo.compute` GPU offload (design-spec §6, §8.3).
**No unit tests** — this boots a real paperclip server, generates real terrain, and observes behaviour.

## What it proves

1. **GPU↔CPU bit-exact parity (the core deliverable).** Boot with `-Dgpu.worldgen.enabled=true`.
   `ComputeBackendRegistry` probes the real OpenCL device (RTX 4060), builds the
   `ImprovedNoise` kernel, samples a 2048-point lattice on the GPU, and compares it
   against the scalar CPU twin with tolerance `0.0` (bit-exact). The log line
   `selected backend: opencl (CPU-parity self-check passed)` means the GPU kernel
   reproduced vanilla noise bit-for-bit and was selected. If parity fails the
   registry transparently falls back to CPU (`falling back to CPU. Reason: ...`).

2. **Transparent CPU fallback.** With no GPU / no LWJGL native / a parity miss, the
   registry selects CPU and the server still generates terrain correctly.

3. **CPU-routed worldgen is unchanged.** With `gpu.worldgen.enabled=false` (default),
   `DensityComputeBridge.fillArray` delegates to the exact upstream `fillArray`, so
   terrain is byte-for-byte vanilla.

## Run

```bash
# from the repo root, after ./gradlew :coderyo-server:createPaperclipJar
cp -r test-harness/p2-gpu-parity run/ && cd run/p2-gpu-parity
bash drive.sh cpu  false   # CPU baseline
bash drive.sh gpu  true    # OpenCL probe + parity self-check + terrain
```

`drive.sh` boots the real jar (`--nogui`, JDK 25), forceloads a fixed 9×9 chunk area
from a fixed seed, saves, and stops. `terrain_digest.py` then computes a terrain-only
SHA-256 (block_states + biomes + Heightmaps of `minecraft:full` chunks in a fixed
window), excluding time-varying metadata.

## Honest caveat on whole-chunk terrain hashing

This tree's chunk generation is **not bit-reproducible run-to-run** even with a fixed
seed — feature/decoration placement varies between boots (a property of the
pre-existing P1 multithreaded chunk-gen path, independent of P2). Two identical CPU
boots produce different terrain digests. Therefore P2 parity is asserted at the
**noise/density compute layer** — exactly the layer the `ComputeBackend` operates on —
via the bit-exact OpenCL-vs-CPU self-check, not via a whole-chunk terrain hash.
