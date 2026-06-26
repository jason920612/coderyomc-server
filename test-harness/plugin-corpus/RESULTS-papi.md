# PlaceholderAPI gap — definitive verdict (region on vs off)

> Issue #13 follow-up. Closes the last plugin-compat gap from the real-plugin
> corpus run (`RESULTS-region-on.md`), where PlaceholderAPI was the one "partial":
> `papi parse me %server_online%` ran without error but returned the **literal**
> placeholder. Question: is that **(a)** a missing eCloud expansion (operator
> step → compat effectively 7/7), or **(b)** a coderyoMC regionization bug?
>
> **Verdict: (a) — missing-expansion / operator step. NOT a coderyoMC bug.**
> Placeholders resolve **identically** with `region.enabled=true` and
> `region.enabled=false` once the expansion is installed.

## Build / harness

- **Build under test:** `coderyo-paperclip-26.2-R0.1-SNAPSHOT.jar`
  (`applyAllPatches` + `createPaperclipJar`, Temurin JDK 25), branch
  `test/papi-gap` off `origin/main`.
- **Boot:** real paperclip jar, headless `--nogui`, port **15569**,
  `online-mode=false`, flat world. One boot per mode, all 7 corpus plugins
  (CoreProtect skipped — self-disables on 26.2).
- **Flags:** `-Dcoderyo.region.debug=true -Dcoderyo.compat.enabled=true`, with
  `-Dcoderyo.region.enabled=true` (ON) and `=false` (OFF) as the only difference.
- Reproduce: `./run-papi-gap.sh --region on` and `./run-papi-gap.sh --region off`.
- Boot reached `Done (~17–18s)!` in both modes; region core demonstrably live
  in the ON run (`[coderyoMC/region]` R1/R2/R3 form/dissolve).

## Why the original probe returned a literal — two independent causes

1. **The `server` expansion was not installed.** PAPI 2.12.2 bundles **no**
   built-in `server`/`player` expansion (verified by unzipping the jar:
   `me/clip/placeholderapi/expansion/**` has only the framework, no `server`
   expansion class). `%server_online%` is provided by the downloadable **Server**
   eCloud expansion. With it absent, PAPI returns the input literally — by design.
2. **`papi parse me …` uses `me` as the *target player*.** On the console there
   is no player, so PAPI short-circuits with **"You must be a player to use me as
   a target!"** *before* resolving the placeholder. The console-correct form is
   `papi parse --null %…%` (no player context).

Both are PAPI usage/operator details, not coderyoMC behavior.

## The key test (eCloud IS reachable in this env)

Console sequence (same in both modes):

```
papi list                          -> 1 hook active: vaultunlocked  (self-registered, no download)
papi parse me %server_online%      -> "You must be a player to use me as a target!"  (target error, not literal)
papi ecloud download Server        -> Successfully downloaded expansion Server [2.7.3]
papi reload                        -> Successfully registered external expansion: server [2.7.3]  (now 2 hooks)
papi parse --null %server_online%  -> RESOLVES
papi parse --null %server_tps%     -> RESOLVES
papi parse --null %server_name%    -> RESOLVES
```

## Results — region ON vs OFF (identical)

| Probe | `region.enabled=true` | `region.enabled=false` |
|---|---|---|
| `papi list` (pre-download) | `vaultunlocked` (1 hook) | `vaultunlocked` (1 hook) |
| `papi parse me %server_online%` (no exp.) | "You must be a player…" | "You must be a player…" |
| `papi ecloud download Server` | **Server [2.7.3] downloaded** | **Server [2.7.3] downloaded** |
| `papi reload` | registered `server [2.7.3]` (2 hooks) | registered `server [2.7.3]` (2 hooks) |
| `papi parse --null %server_online%` | **`0`** ✅ | **`0`** ✅ |
| `papi parse --null %server_tps%` | **`*20.0, *20.0, *20.0`** ✅ | **`*20.0, *20.0, *20.0`** ✅ |
| `papi parse --null %server_name%` | **`A Minecraft Server`** ✅ | **`A Minecraft Server`** ✅ |
| `papi parse --null %vaultunlocked_currency%` | literal* | literal* |
| `papi parse me %server_online%` (re-test) | "You must be a player…" | "You must be a player…" |

\* `%vaultunlocked_currency%` stays literal in **both** modes — VaultUnlocked
loaded its `vaultunlocked` PAPI hook but **no economy provider** is installed to
back a currency name (the manifest notes VaultUnlocked ships no provider). Same
in region-off, so not a regionization effect.

## Verdict

**The PAPI "gap" is (a): a missing eCloud expansion — a normal operator step,
NOT a coderyoMC / regionization bug.** Once the `server` expansion is installed
(`papi ecloud download Server` + `papi reload`), `%server_online%`,
`%server_tps%`, and `%server_name%` **all resolve**, and they resolve **byte-for-
byte identically** under `region.enabled=true` and `region.enabled=false`. No
placeholder resolved under region-off but failed under region-on; the region
core was live during the ON run. PlaceholderAPI loads, enables, registers
expansions, downloads from the eCloud, and resolves placeholders correctly under
the regionized core.

**Compat is therefore effectively 7/7** — the operator simply installs the
needed PAPI expansions exactly as on stock Paper.
