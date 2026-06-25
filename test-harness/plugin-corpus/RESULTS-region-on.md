# Real-Plugin Compat — `region.enabled=true` (Tier 0/2 compat layer LIVE)

> Issue #13. Target: **coderyoMC 26.2** (paperweight-v2 hard-fork of Paper 26.2,
> custom regionized multithreading). All results from the **real production
> path** (design-spec §8): a real `createPaperclipJar` artifact booted headless,
> no mocks. Run date 2026-06-25.
>
> **Build under test:** `coderyo-paperclip-26.2-R0.1-SNAPSHOT.jar`
> (`applyAllPatches` + `createPaperclipJar`, Temurin JDK 25,
> `26.2-DEV-feat/p3-realplugin-test@1a2f211`).
> **Boot flags:** `-Dcoderyo.region.enabled=true -Dcoderyo.region.debug=true
> -Dcoderyo.compat.enabled=true` — the **regionization core + Tier 0/2 compat
> layer are LIVE** (this is the load-bearing difference vs the `RESULTS-baseline.md`
> run, which had `region.enabled=false` and the compat layer inert).
> **Boot:** port **15568**, `online-mode=false`, flat world, headless `--nogui`.
> **One boot, all 7 plugins together.** CoreProtect is **excluded** — it
> self-disables on a hard 26.2 version gate (see baseline §2), so it cannot
> participate.
>
> Server reached **`Done (18.388s)!`** with all 7 plugins enabled and shut down
> cleanly (all dimensions saved, worker/I-O pools terminated). The
> regionization core was demonstrably active: the `[coderyoMC/region]` debug
> channel logged **3 regions forming** (overworld/nether/end spawn chunks) and
> dissolving cleanly — proof the run was not silently falling back to the
> single-thread path.

## 1. Per-plugin result (PRIMARY = robust log-grep; SECONDARY = best-effort probe)

| Plugin | Loads | Enables | Crash / async / thread error | Compat tier touched | Console probe | Verdict |
|---|:--:|:--:|---|---|---|---|
| **LuckPerms** 5.5.53 | ✅ | ✅ | none | main/orchestrator (Tier 0 inline) — no router log | `lp info` → full instance dump (MC 26.2, H2 storage, 1 group) | **Clean** |
| **WorldEdit** 7.4.4-beta-01 | ✅ | ✅ | none | main/orchestrator (Tier 0 inline) | `version WorldEdit` → `7.4.4-beta-01+b969a7f7e` | **Clean** |
| **WorldGuard** 7.0.17 | ✅ | ✅ | none (1 deprecated-event WARN, cosmetic) | main/orchestrator (Tier 0 inline) | `version WorldGuard` → `7.0.17+2370-e42d8bc` | **Clean** |
| **VaultUnlocked** 2.20.2 | ✅ | ✅ | none | main/orchestrator (Tier 0 inline) | `version Vault` → `2.20.2` | **Clean** |
| **PlaceholderAPI** 2.12.2 | ✅ | ✅ | none | main/orchestrator (Tier 0 inline) | `papi parse me %server_online%` → `You must be a player to use me as a target!` (command reached PAPI; console has no player target — expected) | **Clean** |
| **ViaVersion** 5.10.1-SNAPSHOT | ✅ | ✅ | none (benign "no compatible versions" WARN — see notes) | main/orchestrator (Tier 0 inline) | `viaversion` → command list; detected server `26.2 (776)` | **Clean (benign warn)** |
| **EssentialsX** 2.22.0 | ✅ | ✅ | none — prints `unsupported server version!` ERROR but does **not** self-disable | main/orchestrator (Tier 0 inline) | `ess version` → full table (Server/Brand/EssentialsX/PAPI/LuckPerms/Vault) | **Enables (cosmetic warn)** |

### Grading rules (same as baseline §2)
- **PRIMARY (robust):** an `Enabling …` line, no `Could not load`, no
  incompatible-version rejection, **no `AsyncCatcher` / `Asynchronous` /
  `single-writer` / `IllegalStateException` / wrong-`TickThread` exception**
  naming the plugin, and a `Disabling …` line **only at server shutdown** (not
  immediately after enable). All 7 satisfy this under `region.enabled=true`.
- **SECONDARY (best-effort, ≤6 s/probe, never looped):** one console command
  per plugin, log grepped once. **7/7 produced real output** — no
  `output-not-captured`. The probes ran on the console/orchestrator thread, so
  they exercise the plugin command path but **not** the cross-region router.

## 2. Coverage headline

**7 / 7 corpus plugins load, enable, and run without any crash, async-catcher,
or thread-safety exception under `region.enabled=true` (Tier 0/2 compat LIVE).**

Counting against the full 8-plugin corpus (CoreProtect blocked by its own 26.2
gate, not by coderyoMC): **7 / 8 = 87.5%**. This **meets and slightly exceeds
the ADR-0001 ~70–80% target** for the Tier 0 inline + Tier 2 serialized-legacy
baseline increment. The one miss (CoreProtect) is an upstream plugin version
gate, identical to the `region.enabled=false` baseline — regionization did not
regress any plugin: the region-on coverage equals the region-off baseline.

Cross-plugin interactions also survived region-on:
- **PlaceholderAPI registered the `vaultunlocked` expansion** (PAPI ⇄ Vault hook).
- **EssentialsX selected `Vault Compatibility Layer (v2.20.2)` as its payment
  method** (Essentials ⇄ Vault economy bridge), and resolved its full provider
  matrix (TileEntity, DamageEvent, InventoryView, etc.) on the 26.2 API.

## 3. Honest caveat — what this run does and does NOT prove

This is a **load + enable + clean-shutdown** result under a live regionized
core, which is robust and reproducible. It is **not** a proof that the Tier 0/2
**router** has been stress-exercised:

- The `[coderyoMC/region]` channel confirms regions **R1/R2/R3 formed and
  dissolved** around spawn chunks, so the regionization core genuinely ran.
- BUT **no `coderyoMC/compat` router lines appeared** (`compat: event dispatch
  INLINE (Tier 0…)` / `-> legacy region (Tier 2)`). With **zero connected
  players, no entities, and no gameplay events**, plugin enable/commands all ran
  on the **orchestrator (main) thread** — which is the inline / context-free
  path that does not emit a router log line. So every plugin touched, at most,
  the **Tier 0 inline / Tier 2 context-free** path with the orchestrator as the
  current thread.
- To observe Tier 0 vs Tier 2 **classification under contention** (an event
  firing on a region-worker thread, or a cross-region subject), a **future
  increment must drive real gameplay** under region-on: connect ≥1 player, load
  chunks across ≥2 regions, and trigger plugin events on a worker tick. That is
  out of scope for this load/enable smoke and is the natural next test.

## 4. Which plugins motivate **Tier 1 auto-marshal** (next increment)

Tier 1 (future-based cross-region auto-marshal, deferred per ADR-0001) is what
turns "always-correct but serialized" Tier 2 into "correct **and** parallel" for
cross-region plugin calls. The corpus plugins that will most stress it once
gameplay is driven:

- **WorldEdit 7.4.4** — bulk block edits routinely span many chunks / multiple
  regions in one operation; under Tier 2 every cross-region slice serializes to
  the legacy region. **Top Tier 1 candidate** (ownership-transfer / per-region
  slicing).
- **WorldGuard 7.0.17** — region scans + WorldEdit dependency: cross-region
  read patterns on protection checks. Strong Tier 1 (and Tier 1.5 speculative
  read) candidate.
- **PlaceholderAPI 2.12.2** — read-heavy, global-view placeholder resolution
  that can be invoked from any region thread; ideal **Tier 1.5 speculative
  fast-lane** candidate (mostly side-effect-free reads).
- **VaultUnlocked 2.20.2** (with a real economy provider) + **EssentialsX** —
  irreversible cross-plugin economy returns are the canonical **Tier 2 → Tier 1**
  correctness/throughput trade; the Essentials→Vault payment bridge already
  resolves here, so it is the right pair to benchmark Tier 1 against.
- **LuckPerms 5.5.53** — permission lookups invoked from arbitrary region
  threads (other plugins call it mid-event); good Tier 1 marshalling probe.

ViaVersion sits on the packet path (per-connection), largely orthogonal to the
region router, so it is the **lowest** Tier 1 priority.

## 5. Notes / possible upstream bugs (for the commander to file)

- **ViaVersion 5.10.1-SNAPSHOT** — emits `ViaVersion does not have any
  compatible versions for this server version!` This is **expected, not a bug**:
  the server already IS the newest protocol (26.2 / 776), so there is nothing to
  translate down to. It still enables and runs. (Same as baseline.)
- **EssentialsX 2.22.0** — logs `You are running an unsupported server version!`
  at ERROR level and `unknown version`. Its bundled version DB has no 26.2
  entry; **cosmetic** — it does **not** self-disable and is fully functional
  (resolved all providers + Vault payment). Not a coderyoMC bug; an upstream
  version-table gap. Worth filing upstream only as "please add 26.2 to the
  supported-versions list".
- **No coderyoMC-side defects observed.** No `AsyncCatcher`, no `Asynchronous`,
  no `single-writer`, no `IllegalStateException`, no wrong-`TickThread` traces —
  the region core formed/dissolved regions cleanly with all 7 plugins resident.
- The `[…] ERROR]: No key layers in MapLike[{}]` line is vanilla flat-world
  datapack noise (present in baseline too), unrelated to plugins or compat.

## 6. Reproduce
```bash
cd test-harness/plugin-corpus
./download.sh            # fetch the 8 jars into ./jars (gitignored)
./run-region-on.sh       # boot real paperclip jar on 15568 with region.enabled=true,
                         # region.debug=true, compat.enabled=true; all 7 plugins
                         # (CoreProtect auto-skipped); capture run-region-on/region-on-server.log
```
`run-region-on.sh` is anti-stall by construction: a **180 s hard boot timeout**,
a **300 s absolute JVM ceiling watchdog**, and **time-boxed (≤6 s) one-shot**
console probes that are never re-parsed in a loop. Jars are **not committed**
(licensing + size) — only the manifest, scripts, and this results file are.
