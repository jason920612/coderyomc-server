# Entity-GPU Feasibility Probe (#15)

Standalone OpenCL-vs-CPU microbenchmark to decide whether entity-style data-parallel
compute is worth offloading to the GPU in coderyoMC's regionized entity tick **before**
investing in the large SoA-extraction integration effort.

GPU worldgen was already proven NOT worth it (~7x slower: low arithmetic intensity vs.
PCIe/dispatch overhead). This probe asks the same question for entities, cheaply.

## TL;DR / Recommendation

- **Position/velocity integration (cheap): DO NOT offload.** The compute is so trivial that
  16-core CPU finishes in **<0.3 ms even at N=100,000**. The GPU's fixed ~0.4 ms round-trip
  floor means it **never wins** in the tested range. Same overhead trap as worldgen.
- **AABB broad-phase collision (moderate): borderline, DO NOT offload.** Roughly break-even.
  GPU only starts edging ahead at **N >= 50,000** (and only ~1.3-1.5x), where real
  per-region active-entity counts are tens to low thousands. Not worth the integration risk.
- **Batched pathfinding-style cost eval (heavy): GPU wins big, but the realistic-N caveat applies.**
  GPU beats all-cores CPU from **N >= ~1,000** and is **10-100x faster** by N=10k-100k.
  This is the *only* kernel with enough arithmetic intensity to amortize dispatch. **If** a
  future feature batches thousands of agents through an identical heavy heuristic in one tick,
  GPU offload pays off. Vanilla MC mob pathfinding does **not** look like this (it is irregular,
  branchy, stateful graph search over disparate goals -- not a uniform SIMD batch), so this win
  is conditional on a workload we do not currently have.

**Bottom line for #15: do NOT integrate entity-GPU now.** The two kernels that map to real
MC entity work (integration, collision) do not beat a 16-core CPU at realistic per-region
entity counts. The only kernel that wins (heavy uniform batched cost eval) does not match how
MC entities actually tick. Revisit only if a genuinely heavy, uniform, thousands-wide entity
batch appears. This is the same conclusion as worldgen, for the same reason: MC entity batches
are too small and too cheap to amortize host<->device overhead.

## Hardware / Environment

| | |
|---|---|
| GPU | NVIDIA GeForce RTX 4060 (8 GB, 24 CUs, 2505 MHz) |
| OpenCL platform | **NVIDIA CUDA** (confirmed real GPU device, `CL_DEVICE_TYPE_GPU`, not a CPU ICD fallback) |
| CPU | 16 logical cores (`Runtime.availableProcessors()`) |
| JDK | Temurin 25.0.3 |
| LWJGL | 3.3.6 (`lwjgl` + `lwjgl-opencl` + natives-windows) |
| OS | Windows 11 |

The benchmark **aborts** if no GPU OpenCL device is found -- it explicitly refuses a CPU
fallback so a "GPU" number can never silently be a CPU number.

## Methodology

- Three representative entity-style kernels, each implemented **three ways**:
  1. **GPU (OpenCL)** -- total wall time including host->device transfer + dispatch + device->host
     readback (the honest end-to-end cost), plus isolated kernel time and transfer time via
     `CL_QUEUE_PROFILING_ENABLE` event timestamps.
  2. **CPU single-thread** (Java).
  3. **CPU all-cores** (Java, `FixedThreadPool` over all 16 cores) -- *the honest competitor*,
     since coderyoMC's core already parallelizes entities across regions.
- Sizes **N = 100, 1,000, 10,000, 50,000, 100,000**.
- **8 measured runs** after **3 warmup runs** (warmup discarded) per configuration. Mean + stdev reported.
- GPU "total" includes allocating/writing all input buffers, the NDRange dispatch, and reading
  results back, bracketed by `clFinish`. This is what an integration would actually pay per tick.
- Fast-relaxed-math enabled on the OpenCL build; equivalent `float` math on the CPU side.

### The three kernels

- **(a) INTEGRATE** -- `vel.y += g*dt; pos += vel*dt` over N entities. ~7 FLOPs/entity.
  Represents projectile/particle/falling-entity physics. *Cheap.*
- **(b) COLLISION** -- AABB broad-phase via a uniform spatial grid. The grid resolution scales
  with N (`GRID = cbrt(N)`, ~1 entity/cell) so the transferred acceleration structure is **O(N)**,
  not O(world^3) -- a fair test of a real compact/hashed broad-phase. Each entity checks its own
  cell + 26 neighbors for overlaps. *Moderate.*
- **(c) PATHFIND** -- for each of N agents, evaluate an A*-style heuristic cost over a 15x15
  (K=7) local neighborhood with a synthetic terrain field (sin/cos/sqrt per cell). ~225 cells x
  several transcendentals/entity. *Heavy -- the heaviest plausible entity-GPU target.*

## Raw Results (representative run; means in ms, 8 runs each)

GPU total = end-to-end (transfer + dispatch + readback). `kernel`/`xfer` are the profiled splits.

### (a) INTEGRATE -- cheap

| N | CPU 1-thread | CPU all-cores | GPU total | GPU kernel | GPU xfer | GPU vs all-cores |
|---:|---:|---:|---:|---:|---:|---:|
| 100     | 0.007 | 0.118 | 0.388 | 0.004 | 0.004 | 3.3x slower |
| 1,000   | 0.003 | 0.103 | 0.419 | 0.004 | 0.005 | 4.1x slower |
| 10,000  | 0.031 | 0.201 | 0.544 | 0.014 | 0.031 | 2.7x slower |
| 50,000  | 0.146 | 0.196 | 0.916 | 0.008 | 0.140 | 4.7x slower |
| 100,000 | 0.088 | 0.071 | 1.557 | 0.014 | 0.285 | 21.8x slower |

**Crossover: NONE in range.** CPU is so fast the GPU never amortizes its floor.

### (b) COLLISION -- moderate (O(N) grid)

| N | CPU 1-thread | CPU all-cores | GPU total | GPU kernel | GPU xfer | GPU vs all-cores |
|---:|---:|---:|---:|---:|---:|---:|
| 100     | 0.326  | 0.307 | 0.421 | 0.015 | 0.005 | 1.4x slower |
| 1,000   | 0.458  | ~0.1-2.5 (noisy) | 0.433 | 0.023 | 0.007 | ~break-even |
| 10,000  | 2.804  | 0.436 | 0.604 | 0.040 | 0.042 | 1.4x slower |
| 50,000  | 16.870 | 2.520 | 1.538 | 0.196 | 0.196 | **1.6x faster** |
| 100,000 | 34.378 | 3.728 | 2.556 | 0.356 | 0.402 | **1.5x faster** |

**Crossover: ~N >= 50,000** for a reliable GPU win. Below that it is a wash or CPU wins. At
small N both are sub-millisecond and the all-cores thread-pool wakeup latency makes the ratio
noisy (irrelevant -- nobody needs a GPU for a 0.4 ms task).

### (c) PATHFIND -- heavy

| N | CPU 1-thread | CPU all-cores | GPU total | GPU kernel | GPU xfer | GPU vs all-cores |
|---:|---:|---:|---:|---:|---:|---:|
| 100     | 0.685   | 1.207  | 0.417 | 0.024 | 0.005 | ~break-even |
| 1,000   | 6.187   | 0.815  | 0.419 | 0.042 | 0.006 | **1.9x faster** |
| 10,000  | 61.906  | 7.725  | 0.441 | 0.012 | 0.019 | **17x faster** |
| 50,000  | 318.047 | 35.913 | 0.674 | 0.050 | 0.082 | **53x faster** |
| 100,000 | 633.127 | 73.413 | 4.765 | 1.870 | 1.212 | **15x faster** |

**Crossover: ~N >= 1,000.** Heavy arithmetic intensity dwarfs the dispatch floor; GPU scales
almost flat while CPU scales linearly. This is the textbook "GPU-friendly" workload.

## Fixed dispatch / transfer overhead

- **GPU round-trip floor: ~0.38-0.42 ms** even at N=100 (allocate + tiny write + dispatch +
  tiny read + `clFinish`). This is the price of admission per offloaded batch.
- This floor is **much lower than the ~5 ms** sometimes cited for worldgen-style offload,
  because these transfers are small and non-blocking; the floor here is dominated by dispatch
  + queue/`clFinish` latency, not PCIe bandwidth.
- Transfer cost is N-proportional and modest: e.g. INTEGRATE at N=100k moves ~2.4 MB and pays
  ~0.29 ms; PATHFIND readback at N=100k pays ~1.2 ms. Bandwidth is never the bottleneck at
  these sizes -- **dispatch latency is**, which is exactly why cheap kernels lose.

## Why this still says "stop" despite the PATHFIND win

The crossover for the kernels that model *real* MC entity work (integration, collision) sits at
**N >= 50,000+**, while realistic per-region active-entity counts are **tens to low thousands**.
At those counts a 16-core CPU already finishes integration in microseconds and collision in
~1 ms -- there is nothing to offload.

The only big GPU win (PATHFIND) requires **thousands of agents running an identical, branch-free,
heavy heuristic in lockstep**. Real Minecraft pathfinding is the opposite: irregular A* graph
search, per-mob early-outs, divergent goals and states -- a poor SIMD fit that would lose most
of the modeled speedup to warp divergence and would need a major redesign to batch at all.

So: **no realistic win for the entity tick as it exists. Recommend NOT integrating entity-GPU
(#15), same overhead/intensity trap as worldgen.** Keep this benchmark as the gate: only revisit
if a concrete feature introduces a heavy, uniform, thousands-wide entity batch.

## Reproduce

```bash
cd test-harness/gpu-feasibility
./run.sh        # compiles + runs against the real GPU, prints the tables above
```

Requires LWJGL 3.3.6 (`lwjgl`, `lwjgl-opencl`, natives-windows) -- resolved from the Gradle
module cache by `run.sh`; no server build, no `applyAllPatches`, no gradle daemon.
