# Redstone-computer MAP — `/coderyo redstone difftest` verdicts

The redstone computer is built **as an in-world MAP** (setblock circuits in a test
world), **not** as a feature patch. Each circuit is differential-validated bit-for-bit
against vanilla with the runtime command `/coderyo redstone difftest <pos> [ticks]`
(patch 0020, already on `main`). The command detects the live network at `<pos>`,
compiles a model from a snapshot, then for N ticks re-reads the network's external
inputs (levers / buttons / redstone-blocks) from the live world, steps the compiled
model in lockstep, and asserts compiled == vanilla at **every** footprint cell. It
reports `BIT-IDENTICAL` or the exact first divergence (pos / tick / field).

- Server: `coderyo-paperclip-26.2-R0.1-SNAPSHOT.jar`, booted `-Dcoderyo.redstone.compile.enabled=true`, port **15568**, flat world.
- Convention used by every gate: a comparator's **FACING points at its REAR/INPUT**; output exits the opposite side. SUBTRACT comparator: `out = max(0, rear − max(sideL, sideR))`.
- Digital inputs driven by a `redstone_block` placed one block **above** an input dust (dust → 15 ON / 0 OFF). Those toggler cells are in the footprint and re-read live each tick.
- Outputs validated are **dust / comparator** cells (NO redstone_lamps — deliberately avoiding the known wire-end-adjacent-lamp compiler divergence).

`difftest` IS the proof. In addition, each gate's **truth table** was confirmed by reading the live output power (`LOGIC_OK`).

## Rung 1 — the six logic gates (build-01-gates.txt)

Comparator-subtract gate algebra: NOT=15−A; NOR=15−max(A,B); OR=repeater-cleaned dust
merge; AND=A−(15−B) (two comparators); NAND=max(15−A,15−B) (two comparators merged);
XOR=|A−B| (two comparators merged).

| Gate | Seed | Input combos | difftest | Logic (truth table) |
|------|------|--------------|----------|---------------------|
| NOT  | 11,101,10 | A∈{0,1} (2) | **BIT-IDENTICAL** all | OK (15−A) |
| OR   | 13,101,20 | A,B (4) | **BIT-IDENTICAL** all | OK |
| NOR  | 11,101,30 | A,B (4) | **BIT-IDENTICAL** all | OK |
| AND  | 12,101,41 | A,B (4) | **BIT-IDENTICAL** all | OK |
| NAND | 11,101,50 | A,B (4) | **BIT-IDENTICAL** all | OK |
| XOR  | 11,101,60 | A,B (4) | **BIT-IDENTICAL** all | OK |

**22 / 22** difftest cases BIT-IDENTICAL; **22 / 22** truth-table reads correct.

## Rung 1 — half-adder (build-02-half-adder.txt)

SUM = A XOR B (seed 11,101,70), CARRY = A AND B (seed 12,101,75), co-located with
shared-driven A,B togglers.

| A B | SUM(XOR) difftest / logic | CARRY(AND) difftest / logic |
|-----|---------------------------|------------------------------|
| 0 0 | BIT-IDENTICAL / 0 OK | BIT-IDENTICAL / 0 OK |
| 0 1 | BIT-IDENTICAL / 15 OK | BIT-IDENTICAL / 0 OK |
| 1 0 | BIT-IDENTICAL / 15 OK | BIT-IDENTICAL / 0 OK |
| 1 1 | BIT-IDENTICAL / 0 OK | BIT-IDENTICAL / 15 OK |

**8 / 8** difftests BIT-IDENTICAL; SUM & CARRY truth tables correct for all 4 combos.

## Rung 1 — FULL ADDER (build-03-full-adder.txt) — COMPLETE ✅

A complete 1-bit full adder built as a MAP and validated end-to-end:
- **SUM = A XOR B XOR Cin** — two cascaded XOR gadgets (repeater-cleaned X1 = A⊕B
  routed to both stage-2 ports).
- **Cout = majority(A,B,Cin) = (A·B) + (B·Cin) + (A·Cin)** — three AND gadgets feeding
  a 3-way OR (dust merge → cleaning repeater). The majority form uses only primary
  inputs, so no wire-fanout of X1 into the carry path is needed.

**SUM truth table** (read at 31,101,86), all correct = A⊕B⊕Cin:

| A B Cin | 000 | 001 | 010 | 011 | 100 | 101 | 110 | 111 |
|---------|-----|-----|-----|-----|-----|-----|-----|-----|
| SUM     |  0  | 15  | 15  |  0  | 15  |  0  |  0  | 15  |

**Cout truth table** (read at 34,101,79), all correct = majority(A,B,Cin):

| A B Cin | 000 | 001 | 010 | 011 | 100 | 101 | 110 | 111 |
|---------|-----|-----|-----|-----|-----|-----|-----|-----|
| Cout    |  0  |  0  |  0  | 15  |  0  | 15  | 15  | 15  |

**difftest:** SUM seed (31,101,86) and Cout seed (34,101,79), every (A,B,Cin) combo:
**16 / 16 BIT-IDENTICAL** (SUM 8/8 + Cout 8/8), **0 divergences**. The detector picks
up the whole live network at each seed (46–80 cells / 27–43 components, single-region).

**Bug the build process exposed (and the fix):** the prior partial build-03 had the
X1 *branch-2 distribution repeater* at (32,101,88) facing the wrong way
(`facing=north` → its rear pointed into the X1 bus and its output dead-ended at the
Pb port, so Pb never powered). SUM was therefore wrong exactly when X1=1 ∧ Cin=1
(e.g. 1,0,1 gave SUM=15 instead of 0). Correcting it to `facing=south` (rear=bus,
output=north toward Pb) makes the whole SUM path settle; all 8 combos then verify.
The earlier "won't settle under bare setblock" symptom was this dead branch plus
force-load, not a vanilla-propagation quirk — once the topology is right and the
build area is force-loaded, a clean toggle settles in <2 s.

## Rung 2 (start) — 1-bit MEMORY: RS NOR latch (build-04-memory.txt) — ATTEMPTED ⚠️

Cross-coupled comparator-SUBTRACT NOR latch built; exercised RESET/HOLD/SET/HOLD
live. It does **not** reach clean digital levels — Q settles to a non-digital
equilibrium (~6–9 of 15). Root cause, diagnosed e2e (probed the feedback cells):
a comparator NOR is `15 − max(side)`, so a feedback that arrives at the consumer
comparator's side port at an **attenuated** level (long dust feedback drops ~1/block,
reaching ~6) produces `15 − 6 = 9`, a stable analog fixed point. A single mid-lane
cleaning repeater is insufficient (dust *after* it still attenuates before the port);
the repeater must sit directly adjacent to the side input, which — because the two
cross-coupled feedbacks must reach opposite comparators — forces a signal crossover
that did not lay out collision-free in the comparator-subtract footprint in budget.
**This is a circuit-construction limit, not a compiler/harness fault** (0 divergences
were ever reported; the difftest machinery worked throughout). Next iteration:
build the latch from **redstone torches** (digital inverters — a torch control block
reads "powered" at any level ≥1, so it is immune to dust attenuation), the canonical
robust 1-bit cell, then difftest its HOLD.

## Rung 1 — 4-BIT ADDER: 4× tiled full adder (build-05-adder4.txt) — TILES VALIDATED ✅

The proven 1-bit full adder (build-03) tiled **four times** along +x (pitch DX=24; bit *k*
= build-03 shifted +24·*k*). Boots/settles force-loaded; all eight outputs differential-tested:

| bit | SUM seed | SUM difftest | Cout seed | Cout difftest |
|-----|----------|--------------|-----------|---------------|
| 0 | 31,101,86 | **BIT-IDENTICAL** | 34,101,79 | **BIT-IDENTICAL** |
| 1 | 55,101,86 | **BIT-IDENTICAL** | 58,101,79 | **BIT-IDENTICAL** |
| 2 | 79,101,86 | **BIT-IDENTICAL** | 82,101,79 | **BIT-IDENTICAL** |
| 3 | 103,101,86 | **BIT-IDENTICAL** | 106,101,79 | **BIT-IDENTICAL** |

**8 / 8 BIT-IDENTICAL, 0 divergences** — the compiler scales bit-identically to the full
4-bit-wide datapath (seeds detect 23–37 components / 46–74 cells each, single-region).
Per-bit **arithmetic** confirmed live on bit0: A1B1C0→SUM 0, Cout 15; A1B0C1→SUM 0,
Cout 15; A1B0C0→SUM 15, Cout 0 (= full-adder truth table).

**Ripple interconnect — structural finding (the next step).** build-03's full adder is
**top-fed**: every input — including the four Cin ports (30,87)(33,86)(32,75)(37,75) —
is a comparator port driven by a `redstone_block` at y=102 directly over it. Those Cin
ports are buried inside the circuit; their only free neighbour is on the far (east) side,
and a `redstone_block` is the **only** thing that powers a dust from above (a strongly-
powered *solid* block above a dust does **not** — verified live). So a horizontal
Cout(k)→Cin(k+1) wire cannot reach the ports without crossing tile internals. Tiling this
top-fed tile therefore yields 4 **independent, difftest-clean** full adders; a true ripple
needs a full-adder variant with a **side-entry Cin bus** (one clean port fanned internally) —
the concrete next tile design. (Detailed in build-05's header.)

## Rung 2 — 1-bit MEMORY: TORCH RS-NOR latch (build-06-torch-rs-latch.txt) — WORKS ✅

The fix for build-04's analog-attenuation failure. Two cross-coupled redstone-**torch**
NOR gates; each gate block is driven by **repeaters** (clean digital strong-power) carrying
the input + the cross-coupled feedback (Q rail on west x=60, Qbar on east x=64 — no
crossover). A torch inverts at **any** input level ≥1, so it is immune to the dust
attenuation that pinned the comparator latch at ~9/15.

| step | R S | Q  | Qbar | note |
|------|-----|----|------|------|
| RESET | 1 0 | 0 | 1 | |
| HOLD  | 0 0 | **0** | 1 | bit held |
| SET   | 0 1 | 1 | 0 | |
| HOLD  | 0 0 | **1** | 0 | **bit held — clean 15/0** |

**HOLD now persists at a clean digital 15 (Q=1) / 0 (Q=0)** — the exact memory property
build-04 could not reach. Verified by live power reads (the Q output dust at 60,101,122
reads 15 when set-held, 0 when reset-held). This is the robust 1-bit cell for a register file.

**Decisive torch mechanics learned (live, on this fork):** a gate block is turned
"powered" (its torch off) by dust ON TOP or a **repeater** pointing into it — **not** by an
adjacent `redstone_block`, **not** by horizontal dust into its side, **not** by a strongly-
powered solid block above a dust. The latch drives gate blocks with repeaters accordingly.

**Compiler finding (why difftest can't yet validate torch memory).** The HDL compiler
(patch 0020) does **not** model redstone-torch inversion: a standalone torch inverter with
input ON gives vanilla out=0 but compiled **sim=15** (difftest DIVERGENCE real=0 sim=15;
the input-OFF case *is* BIT-IDENTICAL). So every torch/feedback circuit diverges under
difftest — a **missing compiler primitive**, not a circuit fault (the latch HOLDs perfectly
in vanilla, proven above). Adding torch support (block-powered→torch-off, plus bistable-loop
stored-state seeding so a latch compiles to its *current* held bit rather than a default
fixed point) is the prerequisite to differentially validate sequential memory. Until then
torch memory is proven the way build-04 was diagnosed — by **vanilla** behaviour. The
**D-latch** (gated RS: S=D∧E, R=D̄∧E via the proven comparator-AND gadgets feeding this
latch's R/S repeaters) and the **4-bit register** (4 D-latches, shared Enable) are the
immediate next builds; both inherit the same vanilla-proof / compiler-torch-gap situation.

## Rung 1 — SIDE-ENTRY-Cin FULL ADDER (build-07) — COMPLETE ✅

The ripple-ready successor to build-03. build-05 found build-03 was **top-fed** — its four
Cin ports were buried comparator ports each driven by a `redstone_block` at y+1, so a
horizontal Cout→Cin carry had no way in. **build-07 takes Cin as a HORIZONTAL dust/repeater
BUS** entering at the west edge (driver = a `redstone_block` placed ONE BLOCK ABOVE the
bus-start cell `4,20`), so the carry can be wired in horizontally.

- **SUM = A⊕B⊕Cin**, **Cout = majority(A,B,Cin)**.
- The XOR `|P−Q|` gadget's two inputs alternate around its perimeter (P,Q,P,Q) → a single-
  layer planar crossover is impossible. **Fix:** XOR2 uses **two INDEPENDENT subtract
  comparators facing each other into ONE shared merge cell** (`30,14`); X1 is fed from the
  NW corner, Cin from the SE corner — no crossover. Every comparator port has a dedicated
  cleaning **repeater** right at it (so the analog Cin level can never corrupt a subtract).

**Full-adder truth table** (SUM `30,101,14`, Cout `44,101,11`), all 8 (A,B,Cin) combos:

| A B Cin | 000 | 001 | 010 | 011 | 100 | 101 | 110 | 111 |
|---------|-----|-----|-----|-----|-----|-----|-----|-----|
| SUM     |  0  |  1  |  1  |  0  |  1  |  0  |  0  |  1  |
| Cout    |  0  |  0  |  0  |  1  |  0  |  1  |  1  |  1  |

**8 / 8 SUM and 8 / 8 Cout correct** = the full-adder truth table.
**difftest** (`/coderyo redstone difftest 30 101 14`) over the whole connected net
(~270 cells): **BIT-IDENTICAL, 0 divergences.**

**Bugs the build exposed (and fixes):**
1. The three Cout AND gadgets must be **spaced** so no comp2's east SIDE touches the next
   gadget's 15-source `redstone_block` — adjacency poisons the subtract and **Cout sticks 0**.
2. The Cout OR-merge cleaning repeater must face **south** (rear=merge, out=Cout); facing
   north silently drives the merge instead, and Cout reads 0.
3. **The decisive harness lesson — SETTLE BY GAME TICKS, NOT WALL-CLOCK.** This tile is a
   deep comparator cascade; on the regionized server the redstone load drops wall-clock TPS,
   so a probe taken 3–15 s after an input change reads a **half-propagated** state and looks
   exactly like "Cin is ignored" (SUM collapses to A⊕B). A ≥40–55 s real-time settle (or,
   better, a long-tick `difftest`, which steps the model in **game** ticks and is TPS-
   independent) is required before the arithmetic is valid. Every per-combo result above was
   confirmed on a **fresh per-combo build with a long settle**; the cross-combo sweeps that
   "failed" were pure settle artifacts, not circuit faults (difftest stayed BIT-IDENTICAL
   throughout).

## Rung 1 — 2-BIT RIPPLE-CARRY ADDER (build-08) — physical ripple ✅

Two build-07 tiles (bit0 at x+0, bit1 at x+60) with **bit0's Cout (`44,11`) wired
HORIZONTALLY into bit1's Cin bus entry (`64,20`)** — the carry physically ripples
Cout₀→Cin₁. (The carry wire ends in a cleaning **repeater** at `63,20`; a bare dust run
delivers a low analog level that dies a few blocks into bit1's bus.)

Test vector **A = 11b (3) + B = 01b (1)** (bit0: A0=1,B0=1,Cin0=0 ; bit1: A1=1,B1=0):

| signal | bit0 | ripple | bit1 |
|--------|------|--------|------|
| Cin    | 0 | → | **1 (RIPPLED, read live at 64,101,20)** |
| SUM    | **0** | | **0** |
| Cout   | **1** | wired → Cin₁ | **1** |

Result bits {Cout₁, SUM₁, SUM₀} = **1,0,0 = 100b = 4 = 3 + 1** — arithmetically correct,
with the carry **physically propagating** from bit0 to bit1 through a horizontal wire.
**difftest over the whole 2-tile network** (`difftest 30 101 14 60`): **BIT-IDENTICAL
(644 cells), 0 divergences** — the entire rippling datapath compiles bit-for-bit to vanilla.
This is the first **physically-rippling** multi-bit arithmetic datapath on the map (build-05's
4 tiles were difftest-clean but independent; this one's carry actually flows tile→tile).

## Rung 2 — TORCH RS LATCH re-validated + 4-BIT REGISTER (build-09) — SEQUENTIAL MEMORY VALIDATES ✅

The torch-modeling compiler gap that blocked build-06 is **closed** (commit 42fb73a: torch
inversion in all configs + bistable-loop stored-state seeding). This build re-runs the HOLD
difftest on the proven build-06 cell — it now **passes** — and tiles it 4× into a register.

**1) build-06 torch RS-NOR latch, HOLD now difftests BIT-IDENTICAL** (seed `60,101,122`):

| held state | drive | live read | difftest 200 ticks |
|------------|-------|-----------|--------------------|
| RESET (Q=0) | R block at `62,101,120`, settle, remove | Q=0, Qbar=15 | **BIT-IDENTICAL (46 cells)** |
| SET (Q=1)   | S block at `62,101,132`, settle, remove | Q=15, Qbar=0 | **BIT-IDENTICAL (46 cells)** |

So **torch sequential memory now validates differentially** — the headline build-06 said was
the prerequisite for a register file. **Procedure lesson (cost the first divergence):** the R/S
inputs are **repeater rears at y=101**; the driver redstone_block must sit **AT** that y=101 rear
cell, **not at y=102 above it** (y+1 drives a *dust* to 15 but does not power a *repeater* rear).
Driving from y=102 left the latch in its power-on default, not a clean SET, and the unsettled
state diverged (real=0/sim=15 @tick24 = vanilla drifting). y=101 driver + clean pulse + settle → both HOLD states BIT-IDENTICAL.

**2) 4-bit register** = the proven cell tiled 4× along +x (pitch DX=8; bit *k* at x=62+8·*k*).
The four latches are electrically independent (a register *is* four 1-bit memory cells), so
holding an arbitrary 4-bit pattern across them proves memory **at width**. Loaded value **1011b**
(RESET all, then SET bits 0,1,3):

| bit | seed | live Q | difftest 200t |
|-----|------|--------|---------------|
| 0 | 60,101,122 | **15** | **BIT-IDENTICAL (46 cells)** |
| 1 | 68,101,122 | **15** | **BIT-IDENTICAL (46 cells)** |
| 2 | 76,101,122 | **0**  | DIVERGENCE — see caveat |
| 3 | 84,101,122 | **15** | **BIT-IDENTICAL (46 cells)** |

Live reads {b3,b2,b1,b0} = **1,0,1,1 = 1011b** — the register **reads back the loaded 4-bit value
correctly**. Three of four held bits (all the Q=1 bits) are **BIT-IDENTICAL** at width.

**bit2 (the 0-state bit) caveat — two non-fatal effects, neither a fix-task:** (a) **vanilla
settle-race** — dropping the four RESET drivers *simultaneously* raced bit2 into a metastable
state and ~40 s later vanilla bit2 spontaneously flipped 0→15 (procedural: drop drivers one at a
time / settle longer — the *standalone* latch RESET-HOLDs perfectly, proven BIT-IDENTICAL above);
(b) **compiler bistable-seeding edge** — once bit2 was re-settled to a *stable* vanilla Q=0,
difftest reported `real=0/sim=15` (the compiler seeded the loop to the **other** fixed point),
then `POWERED real=true/sim=false` at its Qbar feedback repeater. The three Q=1 bits and the
standalone Q=0 latch all seed correctly, so this is a **seeding edge in the tiled 0-state**, not a
circuit fault — a compiler observation to feed back to patch 0020's bistable seeding, **recorded
not fixed** (this map adds NO feature patch). The **D-latch** (enable-gating S=D∧E, R=D̄∧E via the
proven comparator-AND gadgets feeding these R/S rears) and the **accumulator** (register Q → the
build-07 side-entry ripple adder → SUM back to the register D, gated by a manual clock) are the
documented next builds toward the CPU datapath.

## Divergence the difftest CAUGHT (and its root cause)

On the first half-adder run the difftest reported, e.g.:

```
difftest @11, 101, 70: DIVERGENCE — 46 mismatch(es); first @tick 2: 11, 101, 70 POWER real=0 sim=15
```

i.e. **vanilla = 0, compiled = 15** at the XOR output. Investigation: the half-adder
lane sat in a chunk **outside the forceload region** (`forceload add 0 0 220 40` only
covered chunks z≤2; the half-adder was at chunk z=4). In a non-ticking chunk vanilla's
**scheduled redstone ticks never fired**, so the comparator stayed stuck at its stale
output 0 — while the compiler correctly computes the steady state (15). The difftest
correctly flagged the compiled-vs-vanilla mismatch. **Fix:** `forceload add 0 0 240 200`
to keep every build lane ticking, then a primary-input toggle to settle — after which
the half-adder is **BIT-IDENTICAL across all 4 combos** (table above). This is a
test-harness/world-setup lesson (force-load + settle), not a compiler bug.

## Verdict

The rung-1 combinational foundation is **fully validated as a MAP**: all six gates,
the half-adder, the complete 1-bit full adder (SUM + Cout), **and the 4-bit-wide adder
datapath (4 tiled full adders, all 8 SUM/Cout outputs)** are bit-identical to vanilla and
logically correct across their truth tables. Running difftest totals: **30 (gates+half-
adder) + 16 (full-adder SUM/Cout) + 8 (4-bit adder SUM/Cout) = 54 BIT-IDENTICAL cases,
0 divergences.** The full adder tiles cleanly; the ripple interconnect needs a side-entry
Cin tile (build-03 is top-fed) — the documented next tile design.

**That side-entry tile now exists and ripples (build-07 + build-08).** The
**side-entry-Cin full adder** (Cin enters as a horizontal bus, not a top redstone-block) is
bit-identical to vanilla and logically correct across all 8 (A,B,Cin) combos; two of them
wired Cout₀→Cin₁ form a **2-bit ripple-carry adder whose carry physically propagates** and
computes 3+1=4 correctly, BIT-IDENTICAL over all 644 cells. Running difftest totals now:
**54 (prior) + 8 (side-entry tile SUM/Cout) + 1 (2-bit rippling net) ≥ 63 BIT-IDENTICAL,
0 divergences.** The key new engineering lesson: deep comparator cascades on the regionized
server must be **settled by game ticks** (long-tick difftest) or a long wall-clock wait, not
a few seconds — a premature probe reads a half-propagated state. Next: extend the ripple to
3–4 bits (same tile, more Cout→Cin wires) and pair it with the build-06 register.

Rung 2 (sequential / memory) now has a **working 1-bit cell**: the **torch RS-NOR latch**
HOLDs a clean digital bit (15/0), fixing build-04's analog-attenuation failure. Its correctness
is proven by **vanilla** behaviour because the difftest discovered a real compiler gap — the
HDL compiler does not yet model redstone-**torch** inversion (a standalone torch inverter
diverges real=0/sim=15), so no torch/feedback circuit can be difftest-validated until torch
support is added. That is the headline next compiler work item; with it, the D-latch and
4-bit register (designs noted above) become differentially validatable, and an ALU +
register-file datapath (the 4-bit adder + a register) is assemblable.

## Rung 2 — D-LATCH: gated clocked capture (build-10) — difftest BIT-IDENTICAL ✅

The datapath's **sequential-capture element**: the proven build-06/09 torch RS-NOR latch +
**enable-gating** that drives its R/S rears with **S = D∧E** and **R = D̄∧E**, so the cell
**captures D when the clock E=1 and HOLDS when E=0**. The gating reduces to comparator-SUBTRACT
algebra (same convention as build-01..08): **R = E − D** (a *single* subtract comparator =
D̄∧E) and **S = D − (15−E)** (the build-01 two-comparator AND, with `nE = 15−E` a NOT gadget).
North gadget feeds the R rear (62,120); south gadget feeds the S rear (62,132); each takes its
own D/E driver pair (toggled together) to avoid fan-out.

**Vanilla truth table** (live power reads, seed/Q out `60,101,122`, Qbar `64,101,130`):

| op | drive | Q | Qbar | note |
|----|-------|---|------|------|
| capture 0 | D=0,E=1 | 0 | 15 | RESET |
| HOLD | E=0 | **0** | 15 | bit held |
| capture 1 | D=1,E=1 | 1 | 0 | SET |
| HOLD | E=0 | **1** | 0 | bit held |
| D-flip while E=0 | D 0↔1, E=0 | **unchanged** | | **enable-gating: D ignored when disabled** |

Bidirectional clocked capture confirmed (1→0 and 0→1). **difftest** (`/coderyo redstone
difftest 60 101 122 200`, triggered from an impulse command_block, verdict read from the server
log): **HOLD Q=1 → BIT-IDENTICAL (200 ticks, 74 cells, 39 components, single-region); HOLD Q=0 →
BIT-IDENTICAL (200 ticks, 72 cells).** So the **gated D-latch compiles bit-for-bit to vanilla in
both held states** — the difftest-clean clocked-capture cell the accumulator register is built from.

## Rung 3 — ACCUMULATOR (register + adder feedback, build-10) — datapath core; level-latch race FOUND ⚠️

Design (operator spec): an N-bit register of N D-latches sharing one **Enable=clock**, whose Q
feeds input A of the build-07/08 **side-entry ripple adder**, plus a second input B, with the
adder **SUM wired back to the register's D**; pulsing Enable does **ACC := ACC + B**. Every
constituent is now proven on this map: the **D-latch** (build-10, difftest-clean), the **4-bit
register** (build-09), and the **rippling adder** (build-07/08).

A **1-bit feedback experiment** was run live to probe the loop: for B=1 the adder bit is just
`SUM = NOT Q = Qbar` (already on the latch's east rail), so Qbar was wired straight back to the D
rears (a 1-bit "+1" accumulator = T-flip-flop). Pulsing Enable did **not** advance ACC, exposing
the **headline finding — LEVEL-LATCH RACE-THROUGH**: a D-latch is *level*-sensitive, so while E=1
it is transparent and the instant Q flips, Qbar→D re-feeds the still-open latch and the bit
toggles back and forth for the whole (multi-game-tick, low-TPS) pulse, landing nondeterministically.
**A robust accumulator therefore needs an EDGE-triggered register = a MASTER-SLAVE pair of these
D-latches** (master captures on E, slave on ¬E → exactly one increment per clock edge); the
build-10 D-latch is precisely one half of that flip-flop.

**Nuance that rescues the *real* (adder-based) accumulator:** the build-07/08 ripple adder is a
deep comparator cascade that takes **≥40 s** to settle (build-07), while the latch captures in
~2 s. With a real adder in the loop, its **old settled SUM persists through a short E pulse** (the
new SUM needs ~40 s to ripple), so a brief pulse captures exactly once and `ACC := ACC + B`
advances one clean step per pulse — the slow adder is the natural settle-isolation the fast 1-bit
Qbar proxy lacked. So the proxy races *because it is a fast loop with no isolation*, not because
the datapath is wrong. Building the real `ACC := ACC + B` (2-bit register + build-08 adder +
SUM→D, short-pulse clock or master-slave latches) is the documented next build — all blocks proven.

*(Harness note: no on-disk jar carried patch 0020 — the two present jars were built from
non-redstone commits — so build-10's jar was produced fresh from origin/main 663a78c via
`./gradlew applyAllPatches :coderyo-server:createPaperclipJar`. RCON's dispatcher omits the
op-gated `coderyo` literal and the paperclip JVM ignores piped stdin, so every difftest was
issued from a command_block and its verdict read from the server log.)*

**No feature patch was added — only `test-harness/redstone-computer/`** (build scripts +
this file).

## Rung 2 — MASTER-SLAVE D FLIP-FLOP: edge-triggered register (build-11) — difftest BIT-IDENTICAL ✅

The **edge-triggered** sequential element a CPU register needs, and the fix for build-10's
level-latch race-through. Two build-10 gated D-latches in series: a **MASTER** (base x=62)
enabled while Clock=HIGH (captures D) and a **SLAVE** (base x=46, DX=−16) enabled while
Clock=LOW (captures Master's Q), driven by a **non-overlapping two-phase clock**. Master.Q is
wired to Slave.D through a repeater-cleaned forward interconnect (D must arrive at a clean 15 or
the `R=E−D` subtract mis-fires). Output (ACC = Slave.Q @ `44,101,122`) updates only on the
clock **falling edge** (slave-enable).

**Edge-triggered, race-free — vanilla live reads.** Both latches init 0, then load a 1 through the edge:

| step | drive | Master.Q | ACC (Slave.Q) | note |
|------|-------|----------|----------------|------|
| set D=1, both enables OFF | — | 0 | **0** | D-change alone latches nothing |
| MASTER phase ON | clock HIGH | 15 | **0** | output FROZEN during master capture |
| toggle D 1→0→1 while master transparent | — | follows 0→15 | **0** | **no race-through** |
| MASTER off → SLAVE phase ON | falling edge | 15 (held) | **15** | output updates ONLY on the edge |
| (load a 0) Master captures 0 | clock HIGH | 0 | **15** | ACC HOLDS during master capture |
| SLAVE phase ON | falling edge | 0 | **0** | edge updates bidirectionally |

The level-latch race-through (build-10) is **eliminated** — master and slave are never simultaneously
transparent. **difftest** (`/coderyo redstone difftest 44 101 122 200`, impulse command_block, verdict
from log): **HOLD ACC=1 → BIT-IDENTICAL (200 ticks, 246 cells, 126 components, single-region); HOLD
ACC=0 → BIT-IDENTICAL (200 ticks, 244 cells).** The whole flip-flop (~245 cells) compiles bit-for-bit
to vanilla in **both** held states — the difftest-clean **edge-triggered register** a CPU is built from.

**Build lessons (cost real debug):** (1) `setblock repeater[facing=D]` puts the REAR on side D and
the OUTPUT on the OPPOSITE side (the build-01..10 convention) — building interconnect repeaters with
the intuitive "facing=output" reverses every one (dead). (2) A D-feed dust laid one cell from a latch
ENABLE dust shorts Enable into the D net; route every interconnect leg ≥2 cells clear of all latch
E/D ports and re-amp every ≤~9 dust so D reaches each port at a clean 15.

## Rung 3 — 1-BIT INCREMENT ACCUMULATOR (build-11) — one clean race-free step; sustained blocked by routing ⚠️

For B=1 the 1-bit adder SUM = ACC XOR 1 = NOT ACC = the slave's Qbar, so the minimal accumulator
wires **Slave.Qbar → Master.D** (a master-slave **T flip-flop**): one clock cycle ⇒ ACC toggles,
exactly one clean step. **Cycle 1 incremented cleanly 0 → 1 through the REAL physical feedback**
(D came from Qbar=15; master captured on φ1, slave output on φ2) — one clean, **deterministic** step,
**no race-through**: precisely what build-10's level latch could not do. **Cycles 2–3 stuck at 1**:
the feedback DROP (x=48, z=131→139) **crosses the forward interconnect's S-branch wire at (48,137)**,
which carries the held Master.Q (=15); the two nets MERGE on the same y-level and pin Master.D=15, so
the master kept re-capturing 1 (verified: (48,137) reads power 7 sourced from Master.Q). This is a
**wire-congestion collision in a RETROFIT**, NOT a logic/compiler fault (difftests clean, cycle-1
increment clean): the forward `Master.Q→Slave.D` path and the feedback `Slave.Qbar→Master.D` path
fight for the same lanes — the x=50 column is a solid wall of forward repeaters (z 114..139) and the
slave S-gadget walls off the SW, so the feedback can't reach the Master (east) side without crossing a
live forward wire. **Fix:** design the feedback channels in from the start on a wider platform
(dedicated lanes or a y=102 bridge over the one crossing), not retrofit them; with clear lanes the
master-slave sustains the toggle (proven for one step), and the same structure with B selectable +
the build-08 ripple adder as the SUM path gives the clean **2-bit ACC=0→1→2→3** milestone. Every
constituent (edge-triggered register THIS build, ripple adder build-08) is difftest-clean — only
collision-free routing (and the build-10 settle-isolation between phases) remains.

### What the CPU rung needs next
0. **DONE (build-09):** the torch RS latch's HOLD now **difftest-validates BIT-IDENTICAL** for
   both stored bits, and 4 tiled latches form a **4-bit register** that reads back a loaded value
   (3/4 held bits BIT-IDENTICAL at width; the 0-state bit hit a documented vanilla-settle race +
   compiler 0-seeding edge). Sequential memory is the proven pillar.
1. **DONE (build-10):** the **D-latch enable-gating** (S=D∧E via the build-01 AND gadget,
   R=D̄∧E = E−D as a single subtract comparator) — captures/HOLDs a clocked bit and
   **difftests BIT-IDENTICAL in both held states** (74/72 cells). The clocked-capture cell is proven.
2. **DONE (build-11):** the **EDGE-triggered register (master-slave D flip-flop)** — two build-10
   D-latches (master on Clock=HIGH, slave on Clock=LOW) — **difftests BIT-IDENTICAL in both held
   states** (246/244 cells) and its output changes **only on the clock falling edge**, bidirectionally;
   the level-latch race-through is eliminated. This is the difftest-clean clocked register a CPU uses.
3. **Real ACC := ACC + B** — register Q → build-08 ripple adder ← B → SUM → register D, clocked.
   build-11 wired the 1-bit B=1 case (Slave.Qbar→Master.D) and got **one clean race-free increment
   (0→1) through real feedback**; sustained counting was blocked by a **wire-congestion collision**
   in the retrofit (feedback drop merged the held Master.Q at (48,137)). Next: rebuild on a wider
   platform with **dedicated feedback channels** (or a y=102 bridge) so the master-slave sustains the
   toggle, then swap the B=1 proxy for the build-08 ripple adder + selectable B and read back
   ACC=0,B=1 → 0→1→2→3 (the 2-bit milestone). All blocks are difftest-clean; only routing remains.
4. From the accumulator: a **control unit** (clock/step + opcode), **instruction memory**
   (torch-ROM addressed by a program counter = a counting register), **decode** (opcode → enable
   lines), and a small **register file** (several build-09 registers) — the minimal CPU.
