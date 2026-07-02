# coderyoMC

A high-throughput fork of **PaperMC for Minecraft 26.2**, built on the `paperweight` v2 hard-fork toolchain. It adds **custom regionized multithreading** and a **simulation-LOD engine** to handle far more entities than vanilla Paper, while **keeping Bukkit/Paper plugin compatibility**.

> Status: experimental / research-grade. The performance features are **opt-in flags** (off by default = byte-for-byte vanilla Paper).

## Headline (vs vanilla Paper 26.2, same jar, real e2e)

| Scenario | vanilla | coderyoMC (FULL) | result |
|---|---:|---:|---|
| 4 regions, 1600 mobs | 11.5 ms | 4.6 ms | **2.48x** |
| 4 regions, 4800 mobs | 44.0 ms | 14.2 ms | **3.10x** |
| Sustained-entity capacity @ MSPT<50 | ~5,100 | **~16,900** | **~3.3x** |
| Single-region dense / all near one player | — | — | ~parity |

**The durable win is regionization (cross-core parallelism) when load spans multiple world regions.** A single region, or a horde all clustered on one player, runs on one thread = ~parity (no parallel payoff). Simulation-LOD adds work-elimination for entities **far from any player** (where nobody is watching).

## How it works

- **Regionized multithreading** — independent areas of the world tick concurrently on separate cores (single-writer per region; cross-region moves via an ownership-transfer protocol). Conceptually inspired by Folia, implemented in-house. Enable with `-Dregion.enabled=true`.
- **Simulation-LOD** — fidelity scales with distance to the nearest player (near = full vanilla; far = cheaper / lower-frequency), bounded by a distance-banded error standard. Timing-sensitive entities (villagers, breeding, farms) are exempt. Flags: `-Dcoderyo.pathfinding.los.enabled=true` (A* elision on clear ground), `-Dcoderyo.lod.dab.enabled=true` (distance throttle).
- All performance code is **flag-gated**; with flags off the server is byte-for-byte vanilla Paper.

## Plugin compatibility

With regionization **off**, full Paper/Bukkit compatibility (it *is* Paper). With regionization **on**, a `compat` router keeps plugins working by routing scheduler tasks, events, and cross-region block writes to a valid tick thread (`AsyncCatcher` / `isPrimaryThread()` still pass — no thread check is ever disabled). Pure-API plugins generally work; plugins that reach into NMS internals or cache cross-thread references may need to be region-aware. This is the standard regionized-server trade-off.

**Corpus result (region.enabled=true):** All **7 of 7** corpus plugins (with a 26.2 build) are usable and load+run with no crash / AsyncCatcher / single-writer / thread-safety exception under regionized parallel ticking — meeting the design target (ADR ~70–80% correct-execution ceiling). Tested: LuckPerms, WorldEdit (incl. cross-region `//set` via NMS auto-marshal), WorldGuard, VaultUnlocked, EssentialsX (economy), ViaVersion — all work; PlaceholderAPI resolves placeholders once its standard PAPI expansions are installed (the normal operator step — verified byte-for-byte identical with regions on/off, #29), so it is fully usable too.

See **[USAGE.md](./USAGE.md)** for the recommended run command, the per-flag trade-offs, and the full plugin-compat / benchmark detail.

## Honest engineering log (what was rigorously tested and **rejected**)

Performance work here is benchmark-driven. These were each built, measured, and **dropped because they did not beat their own overhead** on the real workload — kept here for transparency:

- **GPU offload** (worldgen / entity compute) — ~7x slower / no realistic win; the tick is branchy + gather-bound, a poor SIMD/GPU fit. **Removed.**
- **CPU SIMD (AVX2 / Vector API)** — only ~3-8% of the tick is vectorizable; ~0% real gain.
- **Data-oriented (SoA) rewrite** — a clean-room prototype beat AoS by only ~2.3x (cache, not SIMD), not worth abandoning plugin compat.
- **Async pathfinding, entity broad-phase cache, shared neighbor scans** — correct, but maintenance/consolidation cost cancels the win.

**Conclusion: the only levers that win are doing the work in parallel (regionization) and doing *less* work (LOD). Re-routing/re-laying-out the same work does not.**

## Build

Requires **JDK 25**. `./gradlew applyAllPatches` then `./gradlew createPaperclipJar`.

To **run it for max performance with plugin compatibility** (the proven flags + trade-offs), see **[USAGE.md](./USAGE.md)**.

---

*Based on PaperMC (Minecraft 26.2). Not affiliated with Mojang or the PaperMC project. Minecraft is a trademark of Mojang AB.*

## Stability & production hardening

Concurrency correctness is validated by composing all features under heavy real load (not just unit-style probes). Bugs that only surface when regionization, LOD, and plugin compat run together — or under stress — were found and fixed:

- **#11** — region worker-pool not drained on shutdown → intermittent hang. Fixed (clean shutdown).
- **#24** — multiple region workers race-polling the shared mid-tick task queue → `NoSuchElementException` crash under multi-region entity load. Fixed (single-owner draining; preserves single-writer-per-region).
- **#27** — Tier-1 marshal blocking-read from the orchestrator/command thread stacked 50 ms waits into a multi-second main-thread stall under plugin event load. Fixed (any tick thread serves cross-region block *reads* from a read-only snapshot, non-blocking).
- **#28** — entity-tracker (`ChunkMap.newTrackerTick`) iterating a non-thread-safe list while region workers add/remove entities → NPE under spawn-storm. Fixed (defensive guard, gated on regionization).

Each fix is flag-gated such that `region.enabled=false` remains byte-for-byte vanilla, and each is proven by a sustained heavy-load e2e run (0 crashes / 0 single-writer violations).

## Redstone HDL-compiler + drive-the-world (experimental, opt-in)

coderyoMC includes an experimental **redstone HDL-compiler** that treats a connected redstone network like a compiled logic circuit (inspired by MCHPRS). It reuses vanilla'''s own redstone code on an in-memory `VirtualRedstoneWorld` oracle and is **differential-tested bit-identical to vanilla every tick** across 50 component circuits — wire/torch/repeater/comparator (analog 0-15)/observer/lamp/button/plates/target + piston (normal/sticky/QC/topology)/slime-honey multi-block drag/0-tick + hopper/dispenser/dropper/crafter + copper-bulb/daylight-sensor/sculk/lightning-rod + the quirks (quasi-connectivity, 0-tick pulses, zero-update BUD). A runtime `/coderyo redstone difftest <pos>` command validates **any** live in-world circuit against the compiled oracle.

**Drive-the-world: a measured 41.4x MSPT speedup** — on a heavy pure-logic workload (200 networks / ~3600 redstone components) vanilla ran **19.99 ms/tick** vs the compiler-driven **0.48 ms/tick**, **checksum-proven behaviour-identical** to vanilla. When `-Dcoderyo.redstone.drive.enabled=true`, the compiler becomes authoritative for networks the differential validator has proven bit-identical (suppressing vanilla'''s per-block redstone churn); unsupported/movement networks fall back to vanilla. Default OFF.

A validated redstone **datapath** (logic gates → half/full/ripple adders → torch RS/D latches → edge-triggered master-slave register → a sustaining edge-triggered accumulator, every stage difftest-clean) is being built as an in-world test map toward a compiler-driven redstone computer.
 Built up from there to a **running 1-bit stored-program CPU** — a ring-counter program counter + a decoder-less one-hot instruction ROM + an accumulator, wired into an autonomous **fetch→execute** loop: each clock the ring advances, the ROM fetches the next program word, and the accumulator executes it, with no external driver. The whole machine (~3226 cells) is **difftest bit-identical to vanilla** and runs compiler-driven at 41x. (A full Tetris-class computer is beyond a hand-built scope — the bottleneck is redstone-engineering the wiring, not the compiler — but every stage from a single logic gate to a running stored-program CPU is differential-proven bit-identical.)