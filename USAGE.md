# coderyoMC — Operator Usage Guide

How to build and run **coderyoMC** (a regionized, simulation-LOD fork of PaperMC for
Minecraft 26.2) for **maximum entity throughput while keeping plugin compatibility**.

All performance features are **opt-in JVM flags**. With every flag off, coderyoMC is
**byte-for-byte vanilla Paper 26.2** — so you can adopt it incrementally and roll back by
removing flags, with no world or config migration.

> Status: experimental / research-grade. Read the trade-offs below before running this in
> production. The big win (regionization) needs your load to span **multiple world regions**;
> a single dense area is ~parity with vanilla Paper.

---

## 1. Build

Requires **JDK 25** (Temurin tested). From the repo root:

```bash
./gradlew applyAllPatches
./gradlew createPaperclipJar
```

The runnable server is the **paperclip** jar:

```
coderyo-server/build/libs/coderyo-paperclip-26.2-R0.1-SNAPSHOT.jar
```

Accept the Minecraft EULA as usual (`eula=true` in `eula.txt`, or `-Dcom.mojang.eula.agree=true`).

---

## 2. Recommended run command (max performance + plugin compatibility)

This is the **proven** configuration — every flag here was built, measured, and validated
end-to-end (separately *and* all together; see §6). The falsified experiments are **off**.

```bash
java -Xms6G -Xmx8G -XX:+UseG1GC \
  -Dcoderyo.region.enabled=true \
  -Dcoderyo.pathfinding.los.enabled=true \
  -Dcoderyo.lod.dab.enabled=true \
  -Dcoderyo.lod.policy.enabled=true \
  -Dcoderyo.lod.extended.enabled=true \
  -Dcoderyo.compat.enabled=true \
  -jar coderyo-paperclip-26.2-R0.1-SNAPSHOT.jar --nogui
```

`compat.enabled` defaults to follow `region.enabled`, so it is implied when regions are on;
it is listed explicitly for clarity. Add your own GC / heap tuning as appropriate for your host.

---

## 3. What each flag does (and the trade-off)

| Flag | What it does | Behavior trade-off |
|---|---|---|
| `coderyo.region.enabled=true` | **Regionized multithreading.** Independent areas of the world tick **concurrently on separate cores** (single-writer per region; cross-region moves via an ownership-transfer protocol). This is the durable performance win. | None to gameplay. Plugins that assume a single main thread become **region-aware via the compat layer** (§4). The payoff only appears when load spans **multiple** disjoint regions. |
| `coderyo.compat.enabled=true` | **Plugin-compatibility router.** Keeps Bukkit/Paper plugins working under regionization by routing scheduler tasks, events, and cross-region API/NMS block writes to a valid tick thread (Tier 0 inline / Tier 1 auto-marshal to the owning region / Tier 2 serialized). `AsyncCatcher` and `isPrimaryThread()` still pass on every routed thread — no thread check is ever disabled. | None — it only ensures plugin callbacks land on a correct serialized thread. Defaults to `region.enabled`. |
| `coderyo.pathfinding.los.enabled=true` | **L1 LOS / direct-walk A\* elision.** When the straight line to the target is clear and the floor is continuous, skips the A\* search and walks straight (uses the exact vanilla line-of-sight clip). On open terrain this elides ~52–77% of A\* searches. | **Behavior-equivalent by construction** — it only fires when A\* would produce the same straight path. Any obstacle / fluid / drop / door / fence falls back to real A\*. |
| `coderyo.lod.dab.enabled=true` | **Distance-based AI throttle (DAB).** Mobs far from any player re-decide goals and repath less often (fidelity scales with distance). Cuts the AI/path cost for entities nobody is watching. | Distant mobs "think slower." **Aggro/target is never throttled**, the NEAR band (≤16 blocks) is always full vanilla, and breeding/age/trade timers run every tick. Possible drift for redstone/farm contraptions that depend on exact *distant*-mob AI cadence — see the policy guard below. |
| `coderyo.lod.policy.enabled=true` | **Per-entity-type LOD policy (the contraption guard).** Classifies mobs HOSTILE / PASSIVE / EXEMPT and only throttles hard for hostiles. Villagers, tamed/named/leashed/ridden mobs, breeding animals, and recently player-touched mobs are **EXEMPT (never throttled = full vanilla cadence).** | This is the safety guard that makes DAB defensible. Default-on whenever DAB is on. Recommended to keep on. |
| `coderyo.lod.extended.enabled=true` | **Extended far-hostile throttle.** For FAR hostiles only, also throttles sensing + cosmetic head-aim on off-frames (movement, path-following and aggro still run every tick). Grows the LOD MSPT win. | Far hostiles' LOS-sensing/look updates lag slightly; never affects NEAR, PASSIVE, or EXEMPT mobs. |

### Optional tuning

- `-Dcoderyo.lod.policy.exempt.persistent=false` — by default, persistence-required mobs are
  EXEMPT (protects player-built farms). Set to `false` only for **benchmarking** a pure hostile
  horde, *not* for production (it removes the farm guard for persistent mobs).
- LOD band edges / divisors are tunable: `coderyo.lod.band.{near,b1,b2,b3}` (default 16/32/48/64),
  `coderyo.lod.div.{near,b1,b2,b3,far}` (default 1/2/4/8/16). If a contraption is sensitive, raise
  the near radius or lower the far divisors toward 1.
- Debug visibility: `-Dcoderyo.region.debug=true`, `-Dcoderyo.lod.debug=true`,
  `-Dcoderyo.compat.debug=true` (verbose — use for diagnostics, not production).

---

## 4. Plugin compatibility

- **Regionization OFF** → full Paper/Bukkit compatibility (it *is* Paper).
- **Regionization ON** → the `compat` router keeps plugins working. Pure-API plugins generally
  work unchanged; plugins that reach into NMS internals or cache cross-thread references may
  need to be region-aware. This is the standard regionized-server trade-off.

**Corpus result (7 popular plugins, region.enabled=true):**

| Plugin | Result under regionization |
|---|---|
| LuckPerms 5.5.53 | **Works** — groups, inheritance, permission set/check |
| WorldEdit 7.4.4 | **Works** — selection + `//set`; **cross-region `//set` lands in both regions** via the NMS Tier-1 marshal |
| WorldGuard 7.0.17 | **Works** — region define / info / flag |
| VaultUnlocked 2.20.2 | **Works** — economy bridge |
| EssentialsX 2.22.0 | **Works** — `eco give` / `balance` (cosmetic version warning only) |
| ViaVersion 5.10.1 | **Works** — protocol passthrough (connection-level) |
| PlaceholderAPI 2.12.2 | **Partial** — enables and parses without crash; some placeholders returned unresolved (a resolution/expansion gap, **not** a region/compat defect) |

**6/7 fully functional, 7/7 load+run with no crash / AsyncCatcher / single-writer / thread-safety
exception** under regionized parallel ticking — meeting the design target (~70–80% correct-execution
ceiling for the always-correct compat baseline). Cross-region block writes from WorldEdit `//set`,
vanilla `/setblock`, and `/fill` are auto-marshaled to the owning region (Tier 1).

---

## 5. Benchmark numbers (vs vanilla Paper 26.2, same jar, real e2e)

Host: AMD Ryzen 7 5700X3D (8c/16t), Windows 11, Temurin JDK 25. MSPT = steady-state 5 s-avg.

| Scenario | vanilla MSPT | coderyoMC FULL MSPT | result |
|---|---:|---:|---|
| Multi-region spread, 4 regions, 1600 mobs | 11.5 ms | 4.6 ms | **2.48x** |
| Multi-region spread, 4 regions, 4800 mobs | 44.0 ms | 14.2 ms | **3.10x** |
| Sustained-entity capacity @ MSPT < 50 ms | ~5,100 mobs | **~16,900 mobs** | **~3.3x** |
| Single-region dense / horde all on one player | — | — | ~parity (expected) |

**The durable win is regionization** — cross-core parallelism when load spans **multiple** world
regions. A single region, or a horde all clustered on one player, runs on one thread = ~parity
(no parallel payoff). LOD adds work-elimination for mobs **far from any player**; its single-thread
MSPT saving on path-bound terrain is up to **-43.9%** (isolated with regions off).

---

## 6. Full-stack integration (all features on together)

All proven features were validated running **simultaneously** in one realistic mixed scenario:
4 far-apart regions ticking in parallel, a near-player horde at full fidelity, a far/idle band
LOD-throttled, and live plugin ops — all under `region+LOD+compat` on, with the 7 corpus plugins
and a connected bot player. **The features compose at the correctness level:** regions tick in
parallel on `coderyo-region-worker-*` threads, LOD bands the far mobs (HOSTILE throttle ~0.76 vs
EXEMPT 0.0), the compat layer routes events and **auto-marshals cross-region WorldEdit/`/setblock`
writes (Tier 1)**, and across all runs there were **0 single-writer / 0 AsyncCatcher / 0 sync-event
violations and 0 hard crashes**, with a **clean shutdown** (`WorkStealingRegionScheduler shut down
(clean=true)`, all dimensions saved). Under the sustained mixed load (~420 mobs across 4 regions +
the 7 plugins + live LuckPerms/EssentialsX/WorldGuard ops) the server held **MSPT ~5.6 ms mean
(steady 5 s-avg ~4 ms, max 17 ms) and TPS 20.0** — healthy, well inside the 20-TPS budget.
(Reproduce: `test-harness/plugin-corpus/drive-fullstack.sh`.)

### Integration bug found — and fixed — by the full-stack test (honest)

Running all features together under **heavy real-plugin event load surfaced a main-thread stall
that the earlier, separately-run compat tests did not catch.** When a plugin's **event handler
reads a block in a region the orchestrator (main) thread does not own** (e.g. `block.getType()`
from a WorldGuard/Essentials listener during a multi-region spawn/forceload burst), the compat
cross-region block-read marshal blocked the main thread up to 50 ms per read before falling back to
a snapshot. A **flood** of such reads (one per loaded chunk / spawned entity across several regions)
stacked those 50 ms waits into a multi-second main-thread stall (Paper's watchdog logged a thread
dump — *not a crash*; the server recovered and shut down cleanly). The earlier compat tests used a
trivial probe plugin and a single cross-region read, so the pile-up never accumulated.

Root cause: the cross-region block-**read** path served only **region worker** threads from the
snapshot inline and treated the **orchestrator main thread** as a "may-block" caller. The fix is a
one-line guard in the compat layer — serve **any tick thread** (orchestrator main *and* region
worker) from the read-only snapshot inline, never block (block-state reads are side-effect-free, so
this changes no correctness invariant; the **write** path was never affected). With the fix the same
full-stack run goes from 13 watchdog thread-dumps to **0 stalls / 0 watchdog events**, MSPT ~5.6 ms,
TPS 20.0, clean shutdown. The fix is validated locally; capturing it into the tracked source patch
is a follow-up (it lives in the materialized minecraft-source tree).

---

## 7. What NOT to enable

These were each built, measured, and **rejected** because they did not beat their own overhead on
the real workload. They are **falsified** — leave them off:

- `coderyo.pathfinding.async` — async pathfinding (moves, doesn't eliminate, the work; consolidation cost cancels the win)
- `coderyo.entitycache` — entity broad-phase cache (no net gain)
- `coderyo.neighborshare` — shared neighbor scans (no net gain)
- GPU offload — ~7x slower; the tick is branchy + gather-bound, a poor GPU fit (removed)
- CPU SIMD (AVX2 / Vector API) — only ~3–8% of the tick is vectorizable; ~0% real gain

**Conclusion: the only levers that win are doing the work in parallel (regionization) and doing
*less* work (LOD). Re-routing or re-laying-out the same work does not.**

---

*Based on PaperMC (Minecraft 26.2). Not affiliated with Mojang or the PaperMC project.
Minecraft is a trademark of Mojang AB.*
