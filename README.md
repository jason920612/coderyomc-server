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

**Corpus result (region.enabled=true):** **6 of 7** popular plugins are fully functional and **7/7** load+run with no crash / AsyncCatcher / single-writer / thread-safety exception under regionized parallel ticking — meeting the design target (ADR ~70–80% correct-execution ceiling). Tested: LuckPerms, WorldEdit (incl. cross-region `//set` via NMS auto-marshal), WorldGuard, VaultUnlocked, EssentialsX (economy), ViaVersion — all work; PlaceholderAPI loads+parses but leaves some placeholders unresolved (a resolution gap, not a region/compat defect).

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
