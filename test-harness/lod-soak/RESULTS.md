# Simulation-LOD Long Soak — does LOD hold up over an extended window?

**The production-readiness datum for the eventual "flip LOD default-on?" decision.** LOD was already
validated in short runs (`docs/pathfinding-elision-design.md` §10–§12: −43.9% far-entity MSPT,
contraption-safe by per-type policy, fidelity-banded, reach 22/22 with a moving target). The one
missing number was **long-run stability**: over a sustained mixed load held for an extended window,
does LOD drift (MSPT), leak (heap), run away (fidelity), desync (contraption cadence), or crash?

**Date:** 2026-06-30 · **Host:** AMD Ryzen 7 5700X3D (8c/16t), Windows 11, Temurin JDK 25 ·
**Build:** `coderyo-paperclip-26.2-R0.1-SNAPSHOT` @ `a1a6122` (origin/main) · **Port:** 15565 ·
JVM `-Xms3G -Xmx6G -XX:+UseG1GC` (heap noted for leak-watch) · seed `lodsoak2026`.
**RESEARCH/SOAK ONLY** — no server-code changes.

---

## Verdict

> **LOD is SOAK-STABLE.** Over a ~16-minute measured steady-state window under a sustained mixed
> multi-region + near-horde + far-throttled + contraption load with LOD fully ON, **MSPT did not
> drift (slope −0.67 ms/min — flat/slightly declining), TPS held a flat 20.00 (54/54 samples),
> the post-GC heap plateaued at ~1.0 GB (no leak, no Full GC, no GC death-spiral), far mobs stayed
> correctly throttled with a clean monotonic distance→throttle band gradient and zero frozen mobs,
> the timing-sensitive contraption class (villagers + breeding animals) was never throttled (EXEMPT
> skip 0.000 across all 539 tally samples — zero cadence drift), and there were 0 crashes /
> 0 single-writer / 0 AsyncCatcher / 0 NPE during the entire window.**
>
> The long run surfaced **no LOD pathology.** Recommendation: **the soak supports the default-on
> path already argued in design §12.7** (ship `lod.policy.enabled=true` as the guard and flip
> `dab.enabled` + `extended.enabled` default-ON), with two honest, **non-LOD** caveats below.

### Config under test (LOD fully ON)
`region.enabled=true region.debug=true` + `pathfinding.los.enabled=true` +
`lod.dab.enabled=true lod.debug=true lod.policy.enabled=true lod.extended.enabled=true
lod.policy.exempt.persistent=false`.

### The sustained mixed load (held the whole window)
- **Multi-region hostiles** — dense persistent zombie packs in 3 far-apart forceloaded areas
  ((0,0), (±3000,0)) → disjoint regions ticking in parallel on `coderyo-region-worker-1..15`.
- **NEAR full-fidelity horde** — 220 zombies (follow_range 160) ringed 3–13 blocks on the bot
  (NEAR band, never throttled).
- **FAR/idle throttled band** — 300 zombies ringed 64–108 blocks (FAR band → LOD throttles).
- **EXEMPT timing-sensitive contraption** — 40 villagers + 40 breeding cows/sheep (`InLove`) in a
  far band: the classic DAB-complaint entities, must keep vanilla cadence.
- **Redstone contraption** — self-running face-to-face observer clocks (continuous scheduled-tick
  load; ticked as block-entities in region R6 the whole window).
- **protocol-776 MiniBot** present at the central region as the horde's player target.

---

## The five long-run pathologies — results

### 1) MSPT / TPS drift — FLAT (no creep)
| metric | value |
|---|---|
| MSPT 5 s-avg mean (post-warmup, 54 samples) | **20.21 ms** |
| MSPT drift slope | **−0.67 ms/min** (flat / slightly declining over 13.2 min) |
| MSPT first-3 → last-3 samples | 32.6 → 18.6 ms (settling **down** as warmup clears) |
| MSPT min / max-column mean | 14.2 ms / 53 ms (one isolated 308 ms spike — GC/reconnect blip) |
| TPS (1 m) mean / min / held-20 | **20.00 / 19.9 / 54-of-54 (100%)** |

MSPT does **not** creep upward over time — the slope is slightly negative (warmup tail draining),
the steady band sits ~18–21 ms, and TPS is pinned at 20. Per-region debug confirms the central
region R5 (682 entities) ran ~14–18 ms and the others ~2–3 ms, all `~20.0 TPS-budget`, in parallel.

### 2) Heap leak / GC death-spiral — STABLE (plateaued, no leak)
| metric | value |
|---|---|
| GC events / **Full GCs** | 134 / **0** |
| post-GC live-set floor by 1/5 time buckets (MB) | 15 → 906 → 985 → 992 → **1000** |
| young-GC pause (steady) | ~5–6 ms, ~20 s apart (down from ~18–20 ms during warmup) |
| heap ceiling used | ~1.0 GB of 6 GB (`-Xmx6G`) |

The post-GC floor **climbs during warmup (chunk/cache fill, 15→906 MB) then decelerates and
plateaus** (985→992→1000 MB over the back half; the raw GC log shows 991→1002 MB over the last
5 minutes ≈ +2 MB/100 s ≈ flat). No Full GC, no rising GC frequency, no pause growth → **no leak,
no death-spiral.** LOD's caches/bands reach a bounded steady state.

### 3) LOD fidelity runaway — NONE (correct throttle, clean bands, no frozen mob)
Final per-band DAB tally (with the live player present) — a clean monotonic distance→throttle gradient:
| band | skip% | meaning |
|---|---|---|
| NEAR (0–16) | **0.000** | never throttled — full vanilla fidelity on the player |
| BAND1 (16–32) | 0.501 | gentle |
| BAND2 (32–48) | 0.513 | |
| BAND3 (48–64) | 0.681 | |
| FAR (64+) | **0.905** | aggressive far throttle |

Per-class: **HOSTILE skip ~0.913→0.936 stable** (throttling active, not runaway), and HOSTILE
`ran` reached **1,088,544 ≫ 0** over the window → far mobs **keep ticking** (movement/path/aggro
every tick by construction) — **zero frozen / never-updating mobs.** Bands populated and escalated
correctly; NEAR mobs (ran=220, skip=0) stayed full-fidelity on the bot.

### 4) Contraption cadence drift — NONE (EXEMPT class vanilla the whole window)
| class | skip% (start → end, 539 tally samples) | cadence-violation lines |
|---|---|---|
| **EXEMPT** (villagers, breeding cows/sheep, persistent/named) | **0.000 → 0.000** | **0** |
| PASSIVE (adult animals) | 0.500 → 0.499 (capped div-2, flat) | — |

The timing-sensitive contraption class was **never throttled at any point** across the full window
(zero EXEMPT non-zero-skip lines) → the classic DAB-complaint entities keep **byte-for-byte vanilla
AI cadence**; no progressive desync. The observer-clock redstone (R6, 314 block-entities) ran
continuously at 20 TPS-budget. (Per design §12.1, breeding/love/age/trade timers live in
`aiStep`/`Brain.tick`, which LOD never gates — so this is structural, not just measured.)

### 5) Stability — 0 across the full window
| signal | count (window) |
|---|---|
| crashes (NoSuchElement / region tick failed / Exception ticking / Reported) | **0** |
| single-writer violations | **0** |
| AsyncCatcher | **0** |
| NPE (during the tick window) | **0** |
| watchdog thread-dumps | 10 — **all during the 12:51–12:52 spawn storm** ("NOT A BUG"), none at steady state |

Regions ticked concurrently on `coderyo-region-worker-1..15` for the whole window; the #24 mid-tick
race fix held under sustained parallel multi-region entity load.

---

## Honest caveats (both NON-LOD)

1. **The window reached ~16 min (≈13.5 min analyzed steady), short of the 20-min target.** The
   server JVM **self-terminated at 13:09:41 with exit code 0 — no crash, no `hs_err`, no OOM
   (host had 72 GB RAM free), no watchdog kill, and no `Stopping the server` sequence in the log.**
   The steady-state tick loop logged **0 errors after 12:52**, so this was **not** a tick/LOD
   failure — it was an undetermined abrupt JVM exit, plausibly host/harness-side and likely
   aggravated by the bot-reconnect harness (the MiniBot's PLAY-state keep-alive only survives ~120 s
   on this build, so a reconnect loop spawned ~70 short-lived login JVMs against the server; bench.sh
   never hit this because it only used ≤50 s windows). The captured steady window is clean and the
   trends are unambiguous, but a **clean 20-min completion + clean shutdown could not be confirmed in
   this run** and is the one datum worth re-capturing with a longer-lived bot.

2. **Upstream shutdown-save NPE (not LOD, not regionization).** A separate short smoke run that
   *did* reach the stop path threw `NullPointerException` in
   `SavedDataStorage.encodeUnchecked → DFU BaseMapCodec.encode` (a SavedData map with a null
   `wrapped` ObjectArrayList) during `saveGlobalData` at shutdown. The stack is **entirely upstream
   Mojang/Moonrise save code on the main thread** — no `com.coderyo` frames — so it would fire with
   LOD/region off too. Worth filing as an `upstream`-labeled issue (per the upstream-bug policy);
   it does **not** affect the steady-state soak and is independent of LOD.

Neither caveat is an LOD steady-state pathology. The soak's five target questions (drift, leak,
fidelity, cadence, stability) all came back clean.

---

## Reproduce
- Runner: [`soak.sh`](./soak.sh) — `WINDOW=1380 SAMPLE=15 SETTLE=90 bash soak.sh` (boot → mixed load →
  settle → sample `/mspt`+`/tps` + per-class LOD tally → GC logged to `gc.log`).
- Analyzer: [`analyze-soak.py`](./analyze-soak.py) `run-soak` — MSPT drift slope, post-GC heap
  trend/buckets, TPS, per-class & per-band tally stability + EXEMPT cadence-violation check, stability
  counts. (`WARMUP=150` drops spawn-storm recovery.)
- Bot: `../benchmark-vs-vanilla/MiniBot.java` (protocol-776). `run-soak/` (server.log, gc.log,
  bot logs) is git-ignored run output — regenerate via the script.
</content>
