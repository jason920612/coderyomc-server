# Real-Plugin Compat Corpus — 26.2 Availability + `region.enabled=false` Baseline

> Issue #10. Target: **coderyoMC 26.2** (paperweight-v2 hard-fork of Paper 26.2,
> custom regionized multithreading). All results from the **real production
> path** (design-spec §8): a real `createPaperclipJar` artifact booted headless,
> no mocks. Baseline boot date 2026-06-25.
>
> **Build under test:** `coderyo-paperclip-26.2-R0.1-SNAPSHOT.jar`
> (`applyAllPatches` + `createPaperclipJar`, Temurin JDK 25).
> **Boot:** port **15567**, `online-mode=false`, flat world, headless `--nogui`.
> Server reached `Done (17.233s)!` and shut down cleanly. No server-side
> stack traces or `Could not load` errors for any plugin.

## 1. 26.2 build availability (honest)

26.2 was released **2026-06-16** — nine days before this corpus was built. The
single most important finding: **only 4 of 8 well-known plugins ship a build
that explicitly declares Minecraft 26.2 support.** The other 4 top out at
26.1.x / 1.21.11 on their public release channels (some have dev/snapshot
builds that claim 26.2 but no tagged stable artifact).

| Plugin | Newest version | Declares 26.2? | Highest declared MC | Source | Download |
|---|---|:--:|---|---|---|
| **LuckPerms** | 5.5.53 | ✅ yes | 26.2 | Modrinth | `LuckPerms-Bukkit-5.5.53.jar` |
| **WorldEdit** | 7.4.4-beta-01 | ✅ yes | 26.2 (beta channel) | Modrinth | `worldedit-bukkit-7.4.4-beta-01.jar` |
| **ViaVersion** | 5.10.1-SNAPSHOT+1012 | ✅ yes | 26.2 (snapshot, built `mc26.2`) | Modrinth | `ViaVersion-5.10.1-SNAPSHOT.jar` |
| **VaultUnlocked** | 2.20.2 | ✅ yes | 26.2 | Modrinth | `VaultUnlocked-2.20.2.jar` |
| **PlaceholderAPI** | 2.12.2 | ❌ no | 26.1.2 | Modrinth/Hangar | `PlaceholderAPI-2.12.2.jar` |
| **WorldGuard** | 7.0.17 | ❌ no | 26.1.2 | Modrinth | `worldguard-bukkit-7.0.17.jar` |
| **EssentialsX** | 2.22.0 | ❌ no | 26.1.2 (site claims 26.2 via snapshot repo) | Modrinth | `EssentialsX-2.22.0.jar` |
| **CoreProtect** | 23.2 (CE fork) | ❌ no | 1.21.11 | Modrinth | `CoreProtect-CE-23.2.jar` |

Notes / honesty:
- **PlaceholderAPI / WorldGuard / EssentialsX** publish nothing 26.2-tagged yet.
  Their newest stable builds stop at 26.1.2 (released ~2026-04). EssentialsX's
  website advertises 26.2 via its **snapshot** Maven repo
  (`repo.essentialsx.net/snapshots`), but there is no 26.2-tagged stable jar; we
  pin the newest stable (2.22.0) for reproducibility.
- **CoreProtect**: the original PlayPro CoreProtect ships 26.2 only as a
  self-compiled/Patreon **dev build** — no tagged public artifact. The closest
  reproducible release is the **Community Edition fork** (23.2), which tops out
  at 1.21.11.
- **ViaVersion** only ships 26.2 as a **SNAPSHOT** (`5.10.1-SNAPSHOT`, built
  `mc26.2`); there is no stable 5.10.x yet.
- **WorldEdit** 26.2 support is **beta-channel only** (7.4.4-beta-01).
- Exact URLs are in `manifest.tsv` / `manifest.json`.

## 2. `region.enabled=false` load/enable baseline

All 8 jars dropped into `run/plugins/` and booted together on the real 26.2
paperclip jar (region disabled / Tier-0 passthrough — the P3.1 compat layer is
present but inert by default, so plugins ran the classic single-thread path).

| Plugin | Loads | Enables | Outcome on coderyoMC 26.2 | Detail |
|---|:--:|:--:|---|---|
| **LuckPerms** 5.5.53 | ✅ | ✅ | **Clean** | `Enabling LuckPerms v5.5.53`; clean shutdown (`Goodbye!`). No warnings. |
| **WorldEdit** 7.4.4-beta-01 | ✅ | ✅ | **Clean** | Enabled, registered `BukkitServerInterface`, clean unregister on stop. |
| **WorldGuard** 7.0.17 | ✅ | ✅ | **Clean** | Enabled with its hard `WorldEdit` dependency satisfied; clean shutdown. Despite declaring only 26.1.2, it loads + enables fine on 26.2. |
| **VaultUnlocked** 2.20.2 | ✅ | ✅ | **Clean** | Registers as plugin name `Vault`; EssentialsX picked it up as payment provider. |
| **PlaceholderAPI** 2.12.2 | ✅ | ✅ | **Clean** | Enabled + disabled cleanly. No 26.2 tag but no problem at load/enable. |
| **ViaVersion** 5.10.1-SNAPSHOT | ✅ | ✅ | **Clean (benign warn)** | Enables. Warns *"does not have any compatible versions for this server version"* — **expected**: the server already IS the newest protocol, so there is nothing to translate down to. Not a failure; plugin stays enabled and shuts down cleanly. |
| **EssentialsX** 2.22.0 | ✅ | ✅ | **Enables (warns unsupported)** | Enables, finds Vault payment layer, fully functional. Logs `You are running an unsupported server version!` + `unknown version` (its version DB has no 26.2 entry) — cosmetic; it does **not** self-disable. |
| **CoreProtect** 23.2 | ✅ | ❌ | **HARD FAIL — self-disables** | `Minecraft 26.2 is not supported.` → `CoreProtect Community Edition was unable to start.` → immediately disables itself. Hard version gate inside the plugin. |

**Summary: 7 / 8 load + enable; 1 / 8 (CoreProtect CE) self-disables on a hard
26.2 version check.** Two of the seven that enable (ViaVersion, EssentialsX)
print version warnings but remain functional.

### Grading rules used
- **Clean** = `Enabling …` printed, no `Could not load`, no incompatible-version
  rejection, no exception on enable, and disabled only at server shutdown.
- **Self-disable** = plugin printed `Disabling …` immediately after `Enabling …`
  (not at shutdown) due to its own version check.
- No plugin was rejected by the *server* (api-version gate passed for all; their
  `api-version` values range 1.13 → 1.21.11, all ≤ 26.2). The only failure is
  CoreProtect's **internal** version check, not a server-side incompatibility.

## 3. Readiness for the `region.enabled=true` compat-tier test

That test runs **after the P3.1 compat layer is wired live** (out of scope for
this issue — this is prep + baseline only). Candidates that load+enable cleanly
at `region.enabled=false` are the ones worth re-running under regionized
threading:

**Ready to re-test under `region.enabled=true`** (enable cleanly today):
- LuckPerms 5.5.53 — permission API, cross-plugin calls → good Tier-1/Tier-2 probe.
- PlaceholderAPI 2.12.2 — read-heavy/global-view → ideal **Tier 1.5** speculative candidate.
- VaultUnlocked 2.20.2 — economy API shim; pair with a provider to exercise irreversible cross-plugin returns (Tier 2).
- WorldEdit 7.4.4-beta-01 — bulk cross-region block edits → exercises ownership-transfer / per-region slicing.
- WorldGuard 7.0.17 — region scanning + WorldEdit dep → cross-region read patterns.
- EssentialsX 2.22.0 — broad core-utilities surface (best single high-coverage probe); ignore its cosmetic version warning.
- ViaVersion 5.10.1-SNAPSHOT — packet path; benign "no compatible versions" warning is unrelated to regionization.

**Not ready / blocked:**
- **CoreProtect** — blocked by its own 26.2 version gate; cannot participate
  until a 26.2-supporting build (PlayPro dev build, or a CE release that adds
  26.2) is published. Re-evaluate when available.

## 4. Reproduce
```bash
cd test-harness/plugin-corpus
./download.sh          # fetch all 8 jars into ./jars (gitignored)
./run-baseline.sh      # boot real paperclip jar on 15567, capture run/baseline-server.log
```
Jars are **not committed** (licensing + size) — only the manifest + scripts +
this results file are. `download.sh` rebuilds the corpus from `manifest.tsv`.
