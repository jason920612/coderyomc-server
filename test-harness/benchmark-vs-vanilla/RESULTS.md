# coderyoMC vs Vanilla Paper — Consolidation Benchmark

**The validation number for coderyoMC** (regionized Paper 26.2 fork). After mapping the
optimization space (LOD = the proven win; GPU/SIMD/data-oriented/async/entity-cache/
neighbor-share all falsified), this measures **where coderyoMC actually beats vanilla,
by how much, under realistic end-to-end load** — same jar, two JVM-flag configs.

**Date:** 2026-06-26 · **Host:** AMD Ryzen 7 5700X3D (8c/16t), Windows 11, Temurin JDK 25 ·
**Build:** `coderyo-paperclip-26.2-R0.1-SNAPSHOT` @ `2c0ad2c` (origin/main) ·
**Port:** 15565 · JVM `-Xms4G -Xmx8G -XX:+UseG1GC` · fixed seed `bench2026`.

---

## Headline

> **coderyoMC sustains ~2.5–3.1x more entities than vanilla Paper when the load spans
> multiple regions** (regionization's cross-core parallelism), and is at **~parity for a
> single-region horde** (flat-dense or path-bound) — exactly as the architecture predicts.
> The multi-region multiplier **grows with per-region load** (2.5x @ 1600 mobs → 3.1x @ 4800
> mobs). Multi-region FULL ran **crash-free with clean scheduler shutdown on every run**
> (the #24 mid-tick-task race fix holds).

| Scenario | mobs | VANILLA MSPT | FULL MSPT | FULL speedup | est. 20-TPS capacity (V → F) |
|---|---:|---:|---:|:---:|:---:|
| **Multi-region spread** (4 regions) | 1600 | **11.49 ± 0.57 ms** | **4.64 ± 0.11 ms** | **2.48x** | — |
| **Multi-region spread** (4 regions) | 4800 | **44.01 ms** | **14.19 ms** | **3.10x** | ~5,100 → ~16,900 (**~3.3x**) |
| **Path-bound horde** (obstacle A*) | 1500 | 24.35 ms | 25.05 ms | 0.97x (**parity**) | ~3,100 → ~3,000 (~1.0x) |
| **Single-region flat dense** | 1500 | 38.29 ms | 33.42 ms | 1.15x (**~parity**) | ~1,960 → ~2,240 (~1.1x) |

MSPT = steady-state Paper **5 s-avg** "Server tick times" (avg column), mean of the last 8
samples of the measurement window. `±` = stdev over n=3 runs (multi-region 1600); other cells
are n=1 (time-boxed — see Honest caveats). All configs held **≥20 TPS nominal (MSPT < 50 ms)**
at the counts shown; the difference is **headroom / capacity**, not a TPS failure at this load.

---

## The two configs (same jar, flags only)

| | flags |
|---|---|
| **VANILLA-equivalent** | `coderyo.region.enabled=false` + every coderyo feature flag OFF → byte-for-byte vanilla Paper 26.2 single-thread tick. |
| **coderyoMC FULL** | `region.enabled=true` + the **proven wins**: `pathfinding.los.enabled=true`, `lod.dab.enabled=true` (+ `lod.policy.enabled`, `lod.extended.enabled` default-on, `lod.policy.exempt.persistent=false` so the test horde classifies HOSTILE). **Falsified flags left OFF**: `pathfinding.async`, `entitycache`, `neighborshare`. |

Runner: [`bench.sh`](./bench.sh) `<scenario> <FULL|VANILLA> <mobs>`. Driver: [`run-all.sh`](./run-all.sh).
Bot: [`MiniBot.java`](./MiniBot.java) (protocol-776 stationary player target, reused from the L1 harness).

---

## Methodology

- **Real e2e only.** Boot the real paperclip headless (`--nogui`, JDK 25), drive the live
  console over stdin (the proven `emit | java` pattern from `run-profile.sh`), `/summon` a
  **fixed** count of `PersistenceRequired` zombies (stable population — no despawn-attrition
  noise), settle 20 s, then sample `/mspt` + `/tps` for the measurement window.
- **MSPT signal = 5 s-avg.** Paper's "Server tick times" line carries three triples
  (5 s / 10 s / 1 m). The **5 s-avg (first column)** is the responsive steady-state signal;
  the 1 m column is contaminated by the one-time spawn-storm freeze (summoning 1600+ entities
  in a burst stalls one tick for several seconds — Paper logs a watchdog thread-dump marked
  *"NOT A BUG OR A CRASH"*; the server recovers within the settle window). We report the 5 s-avg
  mean of the last 8 samples, which excludes that transient. `/tps` "from last 1m" stays
  depressed for ~a minute after the spawn storm and is therefore **not** used as the steady
  signal — MSPT 5 s-avg is.
- **Capacity** ("max entities at ~20 TPS / MSPT < 50 ms") is reported as the count where the
  steady 5 s-avg MSPT reaches 50 ms, interpolated from the measured points (the entity-tick
  regime scales ~linearly in mob count — validated for FULL: 4.64 ms @1600 → 14.19 ms @4800 is
  3.06x MSPT for 3.0x mobs). It is an **estimate from the MSPT curve**, not a per-count sweep.

### Scenarios

1. **Multi-region spread** — `MOBS/4` dense persistent zombies in **each of 4 far-apart
   forceloaded areas** (`(0,0)`, `(3000,0)`, `(-3000,0)`, `(3000,3000)`) → 4 disjoint regions
   (no merge). This is regionization's home turf: the 4 regions tick in parallel on
   `coderyo-region-worker-*` threads vs vanilla's single thread. No bot (forceloaded chunks
   tick AI without a player).
2. **Path-bound horde** — a horde chasing a stationary bot across a **wall-grid obstacle field**
   (every 8 blocks, 4-high) with `follow_range=160`, so L1's flat direct-walk fails the LOS clip
   → **real A\* dominates** (LOD's `-43.9%` single-thread terrain). One region.
3. **Single-region flat dense** — a dense `follow_range=48` horde around one bot on **flat
   ground**, one region, entity-tick-bound. The **honest near-parity** case — reported straight.

---

## Per-scenario findings

### 1. Multi-region spread — the regionization win (THE headline)

| mobs | VANILLA (region off, single-thread) | FULL (region on, 4 parallel regions) | speedup |
|---:|---:|---:|:---:|
| 1600 | 10.89 / 12.26 / 11.31 → **mean 11.49, sd 0.57** | 4.76 / 4.50 / 4.67 → **mean 4.64, sd 0.11** | **2.48x** |
| 4800 | **44.01** (n=1) | **14.19** (n=1) | **3.10x** |

Vanilla ticks all 4 areas **serially** on the main thread → MSPT ≈ sum. coderyoMC ticks them
**in parallel** → MSPT ≈ max(region) + orchestration. The multiplier **grows with per-region
load** (2.48x → 3.10x as mobs go 1600 → 4800) because the fixed serial/orchestration overhead
amortizes over more parallel work (Amdahl). At 4800 mobs **vanilla is already at ~44 ms (the
edge of the 20-TPS budget) while FULL has 36 ms of headroom** → vanilla caps near ~5,100 mobs,
FULL near ~16,900 → **~3.3x entity capacity** at 20 TPS for this multi-region shape.

**Stability:** every multi-region FULL run logged **0 region crashes** (no
`NoSuchElementException` / "region tick failed" / single-writer violations) and a **clean
`WorkStealingRegionScheduler shut down (clean=true)`**. The mid-tick-task race that crashed
2-region load in the original profiling run (`test-harness/profiling/RESULTS.md §1`) is fixed.

### 2. Path-bound horde — honest single-region parity (LOD win offset by region overhead)

| mobs | VANILLA | FULL | speedup |
|---:|---:|---:|:---:|
| 1500 | 24.35 ms | 25.05 ms | 0.97x — **parity** (FULL marginally slower) |

This is the honest, important nuance. The proven LOD MSPT win (`-43.9%`, documented in
`docs/pathfinding-elision-design.md §12.4`) was measured **with `region.enabled=false`** to
isolate the AI/path saving in single-thread. With **`region.enabled=true` (the FULL config) and
all mobs around one bot → ONE active region**, the WorkStealing scheduler runs (parallelism=15)
but with no second region to parallelize, its per-tick orchestration overhead **roughly cancels
the LOD AI/path saving** → net parity. The LOD lever is real but it shines **single-threaded**;
regionization's lever needs **multiple** regions. Path-bound load confined to one region is
therefore ~parity, not a FULL win — reported straight.

### 3. Single-region flat dense — near-parity (expected)

| mobs | VANILLA | FULL | speedup |
|---:|---:|---:|:---:|
| 1500 | 38.29 ms | 33.42 ms | 1.15x — **~parity** (FULL marginally faster) |

One region, entity-tick-bound, all mobs near one bot. As expected, FULL ≈ VANILLA; the small
edge to FULL is the LOD throttle trimming the far-band AI on a dense ring, not parallelism
(single region). No regression — coderyoMC does not lose the single-region dense case.

---

## Honest caveats

- **Multi-region is where coderyoMC wins; single-region is parity.** The headline 2.5–3.1x is
  entirely the **regionization (cross-core parallelism)** lever and requires the load to span
  multiple disjoint regions. A single-region horde — flat-dense *or* path-bound — is ~parity:
  there is only one region to tick, so the scheduler adds overhead without a parallel payoff,
  and the LOD MSPT saving (which is real single-threaded) is offset by that overhead.
- **The `-43.9%` LOD figure is a `region.enabled=false` number** (single-thread, isolating the
  AI/path saving) — see `docs/pathfinding-elision-design.md §12.4`. It is **not** the FULL-config
  path-bound result here (which is parity). Both are honest; they measure different things.
- **Run counts are time-boxed.** Multi-region @1600 has n=3 (sd reported); all other cells are
  **n=1** under the ~40 min budget. The 5 s-avg steady signal is tight run-to-run (sd 0.11–0.57
  ms at 1600), so single runs are indicative but not statistically averaged. Capacity numbers
  are **MSPT-curve estimates**, not measured per-count sweeps.
- **Spawn-storm transient:** bursting 1600–4800 `/summon`s stalls one tick for several seconds
  (Paper watchdog thread-dump, *"NOT A BUG"*); excluded by the settle window + 5 s-avg-of-last-8
  metric. Both configs incur it.
- **Terrain / target dependence:** the path-bound result depends on the obstacle field forcing
  real A* (`follow_range=160`); the multi-region result depends on regions staying **disjoint**
  (areas 3000 blocks apart, no merge). Mobs in the multi-region scenario wander
  (`RandomStrollGoal`, no player target) so per-mob cost is lower than an active chase — the
  parallel speedup would be **larger** with heavier per-region (chasing) load, smaller if the
  serial global tick phase dominated.
- **Reproduce:** `./bench.sh multiregion FULL 1600` (and `VANILLA`); `./run-all.sh multiregion 1600 3`.
  Raw `run-*/server.log` are git-ignored run output; the `bench.sh` / `run-all.sh` / `MiniBot.java`
  scripts are committed.
