# CPU SIMD / SoA / Branch-Prediction Feasibility Probe (#21)

**Thesis under test:** the data-parallel work that **lost on GPU** (worldgen noise, entity
batches — proven ~7x raw compute but a net loss once PCIe transfer + dispatch overhead was
counted) should **win on CPU SIMD**, because the Java Vector API runs *in-register on the same
cores* — **no host↔device copy, no dispatch latency**. Confirmed below.

This is a **standalone micro-benchmark**. It does **not** build or patch the server. It is a
hand-rolled JMH-style harness (long JIT warmup → C2, many measured reps, best-of-trials, a
`volatile` blackhole sink + returned accumulators so the optimizer cannot delete the loop body).
No mocks — real measured `ns/element`.

---

## 0. Reference machine & SIMD capability

| Property | Value |
|---|---|
| CPU | AMD Ryzen, `AMD64 Family 25 Model 33` = **Zen 3** |
| Cores (logical) | 16 |
| JDK | Temurin **25.0.3+9** (LTS), `jdk.incubator.vector` present |
| OS / arch | Windows 11 / amd64 |
| `FloatVector.SPECIES_PREFERRED` | **8 lanes, 256-bit** |
| `DoubleVector.SPECIES_PREFERRED` | 4 lanes, 256-bit |
| `IntVector.SPECIES_PREFERRED` | 8 lanes, 256-bit |
| **ISA the Vector API dispatches to** | **AVX2 (256-bit)** |

> Zen 3 has AVX2 but **not** AVX-512, so the JVM picks the 256-bit species (8 float lanes).
> Theoretical ceiling for a perfectly-vectorizable float loop is therefore **~8x**; we get
> 5.5–6x on real noise math (the rest lost to the scalar floor-trunc + serial dependencies).
> On an AVX-512 box (e.g. recent Intel server / Zen 4+ partial) the species would be 512-bit
> / 16 float lanes and these SIMD numbers would roughly double.

---

## 1. Results (ns/element; speedups are the median of several runs, very stable)

### [2] Noise-style math — the GPU loser (4-octave Perlin-ish gradient-dot over ~1M lattice points, float)

| Variant | ns/elem | Speedup vs scalar |
|---|---:|---:|
| scalar baseline | ~19.5 | 1.00x |
| **Vector API (SIMD, AVX2)** | ~3.3 | **~5.8x** |

- FP caveat: SIMD reduction reassociates the float adds → result differs from scalar in the last
  ULPs (`relErr ≈ 3e-6`, "within tolerance"). **This matters for worldgen determinism** — a
  vectorized noise function is *not* bit-identical to the scalar one and may not be identical
  across lane widths/machines. Only vectorize worldgen where exact cross-machine reproducibility
  is not contractual, **or** fix the lane reduction order to be deterministic.

> **Verdict: YES — CPU SIMD wins where GPU lost.** ~5.8x speedup with *zero* transfer cost, on the
> same cores, no dispatch. This is the headline result: the noise workload that was a net loss on
> GPU is a clean ~6x win on CPU SIMD.

### [3] Entity integration `pos += vel*dt` over ~1M entities (AoS vs SoA-scalar vs SoA-SIMD)

| Variant | ns/elem | Speedup |
|---|---:|---:|
| AoS (array of `Entity` objects, refs shuffled = realistic live-entity heap scatter) | ~4.9 | 1.00x |
| SoA scalar (`float[] x,y,z,vx,vy,vz`) | ~0.79 | **~6.2x vs AoS** (pure cache/layout) |
| **SoA + Vector API (SIMD)** | ~0.26 | **~3.1x vs SoA-scalar; ~19x vs AoS total** |

- The **biggest single win here is the data layout** (AoS→SoA = ~6x) — that's the cache effect,
  before any SIMD. SIMD then adds another ~3x on top. **SoA is the prerequisite**: you cannot
  vectorize AoS without gather/scatter, which kills the win.

### [4] Branch prediction — `sum(a[i] > T)` over ~2M ints

| Variant | ns/elem | Note |
|---|---:|---|
| branchy, **RANDOM** data | ~3.07 | branch mispredicts ~50% of the time |
| branchy, **SORTED** data | ~0.26 | same code, predictable branch → **~11.7x faster** |
| branchless (mask arithmetic) | ~0.115 | **~26.7x** vs branchy-random |
| **SIMD masked (Vector API)** | ~0.075 | **~40x** vs branchy-random |

- Quantifies the "make data branch-predictable" payoff: the *identical* loop is **~11.7x slower**
  purely because the data order makes the branch unpredictable. Removing the branch entirely
  (branchless / SIMD mask) is **~27–40x**.

### [5] Bulk transform `out = clamp(a*k + b, 0, 15)` (lighting / heightmap style, ~2M floats)

| Variant | ns/elem | Speedup vs scalar |
|---|---:|---:|
| scalar | ~3.71 | 1.00x |
| **Vector API (SIMD)** | ~0.145 | **~25x** |

- **Honest caveat:** 25x is well above the 8-lane ceiling, which means the *scalar* baseline is
  slow — the `?:` clamp (`v<0?0:(v>15?15:v)`) introduces branches C2 does **not** auto-vectorize,
  while the SIMD path uses branchless `max`/`min`. So this number conflates "SIMD" with "removed
  the clamp branches". The realistic SIMD-only contribution is ~6–8x; the rest is the same
  branch-elimination win as [4]. Take 25x as "SoA+SIMD+branchless combined", not "SIMD alone".

---

## 2. Recommendation — which server hot-paths to convert (priority order)

1. **Worldgen noise (Perlin/Simplex octave sampling, density functions).** ~6x on AVX2, ~12x on
   AVX-512 hardware, no transfer cost. **This is the GPU-loser that becomes a CPU-SIMD winner.**
   Gate behind a determinism decision: vectorized reductions are not bit-identical. Convert the
   noise sampler to operate on `float[]`/`double[]` column batches (a chunk column = 16×16×384
   cells is a natural SoA batch).

2. **Entity / projectile / particle integration (position/velocity update, AABB bulk checks).**
   First do **AoS→SoA** (the ~6x cache win is free and needs no Vector API), then SIMD the
   integration (+3x). Combined ~19x. The regionized scheduler already batches entities per region
   — feed those batches as SoA columns.

3. **Bulk grid transforms: lighting propagation, heightmap recompute, biome/temperature maps,
   palette remaps.** Simple `a*k+b`/clamp/threshold maps over flat arrays → ~6–8x SIMD, and the
   clamp-branch removal alone is a large win even without Vector API.

4. **Any hot loop with a data-dependent branch over large arrays** (visibility/cull filters,
   "alive" masks, light-level thresholds): make the data branch-predictable (sort/partition) or
   go branchless/masked — **11–40x** is on the table for the worst-mispredicting loops.

### What's NOT worth it
- Loops C2 already auto-vectorizes (trivial `c[i]=a[i]+b[i]` with no branches) — the Vector API
  adds little there; measure first.
- Gather/scatter-bound or pointer-chasing loops (linked entity lists, hash lookups, AoS without a
  layout change) — SIMD gather on AVX2 is slow; **fix the layout (SoA) first or skip**.
- Anything where worldgen output must be **bit-for-bit reproducible** across machines/JVMs unless
  the reduction order is pinned.

### Per-machine note
All numbers above are **AVX2 / 256-bit (8 float lanes)** on Zen 3. The benchmark prints
`SPECIES_PREFERRED` width at startup; on AVX-512 hardware re-run to get the doubled lane count
before committing server hot-loops to a fixed width — the Vector API auto-adapts, but the
*payoff* scales with lane width.

---

## Reproduce
```bash
cd test-harness/cpu-simd-feasibility
./run.sh            # or:
javac --add-modules jdk.incubator.vector SimdFeasibility.java
java  --add-modules jdk.incubator.vector SimdFeasibility
```
Run it a few times — the internal harness already does warmup + best-of-trials, and the reported
speedups are stable to within a few percent run-to-run.
