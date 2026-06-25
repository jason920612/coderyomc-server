# Real-Tick CPU Hot-Spot Profile — coderyoMC regionized core (#21)

**Goal:** stop guessing optimization targets. Profile the **real running tick under
realistic load** with JFR and rank where CPU time actually goes, so the next
optimization hits a measured hot spot (the prior GPU-worldgen and SIMD-noise
attempts failed because they targeted a workload the server isn't bound by).

**Date:** 2026-06-25 · **Host:** AMD Ryzen 7 5700X3D (8c/16t), Windows 11,
Temurin JDK 25.0.3 · **Build:** `coderyo-paperclip-26.2-R0.1-SNAPSHOT`
(branch `feat/tick-profiling`, base `c2202c9`) · **Port:** 15565 ·
`region.enabled=true region.debug=true` · JVM `-Xms3G -Xmx6G -XX:+UseG1GC`.

> ⚠️ **Headline finding first:** under the target workload (≥2 active regions
> each holding entities) the **WorkStealing region scheduler crashes within
> seconds** with a `NoSuchElementException` race in concurrent mid-tick task
> draining. This reproduced on **every** 2-region run (5/5). It is both the most
> important result and the reason the long steady-state window had to be taken
> from the pre-crash ticking. See **§1**.

---

## Load setup (real e2e, no synthetic micro-loop)

Driver: [`run-profile.sh`](./run-profile.sh) boots the real paperclip, drives the
live server console over stdin (proven `emit | java` pattern), and records a
continuous JFR (`settings=profile`, method sampling), dumped on clean stop.

Realistic **tick** load (not worldgen):
- `forceload add -80 -80 80 80` and `forceload add 2920 -80 3080 80`
  → **2 well-separated regionizer regions**, ~200 force-ticked chunks.
- **~720–1400 mobs** summoned across both regions: zombies, skeletons, spiders,
  villagers, cows, sheep, chickens. Hostile AI goals + `Brain` behaviours +
  **A\* pathfinding** + collision/push run every tick (mobs in force-loaded
  chunks tick AI without a player present; region-debug confirms ~1451/1918
  entities/region ticking).
- **Flowing fluids** (water + lava sources) and a **redstone** block/lamp/torch
  cluster → scheduled-tick / `LevelTicks` / fluid load.
- 25 s settle after generation so the JFR window is steady **tick**, not one-shot
  worldgen. Analyzer ([`analyze-jfr.sh`](./analyze-jfr.sh)) additionally filters
  `jdk.ExecutionSample` to the post-generation window via epoch markers, so
  residual `ImprovedNoise`/`Climate` worldgen frames are excluded from the
  ranking.

Reproduce: `./run-profile.sh 150` then
`START_MS=<gen-done-epoch-ms> END_MS=<stop-epoch-ms> ./analyze-jfr.sh run-prof/tick.jfr 25`.

---

## Observed MSPT / TPS under load

From `region.debug` per-region tick timings (916 ticks, both overworld regions
ticking **in parallel** on `coderyo-region-worker-*` threads):

| Region | entities | tick time (min / median / avg / max) |
|--------|---------:|--------------------------------------|
| **R1** (dense hostile @0,0) | ~1451 | 5.5 / **31.6** / 33.4 / 795 ms |
| **R2** (mixed @3000,0)      | ~1918 | 2.1 / **10.0** / 11.0 / 359 ms |

Server tick = sequential global phases + **max** over the parallel region phase
≈ **32–38 ms median MSPT**, i.e. ~20 TPS nominal but with heavy spikes
(max region phase 795 ms = stop-the-world GC / lock contention stalls).
An independent low-load probe earlier showed avg **20.7 ms / max 56 ms / 14.9
TPS**. The tick is clearly under real pressure.

> **Key asymmetry:** R1 has *fewer* entities than R2 (1451 < 1918) yet costs
> **~3× more** per tick. The difference is *what* the entities do — R1 is packed
> with hostile mobs actively running goal selection + pathfinding; R2 is mostly
> passive/idle. This is the first concrete signal that **per-entity AI cost, not
> entity count, drives MSPT.**

---

## Ranked CPU hot spots (post-gen steady window, 2,814 samples)

### Subsystem attribution (a sample counts if **any** stack frame matches; non-exclusive, sums >100%)

| Rank | Subsystem | % of samples | Notes |
|-----:|-----------|-------------:|-------|
| 1 | `region_sched` | **98.0%** | everything ticks under the region scheduler (expected wrapper) |
| 2 | `entity_tick` | **90.4%** | **the tick is entity ticking, end to end** |
| 3 | `ai_goal` (goals + `Brain`/behaviours/sensors) | **44.7%** | |
| 4 | `chunk_system` (entity-slice + POI lookups) | 21.5% | |
| 5 | `pathfinding` (A\*) | **19.4%** | |
| 6 | `fluid` | 15.6% | flowing water/lava |
| 7 | `gc` | 15.3% | allocation churn, **not** the bottleneck |
| 8 | `movement_collision` | 10.6% | |
| 9 | `tracking_net` | 3.8% | low — networking is **not** hot |
| 10 | `light` | 1.1% | |
| 11 | `redstone`/`LevelTicks` | 0.5% | negligible |
| 12 | `block_entity` | 0.0% | negligible |

**AI goals + pathfinding together ≈ 64% of all on-CPU stacks.** Pathfinding/entity-AI
**does dominate as expected** — confirmed by the profile, not assumed.

### Top on-CPU **leaf** methods (exclusive — where the cycles actually burn)

| # | % | Method | Subsystem |
|--:|---:|--------|-----------|
| 1 | 4.9% | `ChunkEntitySlices$EntityCollectionBySection.getEntities(Entity, AABB, …)` | entity spatial query (AI targeting / collision / sensors) |
| 2 | 4.4% | `LongOpenHashSet.add(long)` | collision visited-set (block iteration) |
| 3 | 4.0% | `BlockBehaviour$BlockStateBase.getCollisionShape(…)` | movement/collision |
| 4 | 3.8% | `ConcurrentChainedLong2ReferenceHashTable.getNode(long)` | chunk/entity map lookup |
| 5 | 3.3% | `ReferenceOpenHashSet.contains(Object)` | goal/behaviour bookkeeping |
| 6 | 3.2% | `PoiAccess.findNearestPoiRecords(…)` | villager `Brain` POI search |
| 7 | 2.8% | `ThreadLocal$ThreadLocalMap.getEntry` | per-frame thread-local access (region workers) |
| 8 | 2.6% | `Long2ObjectOpenHashMap.find(long)` | chunk lookup |
| 9 | 2.4% | `ArrayList.addAll` | entity-query result assembly |
| 10 | 1.5% | `FlowingFluid.getFlow(…)` | fluid |
| 11 | 1.5% | `PathTypeCache.compute(…)` | **A\*** node classification |
| 12 | 1.3% | `EntityFluidInteraction.update` | fluid/entity |
| 13 | 1.2% | `GoalSelector.tickRunningGoals` | AI goals |
| 14 | 1.2% | `Brain.startEachNonRunningBehavior` | AI behaviours |
| 15 | 1.2% | `NodeEvaluator.getNode` | **A\*** |
| 16 | 1.2% | `GoalSelector.tick` | AI goals |
| 17 | 1.0% | `BinaryHeap.downHeap` | **A\*** open-set heap |
| — | 0.9% | `WalkNodeEvaluator.getNeighbors` | **A\*** neighbour expansion |

The on-CPU leaves cluster into three per-entity families:
**(a) AI decision-making** (`GoalSelector`, `Brain`, `PoiAccess`, sensors),
**(b) A\* pathfinding** (`PathTypeCache`, `NodeEvaluator`, `WalkNodeEvaluator`,
`BinaryHeap`), and **(c) collision + entity spatial queries**
(`getEntities(AABB)`, `getCollisionShape`, `LongOpenHashSet`). All three run
**synchronously inside the region worker's entity loop**, serialized per region.

---

## §1 — CRITICAL: WorkStealing region scheduler crash (concurrency hazard)

Under the intended ≥2-region entity workload the server **crashes reliably**
(observed 5/5 runs, at both ~1400 and ~720 mobs, within seconds of two regions
ticking concurrently):

```
net.minecraft.ReportedException: Exception ticking worlds (region scheduler)
  Caused by: java.lang.RuntimeException: region tick failed
    at com.coderyo.region.WorkStealingRegionScheduler.submitTick(WorkStealingRegionScheduler.java:124)
  Caused by: java.util.NoSuchElementException
    at java.util.AbstractQueue.remove(AbstractQueue.java:117)
    at net.minecraft.util.thread.BlockableEventLoop.pollTask(BlockableEventLoop.java:182)
    at net.minecraft.server.level.ServerChunkCache$MainThreadExecutor.pollTask(ServerChunkCache.java:916)
    at net.minecraft.server.level.ServerChunkCache.pollTask(ServerChunkCache.java:489)
    at net.minecraft.server.MinecraftServer.tickMidTickTasks(MinecraftServer.java:451)
    at ...moonrise$executeMidTickTasks → ServerLevel.moonrise$midTickTasks
    at net.minecraft.world.level.Level.guardEntityTick(Level.java:1596)
    at net.minecraft.server.level.ServerLevel.coderyoTickOneEntity(ServerLevel.java:1016)
    at com.coderyo.region.RegionTickOrchestrator.lambda$tickLevel$0(RegionTickOrchestrator.java:226)
    at com.coderyo.region.Region.tick(Region.java:191)
    at com.coderyo.region.WorkStealingRegionScheduler.lambda$submitTick$0(...:109)
    at java.util.concurrent.ThreadPoolExecutor$Worker.run
```

**Root cause (from the stack + `WorkStealingRegionScheduler.submitTick`):**
`submitTick` runs each region's `tick()` **concurrently on a thread pool**. Inside
the per-entity loop, vanilla/Moonrise drains *mid-tick tasks* via
`ServerChunkCache.pollTask → BlockableEventLoop.pollTask`, which calls
`AbstractQueue.remove()`. That mid-tick task queue is a **single shared
main-thread executor on `ServerChunkCache`** — but now **multiple region worker
threads poll it simultaneously**. `AbstractQueue.remove()` is `poll()` then
"throw if null": a classic check-then-act TOCTOU. Two workers race, one drains
the last task, the other sees `null` and throws → the whole tick aborts.

This is a genuine **shared-mutable-state hazard in the parallel region tick**: the
regionization isolates per-chunk entity writes but does **not** isolate the
mid-tick task executor that entity ticking re-enters. It must be fixed before the
core can run multi-region entity load at all, and it directly contaminates any
attempt to optimize the entity tick "in place."

---

## Prioritized optimization plan (grounded in the profile)

### 🥇 #1 (highest value) — Fix the region mid-tick task race, then **parallelize is already the win**

**This is the single highest-value next target — but it is a *correctness* fix, not
a speed feature.** The profile shows the parallel region tick is exactly the right
architecture (R1 and R2 genuinely tick on separate worker threads), and that
**entity AI is the cost** — so spreading regions across cores is the correct
lever. It simply **does not survive contact with ≥2 entity-bearing regions today.**

- **Technique: serialize / shard the shared mid-tick executor (algorithmic +
  concurrency-correctness), NOT SIMD.** Options, cheapest first:
  1. Make the `ServerChunkCache` main-thread-executor drain **single-owner** —
     only the orchestrator thread polls it between region phases, never the region
     workers (move `midTickTasks` out of `coderyoTickOneEntity`/`guardEntityTick`
     when running under the region scheduler).
  2. Or give each region its **own** mid-tick task queue and drain it on its owning
     worker (matches the existing single-writer-per-region invariant).
  3. Or, minimally, replace the racy `AbstractQueue.remove()` drain with a
     null-tolerant `poll()` loop **and** guard the queue — but (1)/(2) remove the
     contention entirely and are the principled fix.
- **Why first:** nothing else can be measured or shipped on the entity tick until
  the multi-region path is stable; and once stable, the existing parallelism *is*
  the speedup (R1+R2 overlap → ~max instead of sum).
- *Out of scope for this PR (profiling only, no server-code changes) — filed as the
  #1 recommendation for the core team.*

### 🥈 #2 — **Async / off-thread A\* pathfinding** (parallelize)

Pathfinding is **~19% of stacks** and is the most parallelizable per-entity cost:
`PathTypeCache.compute`, `NodeEvaluator.getNode`, `WalkNodeEvaluator.getNeighbors`,
`BinaryHeap.downHeap`. A full A\* search is a self-contained, read-mostly graph
search over a block snapshot.

- **Technique: parallelize — move path computation onto a worker pool**, return the
  `Path` to the entity a tick or two later (mobs tolerate 1–2 tick path latency).
  This pulls a fifth of the entity-tick CPU off the region-tick critical path.
- **Not SIMD:** A\* is pointer-chasing + a priority heap + branchy neighbour
  expansion — **gather/branch-bound**, exactly the shape that sank the SIMD-noise
  attempt. Do **not** vectorize it.
- Pairs naturally with #1: async pathfinding *reduces* the per-entity work that
  re-enters the mid-tick executor, easing the contention too.

### 🥉 #3 — **Entity spatial-query + collision** (algorithmic / cache, then branch-tighten)

The hottest single leaf is `getEntities(AABB)` (4.9%), with collision
(`getCollisionShape` 4.0% + `LongOpenHashSet.add` 4.4%) close behind — together
the largest **non-AI** family.

- **Technique: algorithmic — cut redundant broad-phase queries** (cache nearby-entity
  lists per section per tick so targeting/sensors/collision share one scan instead
  of each re-querying), and reuse the collision visited-`LongOpenHashSet` /
  block-shape results across an entity's sub-steps.
- **Then branch-predictable/branchless** on the inner `getCollisionShape` /
  block-iteration loop (most blocks are air/full-cube — fast-path those before the
  general voxel-shape path).
- **Not SIMD:** these are hash-set + AABB-overlap + map lookups — gather-bound.

### Explicitly *not* worth chasing (the profile says so)
- **Networking/entity tracking** — 3.8%. The GPU/SIMD instinct to attack "data
  parallel" work is wrong here; this isn't hot.
- **Redstone/`LevelTicks`/block-entities** — <1% combined.
- **Light** — 1.1%.
- **GC (15%)** is real but a *symptom* of per-entity allocation (path nodes,
  entity-query lists), not an independent target — it shrinks as #2/#3 cut
  allocations. Don't tune GC flags as the primary fix.
- **`ImprovedNoise`/`Climate$RTree`** (large in the *unfiltered* run) is residual
  worldgen + biome-climate sampling during mob spawning, **not** the steady tick —
  precisely the false target the earlier SIMD-noise work optimized. The window
  filter confirms it falls out of the steady-state top once generation settles.

---

## Artifacts
- [`run-profile.sh`](./run-profile.sh) — boot + realistic-load driver (JFR on).
- [`analyze-jfr.sh`](./analyze-jfr.sh) — `jdk.ExecutionSample` aggregator: top leaf
  methods, top leaf classes, non-exclusive subsystem attribution, optional
  steady-window epoch filter.
- [`extract-mspt.sh`](./extract-mspt.sh) — pull TPS / tick-time lines from a log.
- `run-prof/tick.jfr`, `run-prof/server.log`, `run-prof/analysis-steady.txt`,
  `crash-reports/*` — **git-ignored** (binary/large/run output); regenerate via the
  scripts above.

## Honest caveats
- The intended **multi-region, multi-minute** steady window could not complete: the
  §1 race crashes 2-region entity load in seconds. Reported numbers come from the
  **pre-crash** ticking (≈37 s recording, 2,814 post-gen samples) — ample for a
  stable hot-spot ranking, but MSPT spikes (max 795 ms) partly reflect the system
  approaching the failure, so treat the *median* MSPT (~32 ms) as the load signal,
  not the max.
- Method sampling slightly over-weights leaf JIT-inlined hot loops; subsystem
  buckets are non-exclusive by design (deep stacks span layers). The *direction*
  (AI + pathfinding + collision dominate; networking/redstone/light do not) is
  unambiguous across both the full and window-filtered views.
