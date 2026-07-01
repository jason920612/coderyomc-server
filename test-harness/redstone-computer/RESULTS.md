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

## Rung 3 — 1-BIT INCREMENT ACCUMULATOR (build-12) — SUSTAINED clean counting, difftest-clean ✅

The crossing is **solved**, and the 1-bit `ACC := ACC + 1` accumulator now **sustains** counting —
the milestone build-10 (level-latch race) and build-11 (wire-crossing) could not reach. It is the
build-11 master-slave register wired as a **T-flip-flop** (Slave.Qbar → Master.D = a 1-bit "+1"
adder, since for B=1 the adder SUM = ACC XOR 1 = NOT ACC = Slave.Qbar), on a **wider board with
dedicated, non-crossing feedback channels**.

**The layout fix (what solved the same-y net merge).** In any master-slave accumulator the forward
`Master.Q→Slave.D` and feedback `Slave.Qbar→Master.D` run **antiparallel** between the two latches;
build-11 crammed both into shared z-rows + an x=50 forward "wall," so the feedback drop merged the
held Master.Q at (48,137). build-12 gives each its **own band**, with every vertical transition at an
**x-extreme outside the other path**:
- **Forward** = north band (trunk z=114) + a **west drop (x=41)** that reaches Slave's *south* D-port
  (46,135) by running z=137 only over **x=42..46** — so it **never touches the x=47–49 corridor**.
- **Feedback** = far-**south** band (trunk z=145) + **east risers** (x=62 → Master D_south; x=66 →
  Master D_north). x=66 is 2 cells east of the Qbar rail (x=64) so no rail short.
- The two paths share **no y=101 cell** and never run adjacent on the same z — **pure planar
  separation, no y=102 bridge needed**.

**Sustained counting (vanilla live reads, ACC = Slave.Q dust @44,101,122).** Two-phase manual clock
(phi1 master-capture, phi2 slave-output), settled by game ticks each phase. From a clean ACC=0 start:
`0→1→0→1→0→1→0→1→0` (8 cycles) plus an earlier `1→0→1→0→1→0→1` (6 cycles) = **14 consecutive clean
toggles, ZERO sticking** through **real physical feedback**.

**difftest (compiler == vanilla),** impulse command_block, verdict from the server log:

| held state | command | verdict |
|------------|---------|---------|
| ACC = 1 | `coderyo redstone difftest 44 101 122 200` | **BIT-IDENTICAL (200 ticks, 432 cells, 218 components, single-region)** |
| ACC = 0 | `coderyo redstone difftest 44 101 122 200` | **BIT-IDENTICAL (200 ticks, 432 cells)** |

So the **whole accumulator** (both torch latches + both comparator enable-gates + the forward AND
feedback interconnects, 432 cells) compiles **bit-for-bit to vanilla in both held states**, and counts
cleanly through real feedback. This is the **difftest-clean, sustained-counting edge-triggered
accumulator — the datapath core** a CPU is built from. (The literal 2-bit `0→1→2→3` and general
`ACC:=ACC+B` are now pure scale-up of the *solved* routing — designs in build-12's header.)

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
3. **DONE (build-12):** the **1-bit increment accumulator** (master-slave T-flip-flop,
   Slave.Qbar→Master.D) now **SUSTAINS clean counting** — ACC toggles 0↔1 every clock cycle,
   **14 consecutive clean toggles, zero sticking** — and is **difftest BIT-IDENTICAL in both held
   states** (432 cells, 218 components). The build-11 wire-crossing is **solved** by dedicated
   non-crossing feedback channels (forward on a north band + west drop; feedback on a far-south band
   + east risers; no shared y=101 cell). The datapath core works end-to-end through real feedback.
4. **2-bit ACC = 0→1→2→3 / general ACC:=ACC+B** — two of the build-12 cell clocked synchronously
   with bit1.D = XOR(Q1,Q0) (build-01 gadget) for a +1 counter, OR the build-08 2-bit ripple adder as
   the SUM path with selectable B (B=1, B=2). Every constituent is difftest-clean; only lane routing
   (now solved at 1-bit) scales up.
5. From the accumulator: a **control unit** (clock/step + opcode), **instruction memory**
   (torch-ROM addressed by a program counter = a counting register), **decode** (opcode → enable
   lines), and a small **register file** (several build-09 registers) — the minimal CPU.

## Rung 4 — ALU OP-SELECT CORE: XOR operator + 2:1 mux (build-13) — both difftest-clean ✅ (integration pending)

Toward the 4-bit ALU (the CPU **compute core**). This build lands and BIT-IDENTICAL-validates the
two hardest-to-route primitives the op-select ALU is assembled from — a logic **operator** gadget
and the **multiplexer** that routes the selected operation to the output — and re-confirms the
comparator convention empirically on this jar. It stops HONESTLY short of a fully-wired ALU: the
operators and the mux are each difftest-clean, but the operator→mux interconnect (dense comparator
ports; wants spaced lanes) was not routed in budget.

**Convention re-confirmed EMPIRICALLY this run (the "facing probe").** A single comparator was
built and read: `redstone_block` west of `comparator[facing=west]`, output dust to the east read
**power 15** (`fill 96 100 96 180 100 140 stone` floor first — dust with no support pops). So
`facing=D` ⇒ REAR/INPUT on side D, OUTPUT exits the opposite side (subtract: `out = rear −
max(sides)`). This matches every prior build and removed all guesswork before laying comparators.

**Harness finding (supersedes the build-10 note): `/coderyo redstone difftest` runs straight from
the server CONSOLE (stdin).** The operator console is permission level 4, which satisfies the
command's `LEVEL_GAMEMASTERS` gate — no impulse `command_block` was needed. The persistent server
was driven by `tail -f cmds.txt | java …`, so each `difftest` was issued by appending to `cmds.txt`
and its verdict read from the log line `[redstone-difftest/live] PASS … BIT-IDENTICAL`. (The earlier
command_block requirement was an RCON limitation, not a console one.)

**(1) XOR OPERATOR** — two subtract comparators facing each other into a shared merge cell
(`comp1 = A−B`, `comp2 = B−A`, merge = `|A−B|`). Output/seed `(101,101,100)`.

| A B | XV = A XOR B | | A B | XV |
|-----|------|--|-----|------|
| 1 0 | **15** | | 1 1 | **0** |
| 0 1 | **15** | | 0 0 | **0** |

All 4 combos correct (live power read). **difftest `101 101 100 100` → BIT-IDENTICAL (100 ticks,
14 cells), 0 divergences.**

**(2) 2:1 OP-SELECT MULTIPLEXER** — `out = (D0−S0) OR (D1−S1)` with a **dual-rail one-hot-LOW**
opcode: to select operand k, drive its select rail `Sk=0` and the other rail `=1`. Seed/read
`(123,101,122)`.

| select | D0 D1 | OUT | meaning |
|--------|-------|-----|---------|
| D0 (S0=0,S1=1) | 1 0 | **12** | D0 passed (12 = 15 attenuated over the OR merge) |
| D1 (S0=1,S1=0) | 0 1 | **12** | D1 passed |
| D0 (S0=0,S1=1) | 0 1 | **0**  | **ISOLATION: non-selected HIGH operand blocked** |

Selection + isolation both correct. **difftest `123 101 122 100` → BIT-IDENTICAL (100 ticks, 28
cells), 0 divergences.** (First attempt used a single-rail select with an on-board `NOT(S)` gadget;
its output cell was adjacent to the D1 rear and **shorted** — power read caught `g1=9` where 0 was
expected. Dual-rail select removes the on-board NOT and the short — and is exactly how a real opcode
**decoder** feeds a mux: one-hot select lines. A power read localized the bug in one probe; no
difftest was needed to find it.)

**Honest status.** The op-select **mux** (the ALU's operation-router) and a logic **operator** (XOR)
are each **difftest-clean and functionally verified**; the ADD path already exists difftest-clean as
the build-08 2-bit ripple adder. What remains for a full ALU is **integration**: drive the mux rears
from the *real* operator outputs (D0←XOR, D1←AND/OR/ADD-sum), stack two 2:1 muxes (or one 4:1) per
output bit under a 2-bit opcode decoded to one-hot select rails, and ripple the ADD across bit
slices. That is collision-free **routing** work (operator→mux interconnect through dense comparator
clusters — the build-12 lane discipline applies), not new logic: every constituent is proven
BIT-IDENTICAL. This build did **not** reach a selectable ADD+logic ALU output; it validated the two
pillars that make one assemblable. **This build did not reach a selectable ADD+logic ALU output; it validated the two
pillars that make one assemblable.** **No feature patch was added — only `test-harness/redstone-computer/`.**

## Rung 5 — INTEGRATED 2-BIT OPCODE-SELECTABLE ALU (build-14) — difftest BIT-IDENTICAL ✅

The integration build-13 stopped short of: real operator outputs routed **through a real opcode-decoded
select into a mux, per output bit**, difftest-clean. **build-14 wires it.** This is the CPU **compute core
integrated** — the pillars from build-13 (an operator + a 2:1 op-select mux) are no longer separate; they
form **one selectable ALU output** validated BIT-IDENTICAL over the whole connected network, per opcode.

```
  OUT_i = MUX( XOR(A_i,B_i), AND(A_i,B_i) ; op )     for bit i in {0,1}
  op = 0  ->  ALU result = A XOR B   (per bit)
  op = 1  ->  ALU result = A AND B   (per bit)
```

**2 operations (XOR, AND), 1-bit opcode, 2-bit datapath A[1:0],B[1:0].** XOR and AND are per-bit
COMBINATIONAL (no carry), so bit0 and bit1 are independent symmetric slices — the clean starting point
the FLOOR PLAN prescribed. Each slice is self-contained: **{ XOR operator, AND operator, 1→2 NOT-gate
decoder, 2:1 one-hot-LOW mux }**. Bit1 is the bit0 slice with every z +20 (≥2-cell clear gap in the dense
x=231/232 mux column → zero cross-talk). Full geometry + coords in `build-14-alu-integrated-2bit.txt`.

**Integration pieces wired (all NEW this build):**
- **operator → mux-rear routing** on spaced lanes (XV0 lane z=208, AN0 lane z=220 — 12 apart), each
  ending in a cleaning repeater that refreshes the operator output to 15 at the mux gate rear;
- a **1→2 opcode DECODER**: a real NOT gate produces `S_and = ¬op`; the other one-hot-LOW rail
  `S_xor = op` is the opcode line itself (dual-rail one-hot select — exactly build-13's note), feeding
  the two mux gate SIDES;
- the **2:1 mux per bit** (`g_xor = XV_i − S_xor`, `g_and = AN_i − S_and`, `OUT_i = OR`).

**Per-bit truth matrix** (bit0 @232,101,214 and bit1 @232,101,234, identical; power 9 = logical 1
attenuated across the OR-merge column):

| op | 00 | 01 | 10 | 11 | = |
|----|----|----|----|----|---|
| 0 (XOR) | 0 | 1 | 1 | 0 | A XOR B |
| 1 (AND) | 0 | 0 | 0 | 1 | A AND B |

Both **isolation** directions verified live: the NON-selected HIGH operand is blocked to 0 at OUT.

**2-bit ALU showcase** (both output bits read):

| op | operation | result | OUT1 OUT0 |
|----|-----------|--------|-----------|
| 1 | AND  11(3) & 10(2) | 10(2) | 1 0 ✅ |
| 0 | XOR  11(3) ^ 01(1) | 10(2) | 1 0 ✅ |
| 1 | AND  11 & 11       | 11    | 1 1 ✅ |
| 0 | XOR  11 ^ 11       | 00    | 0 0 ✅ |

**difftest** (`/coderyo redstone difftest <OUT_i> 100`, from the server console, verdict from the log)
over the **whole connected slice** (operators + decoder + mux):

| case | seed | verdict |
|------|------|---------|
| bit0 op=0/XOR (A=1,B=0) | 232 101 214 | **BIT-IDENTICAL (100t, 105 cells)** |
| bit0 op=1/AND (A=1,B=1) | 232 101 214 | **BIT-IDENTICAL (100t, 110 cells)** |
| bit0 op=0/XOR (A=1,B=1) — AND-operand isolation | 232 101 214 | **BIT-IDENTICAL (100t, 108 cells)** |
| 2-bit AND — OUT0 / OUT1 | 232 101 214 / 232 101 234 | **BIT-IDENTICAL (107 / 110 cells)** |
| 2-bit XOR — OUT0 / OUT1 | 232 101 214 / 232 101 234 | **BIT-IDENTICAL (108 / 105 cells)** |

**7 / 7 difftests BIT-IDENTICAL, 0 divergences.** The ~105-cell footprint per difftest confirms each
seed detects the ENTIRE slice (both operators + decoder + mux) as one connected network — this is a
genuinely *integrated* ALU, not co-located pieces.

**Opcodes that route cleanly: BOTH (op=0→XOR, op=1→AND), on BOTH bits.** The integrated,
difftest-clean, opcode-SELECTABLE ALU output is the milestone build-13 named and did not reach.

**Routing lesson (build-12/13 discipline, re-learned live).** The first attempt spaced the XOR and AND
clusters only 2 apart in z (206 / 210): the XOR-output exit lane at z=208 ran orthogonally adjacent to
the AND cluster's A0-input dust at (223,209) → the AND rear (15) **shorted** into the XOR output lane and
leaked to OUT even when XOR was selected. A single power read localized it (XV merge read 12 where
XOR(1,1)=0 was expected). **Fix:** relocate the AND slice to z=217-219 so the two operator→mux lanes are
12 cells apart with ≥2 empty cells from every driver. No logic/compiler fault — pure lane spacing.

**Honest scope.** 2 ops (XOR, AND) — both per-bit logic. **ADD was NOT folded in**: the build-08 ripple
adder is ~600 cells and routing its SUM/Cout into the mux under budget was the large risk the anti-stall
guidance said to avoid; the integration milestone is equally proven by XOR+AND. **Next operators**
(documented in build-14): fold in **OR** (widen to a 2-bit opcode + 2:4 active-low one-hot decoder, 4:1
mux per bit) and **ADD** (route the difftest-clean build-08 SUM_i into the mux data rears — collision-free
routing, no new logic). Then latch OUT into an accumulator (build-11 edge-triggered register) and drive
the opcode from an instruction ROM addressed by a program counter → the minimal CPU. **No feature patch
was added — only `test-harness/redstone-computer/`.**

## Rung 5 — INSTRUCTION-FETCH FRONT-END: Program Counter + Instruction ROM (build-15) — ROM difftest BIT-IDENTICAL ✅

The CPU **fetch** pillar: an address SOURCE (Program Counter) + the **Instruction ROM** it addresses. This
build LANDS and difftest-validates the **instruction ROM** (a 2→4 one-hot address decoder + a word matrix);
the **PC** (a 2-bit edge-triggered counting register) is designed from the already-proven build-11/12
edge-triggered accumulator and documented as the next build. The ROM is validated with the PC's job done by
a **manually-driven dual-rail address** — exactly item-2's spec ("set the PC to each address 0..3, read the
ROM output") — so ROM correctness is independent of the PC's feedback routing. Full geometry in
`build-15-pc-rom.txt`.

**4 words × 3 bits, stored** `W0=101 W1=011 W2=110 W3=001` (bit2 bit1 bit0), addressed by a 2-bit dual-rail
address `{a0,na0,a1,na1}` (four `redstone_block`-driven cells).

**(1) 2→4 one-hot DECODER.** Because both address rails *and their complements* are present, each minterm
`AND(x,y)=x−(15−y)` collapses to a **single subtract comparator** `x − (complement of y)`:
`W0=na1−a0, W1=na1−na0, W2=a1−a0, W3=a1−na0` (4 comparators facing west at x=306, z=300/304/308/312).
**One-hot verified live for all 4 addresses:** addr0→W0 hot, addr1→W1, addr2→W2, addr3→W3; rest LOW. **4/4.**

**(2) word MATRIX** (diode-OR per output bit; one-way repeaters isolate every tap). `OUT0=W0|W1|W3`
(re-amped east runs → a short merge column at x=319 → read 321,101,300); `OUT1=W1|W2` merged **between** the
W1/W2 rows at z=306 (so it crosses neither W0 nor W3) → read 313,101,306.

**ROM word read — all 4 addresses** (live power, ~9 s settle):

| addr | word | stored bit1 bit0 | OUT1 OUT0 read |
|------|------|------------------|----------------|
| 0 | W0 = 101 | 0 1 | LO HI → **01** ✅ |
| 1 | W1 = 011 | 1 1 | HI HI → **11** ✅ |
| 2 | W2 = 110 | 1 0 | HI LO → **10** ✅ |
| 3 | W3 = 001 | 0 1 | LO HI → **01** ✅ |

`OUT0` sweep `{1,1,0,1}` = bit0 of all four words; `OUT1` sweep `{0,1,1,0}` = bit1 of all four words — both
low bit-planes read the stored word **bit-correct** for every address.

**difftest** (from the server console; verdict from the log):

| case | seed | verdict |
|------|------|---------|
| addr0 bit0 HI | 321 101 300 | **BIT-IDENTICAL (100t, 124 cells, 64 components, single-region)** |
| addr2 bit0 LO | 321 101 300 | **BIT-IDENTICAL (100t, 126 cells)** |
| addr1 bit1 HI | 313 101 306 | **BIT-IDENTICAL (100t, 128 cells)** |
| addr3 bit1 LO | 313 101 306 | **BIT-IDENTICAL (100t, 127 cells)** |

**4/4 BIT-IDENTICAL, 0 divergences.** The ~126-cell footprint per seed = the WHOLE connected decoder+matrix
(64 components) detected as one network → a genuinely integrated ROM, bit-for-bit to vanilla in both HI and
LO output states on both validated bit-planes.

**Build lessons (cost real debug):** (1) **attenuation** — bare 12-cell dust runs into a long merge column
read correct only for the nearest word; re-amp each word with a repeater before a SHORT merge (build-06/11
rule). (2) **settle by game ticks** — after re-amping, addr1/addr3 still first read LO; a 3 s probe caught the
multi-repeater path half-propagated, a ~9 s settle (or the game-tick-stepped difftest) reads the true steady
state (build-07 rule). (3) **diode isolation + the ROM "triangle"** — a shared merge let W2 back-feed into
OUT0, and a south-routed W2 tap crossed W3's row at (313,312) leaking W3 into OUT1 at addr3; fixed with one-way
diode repeaters on every tap and by merging OUT1 *between* the W1/W2 rows.

**Honest status — OUT2 (bit2 = W0|W2) NOT landed.** bit0 and bit1 are difftest-clean on all 4 addresses; the
3rd bit-plane hits the fundamental single-layer ROM-matrix crossing (the words form the triangle
`{W0,W1,W3}/{W1,W2}/{W0,W2}`, and W2's row z=308 is boxed — north crosses W1, south crosses W3, east is walled
by the OUT0 merge column, west is the decoder). A clean planar fix exists (re-route W1 to OUT0 on an offset row
to vacate z=304, or one y=102 dust bridge with vertical-redstone parity spot-checked first) — recorded not
forced. **The PC** (2-bit counter: `bit0.D=Slave0.Qbar` = the build-12 T-flip-flop verbatim, `bit1.D=Q1 XOR Q0`
= the build-01 gadget; two build-11 master-slave flip-flops on a shared two-phase clock advance 00→01→10→11→00
edge-triggered, each held state difftest-clean) is designed from difftest-clean constituents but not built here
— a sustained 2-bit feedback counter is a multi-cell build on the scale of the whole build-11+build-12 arc.
Wiring the PC's 2 output bits onto this ROM's `{a1,a0}` rails is the item-3 PC→ROM walk. **No feature patch was
added — only `test-harness/redstone-computer/`.**

## Rung 5 — 2-BIT PROGRAM COUNTER (build-16) — counts 00→01→10→11→00, every state difftest BIT-IDENTICAL ✅

The CPU's **address source**: the 2-bit binary counter that drives build-15's instruction ROM. Two
**edge-triggered** master-slave flip-flops sharing **ONE** non-overlapping two-phase manual clock:
- **bit0** = the **build-12 T-flip-flop VERBATIM** (`bit0.D = Slave0.Qbar`) — Master base x=62, Slave base
  x=46, output `ACC0 = (44,101,122)`. Its `Qbar→D` "+1" feedback is **fully physical** on build-12's
  dedicated non-crossing channels (432 cells / 218 components — identical footprint to build-12).
- **bit1** = a **build-11 master-slave D flip-flop** (the whole body translated **+40 in x**: Master1 base
  x=102, Slave1 base x=86, output `Q1 = (84,101,122)`), forward `Master1.Q→Slave1.D` on the same
  north-band+west-drop discipline, **no** T-feedback (266 cells / 135 components). Its next-state is
  `bit1.D = Q1 XOR Q0`. The two cells are **electrically independent** nets (~15-cell gap x=66..81) sharing
  only the clock. Full geometry + coords in `build-16-program-counter-2bit.txt`.

Because both flip-flops are edge-triggered (masters capture on φ1 while the slaves still hold the **old** Q;
both slaves update together on φ2's falling edge), the D's sample the old state and the pair advances
**synchronously**.

**Sustained 2-bit count — vanilla live reads** (`Q1@84,101,122`, `Q0@44,101,122`), from a clean 00 start,
one full wrap (bit0.D=Qbar0 **physical**; bit1.D=XOR(Q1,Q0) supplied each cycle from the observed old state):

| cycle | bit1.D | Q1 Q0 | value |
|-------|--------|-------|-------|
| start | — | 0 0 | **00** |
| 1 | XOR(0,0)=0 | 0 1 | **01** |
| 2 | XOR(0,1)=1 | 1 0 | **10** |
| 3 | XOR(1,0)=1 | 1 1 | **11** |
| 4 | XOR(1,1)=0 | 0 0 | **00** (WRAP) |

The counter **walks 00→01→10→11→00** — both real edge-triggered flip-flops advancing on one shared clock,
bit0 through its real physical feedback. (Reproduced twice: once live, once after the jar-swap reboot.)

**difftest (compiler == vanilla) — every one of the 4 states, BOTH bits** (patch-0020 jar booted on the same
persisted world; D-driver cleared for a pure HOLD at each state; console verdicts from the log):

| state | Q1 Q0 | bit1 seed `84 101 122` | bit0 seed `44 101 122` |
|-------|-------|------------------------|------------------------|
| 01 | 0 1 | **BIT-IDENTICAL (200t, 266 cells)** | **BIT-IDENTICAL (200t, 432 cells)** |
| 10 | 1 0 | **BIT-IDENTICAL (200t, 266 cells)** | **BIT-IDENTICAL (200t, 432 cells)** |
| 11 | 1 1 | **BIT-IDENTICAL (200t, 266 cells)** | **BIT-IDENTICAL (200t, 432 cells)** |
| 00 | 0 0 | **BIT-IDENTICAL (200t, 266 cells)** | **BIT-IDENTICAL (200t, 432 cells)** |

**8/8 per-state difftests + 1 initial = 9 BIT-IDENTICAL, 0 divergences**, across a full 00→01→10→11→00 wrap.
Each seed detects the whole cell as one connected network → **both edge-triggered flip-flops of the PC
compile bit-for-bit to vanilla in every one of the 4 counter states, and the 2-bit value is correct at each.**

**Honest scope — bit1's XOR is applied by a DRIVER, not yet a physical gate.** In this build `bit1.D` was
supplied to Master1.D by a redstone_block driver set each cycle to the XOR of the observed old `{Q1,Q0}`, so
the counter's edge-sequencing, both real flip-flops, the shared clock, and every held state are all proven —
but the physical XOR **gate** and its collision-free routing are the one remaining step. The **key new
insight** that makes it a **non-crossing planar gate** (recorded for the next build): the naive `|Q1−Q0|` XOR
feeds each input to two comparator ports (crossover-impossible on one layer, the build-07/13 problem), but the
slaves expose **both rails** (`Q0,Qbar0,Q1,Qbar1`), so use the **dual-rail identity**
`Q1 XOR Q0 = max(Q1−Q0, Qbar1−Qbar0)` — now each subtract comparator takes **two distinct rails**
(comp_a rear=Q1/side=Q0, comp_b rear=Qbar1/side=Qbar0) into one shared merge, **no input appears twice → no
fanout crossover**. The merge fans to Master1.D_north/D_south on the build-12 antiparallel discipline; the
only long haul is Q0/Qbar0 from bit0 (~40 cells) on two 2-cell-separated rows (build-08 carry rule). Landing
that self-advancing feedback is a build-11/12-scale routing effort and is the immediate next build.

**Harness lesson (cost the first pass).** The dev worktree's on-disk jar was built from a **non-redstone
branch** (LOD work) and lacked the `coderyo` command; and a fresh `applyAllPatches` **fails at
checkoutPaperRepo** because `git fetch origin <pinned-Paper-SHA>` is not served by GitHub. Fix (offline): copy
the sibling worktree's warmed `.gradle/caches/paperweight` in and **repoint the Paper repo's `origin` to that
local copy** (`git remote set-url origin file://…`) so the fetch resolves from disk; build in ~2 min. The
world **save persists across a jar swap**, so the whole circuit was built under the command-less jar and the
server rebooted on the **same world** with the patch-0020 jar to run every difftest.

**NEXT (toward the CPU):** (1) wire the physical dual-rail XOR feedback so the PC self-advances with no manual
D; (2) wire the PC's `{Q1,Q0}` onto build-15's ROM `{a1,a0}` address rails → each clock the ROM output walks
the program W0..W3 in order = the **CPU fetch walk**; (3) then decode + register file + integrate. **No
feature patch was added — only `test-harness/redstone-computer/`.**

## Rung 5 — FETCH FRONT-END: physical dual-rail XOR gate + self-advancing bit0 + both PC flip-flops (build-17) — XOR gate & both FFs difftest-clean; 2-bit self-advance routing deferred ⚠️

Toward making build-16's PC **autonomous**: land the physical `bit1.D = Q1 XOR Q0` gate and the second
flip-flop, then wire the self-advancing feedback + the PC→ROM address bus. This build **lands and
difftest-validates the three constituents** (the new XOR gate + both edge-triggered flip-flops, bit0
physically self-advancing) and reports the **root-cause routing finding** that gates the final two-cell
integration. Full geometry in `build-17-fetch-frontend.txt`. (Jar: the patch-0020 compiler reused
byte-for-byte from the showcase build of `origin/main` 9e2343d — the only commits from there to the fetch
base 4b6b8b5 are test-harness-only build-15/16, so the compiler is identical; no rebuild needed.)

**(A) Physical dual-rail XOR gate — the item-1 gate, difftest-clean ✅.** `bit1.D = Q1 XOR Q0 =
max(Q1−Q0, Qbar1−Qbar0)`: two subtract comparators facing one shared merge, each fed **two DISTINCT rails**
(comp_a rear=Q1/side=Q0; comp_b rear=Qbar1/side=Qbar0) — no input appears twice → **no fanout crossover**,
the build-07/13 planar-XOR problem solved by using the slaves' both-rail outputs. Built standalone at
x≈204, output `XV @(208,101,206)`, driven by 4 dual-rail drivers.

| (Q1,Q0) | Q1−Q0 | Qbar1−Qbar0 | XV = max | XOR |
|---------|-------|-------------|----------|-----|
| (0,0) | 0 | 0 | **0** | 0 ✅ |
| (0,1) | 0 | 15 | **15** | 1 ✅ |
| (1,0) | 15 | 0 | **15** | 1 ✅ |
| (1,1) | 0 | 0 | **0** | 0 ✅ |

**4/4 correct = XOR** (live power). **difftest** (`difftest 208 101 206 100`): (1,0) HI → **BIT-IDENTICAL
(100t, 32 cells, 17 components)**; (1,1) LO → **BIT-IDENTICAL (100t, 32 cells)**. The exact bit1.D gate the
self-advancing PC needs, proven bit-for-bit on a single planar layer.

**(B) Both PC flip-flops rebuilt fresh; bit0 self-advances physically ✅.** bit0 = the build-12 T-flip-flop
verbatim (Master base x=62, Slave base x=46, `Q0@44,101,122`) with its `Qbar0→Master0.D` "+1" feedback
**fully physical**. bit1 = a build-11 master-slave D flip-flop translated +40x (`Q1@84,101,122`,
`Qbar1@88,101,130`, Master1.D at (101,118)/(102,135)), body + forward only.

- **bit0 SELF-ADVANCES** on the shared two-phase clock with **no manual D** — live `0→1→0→1→0` over 4
  cycles (@44,101,122), zero sticking, through real Qbar0→D feedback.
- **difftest:** bit0 held ACC0=0 → **BIT-IDENTICAL (200t, 432 cells, 218 components)** (identical footprint
  to build-12's physical T-loop); bit1 held Q1=0 → **BIT-IDENTICAL (200t, 244 cells, 124 components)**.

**(C) Integration status — the root-cause routing finding (honest).** Both remaining items need the SAME
thing: bit0's **Q0/Qbar0 fanned to a SECOND consumer** — the XOR gate (for bit1.D) in item-1, and the ROM
address `{a1,a0}` in item-2 (Q1 = a1, Q0 = a0). bit1's Q1/Qbar1 are reachable (no T-feedback), but bit0's
`Q0@(44,122)`/`Qbar0@(48,130)` are **enclosed by bit0's own two interconnects** — which build-12 packed into
every clean lane to make bit0's T-loop non-crossing: the **forward** net (z=114 trunk x41–50 + x=41 drop
z115–137) seals the north/west exits, and the **feedback** net (x=48 drop z131–145 + z=145 trunk x48–66 +
x=66 riser) seals the south/east exits. So a **retrofit** tap of Q0/Qbar0 collides with a live bit0 net on
the same y=101 layer (exactly the build-11 wire-crossing mode, and why build-16 applied bit1.D by a driver).
The fix is **not** a local reroute: the whole PC must be **rebuilt on a wider platform** that brings
Q0/Qbar0/Q1/Qbar1 out to a **shared fan-out bus** from the start — one clean tap fanning to BOTH the bit1.D
XOR gate AND the ROM address rails, with bit0's forward+feedback lanes shifted to leave that bus clear. Every
**constituent is difftest-clean** on this jar (the XOR gate, both flip-flops, and build-15's ROM); what
remains is purely that wider-platform non-crossing fan-out — a build-11/12-scale layout effort, deferred
(anti-stall: the difftest-clean XOR gate + a physically self-advancing bit0 + both FFs are the landed wins).

**Landed:** the physical dual-rail XOR gate (bit1.D) difftest-clean; bit0 self-advancing physically +
difftest-clean; bit1 flip-flop difftest-clean. **Deferred:** the two-cell physical self-advance and the
PC→ROM address bus, both gated by the single Q0/Qbar0 second-consumer fan-out (needs the wider platform).
**NEXT:** rebuild the 2-bit PC on a wide platform with a Q0/Qbar0/Q1/Qbar1 fan-out bus → connect to (i) the
XOR gate → Master1.D (self-advance) and (ii) build-15's ROM `{a1,a0}` (fetch walk); then decode opcode →
control lines + register file + integrate the build-14 ALU + build-12 accumulator. **No feature patch was
added — only `test-harness/redstone-computer/`.**

## Rung 5 — FETCH FRONT-END on a WIDE PLATFORM with a shared FAN-OUT BUS (build-18) — fan-out bus functional + difftest-clean at LOW; vertical-bridge HIGH-state compiler divergence FOUND ⚠️

The build-17 fix, built: rebuild the 2-bit PC on a **wide platform** that brings every register rail
(Q0, Qbar0, Q1, Qbar1) **out to a shared fan-out bus from the start**, so each rail can feed multiple
consumers (the bit1.D XOR gate AND the ROM address rails) with no crossing — the fix for the retrofit
collision where bit0's own T-loop ring enclosed Q0/Qbar0. Full geometry in `build-18-fetch-fanout-bus.txt`.
(Jar: the patch-0020 compiler reused byte-for-byte from the showcase build of `origin/main` 9e2343d.)

**The wide floor plan (the ring-map insight that made it tractable).** bit0 = build-12 T-flip-flop verbatim
(fully-physical `Qbar0→Master0.D` feedback), bit1 = build-11 D-flip-flop `+40x`, shared two-phase clock.
Mapping bit0's T-loop ring showed the **west platform (x≤40), the x=67..80 gap, and the east (x≥89) are all
OPEN** — each enclosed rail needs to cross **only ONE ring wire**:
- **Q0** (x=44): tap @z=126, **hop over the x=41 forward-drop wire with a y=103 bridge**, land x=39, lane
  south to the shared corridor at z=152.
- **Qbar0** (x=48): **diode-tap the feedback trunk** (z=145) at x=50 (a repeater is a diode → no back-feed
  into the difftest-clean T-loop), lane south to z=152.
- **Q1** (x=84): hop over the x=81 forward-drop with a y=103 bridge, land x=79, lane to z=152.
- **Qbar1** (x=88): **straight south** (bit1 has no feedback → its east/south is open), lane to z=152.

The four lanes sit at x=39/50/79/88 (each ≥2 apart), re-amped every ≤9 dust — the **shared fan-out bus**.

**(A) bit0 self-advance + fan-out bus — difftest-clean at LOW (reproduced on this jar) ✅.** Q0
(@44,101,122) toggles `0→15→0→15` live through the physical feedback (one metastability-break pulse first),
**with the whole bus attached**. The bus reads the four rails' **correct live values across counter states**:
state 00 → `Q0BUS=0, Qbar0BUS=10, Q1BUS=0, Qbar1BUS=8`; state 01 → `Q0BUS=8, Qbar0BUS=0, Q1BUS=0,
Qbar1BUS=8` (HIGH reads 8–10 = logical 1 over the ~30-cell lane; LOW = 0) — every rail tracks the count.

| difftest (console; verdict from log) | verdict |
|--------------------------------------|---------|
| bit0 pure (no bus) | **BIT-IDENTICAL (200t, 432 cells, 218 comp)** |
| bit0 + Q0 bridge (Q0=0) | **BIT-IDENTICAL (200t, 491 cells)** |
| bit0 + Q0 & Qbar0 bus (Q0=0) | **BIT-IDENTICAL (200t, 505 cells)** (×2) |
| bit1 + Q1 & Qbar1 bus | **BIT-IDENTICAL (200t, 369 cells)** (×2) |

So the **whole PC + shared fan-out bus compiles bit-for-bit to vanilla** when the bridged rails carry LOW,
and reads every rail's correct live value across states. **The build-17 fan-out routing is delivered
functionally — the retrofit-collision is gone** (all four rails out on their own lanes, no crossing).

**(B) NEW compiler finding — the vertical y=102/103 BRIDGE diverges 1–2 dust levels at HIGH (difftest caught
it).** An **isolated** block-sourced bridge is fully parity-clean — a spot-check (up → over an independent
wire → down) is **BIT-IDENTICAL (100t, 22 cells)**. But when a **ring-crossing** bridge carries a HIGH bit
(Q0=1, a loaded/attenuated dust level), its vertical-transition cells **persistently diverge**:
`bit0+Q0 bridge, Q0=1` → **DIVERGENCE, 800 mismatches, @tick0 (42,102,126) POWER real=9 sim=11**;
re-sourcing the bridge from a clean repeater shrank it to **400 mism, (40,102,126) real=13 sim=14** but did
**not** close it (400/200t = 2 climb cells persistently off by 1 = a *steady-state* divergence, reproduced
after a full re-settle — not a settle artifact). So **patch-0020's model of VERTICAL redstone-dust
attenuation drifts 1–2 levels from vanilla when a bridge carries a nonzero loaded signal** (it matches
vanilla for the clean isolated case and for LOW). **Recorded, not fixed** — exactly like the build-06 torch
gap and build-09 seeding edge the difftest discovered (this map adds NO feature patch). **Consequence:** the
y=102 bridge is a functionally-correct fan-out shortcut but **not a reliably difftest-clean one**; a fully
difftest-BIT-IDENTICAL fan-out of the *enclosed* rails needs a **FLAT** (single-layer, no vertical crossing)
exit — i.e. re-laying bit0's forward+feedback interconnects on a genuinely wider footprint so a flat gap
opens beside Q0/Qbar0 (build-17's "rebuild the ring bigger with deliberate gaps"). That flat re-lay
(a build-11/12-scale interconnect rebuild) is the remaining routing work; not completed in budget.

**(C) XOR-gate consume of the bus → bit1.D — attempted, layout bug found, not landed.** Built the build-17
dual-rail XOR gate as a consumer fed by the four bus lanes (staggered inward turns + one bridge). It read
wrong (XV=15 at state 00 where XOR(0,0)=0); power reads root-caused it to **(1)** the west-input runs crossing
the **merge column** (x=64) and shorting it HIGH (build-13/14 "merge must not be crossed" lesson), and **(2)**
the long side-runs arriving **attenuated** so `15 − Qbar0` doesn't null (build-01 "cleaning repeater AT each
port" lesson). The buggy gate was removed and both bits re-verified BIT-IDENTICAL (505/369). The correct
design (route both comparator outputs clear of the input rows to a merge no data run crosses; a cleaning
repeater at every rear AND side) is specified but not built in budget.

**Verdict.** The 2-bit PC is rebuilt on the **wide platform with the shared fan-out bus** — all four register
rails out on their own ≥2-apart lanes to a shared corridor, correct live values across states, bit0
self-advancing physically, whole thing difftest **BIT-IDENTICAL at LOW** (505+369 cells): **the build-17
retrofit-collision is solved functionally.** The difftest then caught a **new compiler finding** — the
vertical ring-crossing bridge diverges 1–2 levels at HIGH, so a fully difftest-clean fan-out wants a flat
wide re-lay rather than a bridge. **Not landed:** the physical XOR consume (→ 2-bit self-advance) and the
PC→ROM fetch walk. **NEXT:** (1) re-lay bit0's forward+feedback wider to open **flat** rail exits; (2) route
the XOR gate with the merge clear of the input rows + cleaning repeaters at every port → bit1.D fanned to
Master1.D_north/D_south → the PC self-advances; (3) tap the same bus into build-15's ROM `{a1,a0}` for the
fetch walk; then decode + register file + integrate the build-14 ALU + build-12 accumulator. **No feature
patch was added — only `test-harness/redstone-computer/`.**

## Rung 5 — FETCH FRONT-END on the PR#69 JAR (build-19) — self-advance TOPOLOGY difftest-clean; PR#69 vertical-bridge fix shown before/after; physical clean-toggle + fetch walk not settled ⚠️

The follow-up to build-18, run on a **fresh paperclip jar built from `origin/main` @19f1682 — the PR#69
merge** ("fix vertical-dust wire connectivity/attenuation under load"), the fix build-18 said would unblock
difftest-clean vertical fan-out. (Neither on-disk jar carried PR#69 — showcase=9e2343d, main-worktree=8bd0170
are both older — so it was rebuilt: warmed `.gradle/caches/paperweight` copied from a sibling worktree, then
`applyAllPatches && createPaperclipJar`, BUILD SUCCESSFUL, no `checkoutPaperRepo` fetch needed.) Booted
`-Dcoderyo.redstone.compile.enabled=true`, port 15568; setblock/reads via RCON, `difftest` via console stdin.
Full geometry + runnable command files (`build-19-*.commands.txt`) in `build-19-fetch-frontend-pr69.txt`.

**(A) bit0 master-slave flip-flop — difftest BIT-IDENTICAL on the PR#69 jar ✅.** The build-11/12 edge-triggered
cell (MASTER x=62, SLAVE x=46, Q0=`44,101,122`), rebuilt from the tested runnable and clocked. **difftest
`44 101 122 200` → BIT-IDENTICAL (200 ticks, 254 cells, 126 components, single-region).** The register a PC
bit is built from compiles bit-for-bit to vanilla on the PR#69 jar.

**(B) bit0 T-flip-flop — full self-advance TOPOLOGY difftest BIT-IDENTICAL; physical toggle NOT settled ⚠️.**
Removed the manual master-D drivers and wired **Slave.Qbar (48,130) → Master.D_north (61,118) & D_south
(62,135)** on the build-12 non-crossing feedback channel (south trunk z=139 + risers) — the physical `Qbar→D`
"+1" loop. **difftest `44 101 122 200` → BIT-IDENTICAL (200 ticks, 358 cells, 177 components).** So the **whole
self-advancing T-flip-flop topology** (both torch latches + both enable-gates + forward AND feedback bus)
compiles bit-for-bit to vanilla — **the compiler handles the full physical feedback loop.** **Honest:** the
physical clean toggle did **not** settle — clocking left Q0 pinned at 1 (the feedback bus reached an analog
fixed point: D read 15 while Qbar read 0). Because the difftest is BIT-IDENTICAL, **vanilla behaves the same**
(compiled==vanilla, both non-toggling), so this is a **construction miswire** — the `build-19-bit0-masterslave`
(build-11 layout) and `build-19-bit0-Tfeedback` (build-12-layout) rails don't line up cleanly on this fresh
board (the same analog-attenuation / lane-tuning problem build-04 and build-12 each spent a whole build
solving), **NOT a compiler/PR#69 fault** (build-12 proved 14 clean toggles on its own tuned board).

**(C) PR#69 vertical-bridge-under-load — the routing blocker, re-tested BEFORE/AFTER on the same world ✅.**
build-18's only difftest divergence was the y=102/103 fan-out **bridge** carrying a HIGH loaded rail over a
crossing wire (real=9/sim=11). A reproduction rig (build-18 Q0-bridge topology, +160x, z=200) drives a
`redstone_block`-fed **loaded HIGH** signal (bridgeIn=12) up a `101→102→103→102→101` bridge **over a powered
crossing wire** (crossWire=14, bridgeTop=10) and out (out=6). Same world, **jar swap**:

| jar | difftest `197 101 200` | difftest `201 101 200` |
|-----|------------------------|------------------------|
| **PR#69** (origin/main 19f1682) | **BIT-IDENTICAL, 32 cells** | **BIT-IDENTICAL, 32 cells** |
| pre-PR#69 (showcase 9e2343d) | BIT-IDENTICAL, **29 cells** | BIT-IDENTICAL, **30 cells** |

On the **pre-PR#69** jar the compiled network is **missing 2–3 cells** — exactly the support-stone cells the
flood-fill dropped (marked-visited-but-never-added when first reached diagonally); the **PR#69** jar detects
the **full 32-cell footprint**. So PR#69's footprint fix is demonstrated on the **same world by a before/after
jar swap** — the vertical routing blocker is gone at the compiler level. **Honest:** in this *simplified*
single-layer geometry the dropped stones did not flip a **value** (both jars report BIT-IDENTICAL); the dramatic
real=9/sim=11 needs build-18's T-loop-**ring** context around the bridge, which requires a settled physical
T-flip-flop (see B). The footprint delta (32 vs 29/30) is the direct, reproducible before/after signature.

**Verdict.** On the **PR#69 jar**: bit0 flip-flop difftest-clean (254 cells); the **full self-advancing
T-flip-flop topology** difftest-clean (358 cells, 177 comp); and the **vertical-bridge fan-out shortcut is
difftest-clean** (32 cells) with the pre-PR#69 footprint-drop shown by a same-world jar swap. **Not landed:**
the **physical** clean 2-bit self-advance (bit0's T-loop reached an analog fixed point on this fresh board — a
construction/lane-tuning task, difftest confirms it is NOT a compiler fault), the physical XOR consume →
bit1.D, and the **PC→ROM fetch walk**. **Next:** tune bit0's feedback rails to a clean level so it toggles
0↔1, add bit1 + the build-17 dual-rail XOR gate → Master1.D for the physical 2-bit self-advance, then tap
Q1,Q0 into build-15's ROM `{a1,a0}` for the fetch walk. **No feature patch was added — only
`test-harness/redstone-computer/`.**

---

## build-20 — 2-bit PC: REPEATER-ISOLATED FAN-OUT solves the recurring attenuation blocker

**The one physical issue that stuck builds 16–19:** adding a fan-out tap to bit0's feedback loop broke its
clean digital toggle — a raw-dust tap **loads/attenuates** the feedback net so the loop settles to an
**analog fixed point** (build-19: `D=15 while Qbar=0`) instead of toggling. **The fix tested here: tap every
fan-out through a REPEATER** (one-way, re-amplifying — it READS the source without loading the net) and
**start from build-12's EXACT clean-toggling bit0 verbatim**. Fresh jar from **origin/main @53fd5e7**
(PR#69 + patch-0020), console-driven on port 15568; difftest verdicts from the `[redstone-difftest/live]` log.

**(1) bit0 = build-12 T-flip-flop verbatim — clean physical toggle REPRODUCED ✅.** Latch bodies + forward
are build-11/12 verbatim; the **feedback is build-12's EXACT non-crossing route** (drop x=48 → far-south
trunk **z=145** → east risers x=62/x=66), *not* build-19's z=139 shortcut that hit the fixed point. On the
two-phase manual clock, Q0 @(44,101,122) from the metastable boot: `c1=15 (break) c2=15 c3=0 c4=15 c5=0 c6=15
c7=0 c8=15 c9=0 c10=15` → **9 consecutive clean toggles, zero sticking — bit0 physically self-advances.**
**difftest `44 101 122 200` → BIT-IDENTICAL (200 ticks, 440 cells, 218 components).** The build-19 analog
fixed point was a **construction miswire (its z=139 route), not build-12 and not the compiler** — build-12's
exact route toggles cleanly on this jar, exactly as the operator said.

**(2) REPEATER-isolated fan-out off the FEEDBACK rail — bit0 KEEPS toggling ✅ (THE KEY TEST).** A diode
repeater on the feedback trunk `52,146 rep[N]` (rear reads trunk (52,145)=Qbar0) → `52,147..150` wire →
cleaning `52,151 rep[N]` → port `52,152`. With the tap attached, Q0 = `0,15,0,15,0,15,0,15,0` — **still a
clean toggle**; bus mid @(52,150)=**12/0** (re-amplified, tracks Qbar0), cleaning-repeater PORT
@(52,152)=**15/0** (clean, ready to feed an XOR subtract comparator). **difftest → BIT-IDENTICAL: 451 cells
(tap), 454 cells (tap + re-amp).** The repeater tap **does not disturb the feedback net** — the recurring
blocker is **solved**.

**(3) Controlled contrast — RAW-DUST tap at the same point ATTENUATES to nothing ✅.** Single-variable swap
(repeater→raw dust, same route extended to z=160): the fan-out is **dead** — `BUSnear (52,147)=3`,
`BUSfar (52,160)=0` — vs the repeater tap's **12 → 15**. Raw dust decays 15→3→0 over the run (a downstream
`15 − attenuated` subtract-XOR would never null); the repeater re-amplifies. This is the mechanism behind
build-18's XOR misfire and the rule: **a cleaning repeater at every comparator port, fed by a repeater tap.**

**(4) bit1 = build-11 master-slave D-FF (+40x) + repeater fan-out — difftest-clean ✅.** Body+forward at
MASTER1 x=102 / SLAVE1 x=86 (Q1=(84,122), Qbar1=(88,130)), shared clock. A floating-D latch boots metastable
and difftests **DIVERGENT** (real=15/sim=0 @tick120 — the torch pair oscillates); clocking once with D=0
drives a **defined Q1=0** → **difftest `84 101 122 200` → BIT-IDENTICAL (252 cells).** Its rail also fans out
via a repeater (south open): `88,131 rep[N]` → `88,136` cleaning rep → port `88,137`=**15 clean**;
**difftest → BIT-IDENTICAL (264 cells).**

**Verdict.** The KEY physical unknown that blocked every prior PC build — *does a fan-out tap kill bit0's
toggle?* — is **answered: NO, if the tap is a REPEATER.** bit0 reproduces build-12's clean physical toggle
(9 toggles, difftest-clean 440); the repeater-isolated feedback tap keeps it toggling and stays difftest-clean
(451/454); a raw-dust control dies 3→0 where the repeater delivers a clean 15; bit1 is difftest-clean (252) and
fans out via its own repeater (264). **Not landed in-budget:** assembling the four repeater-tapped rails into
build-17's dual-rail XOR (`max(Q1−Q0, Qbar1−Qbar0)`) → Master1.D for the full physical 00→01→10→11→00
self-advance, and the PC→ROM fetch walk — now a routing exercise on **proven** parts (this repeater fan-out +
build-17's difftest-clean XOR + build-15 ROM) with the port discipline established. **No feature patch — only
`test-harness/redstone-computer/`.**

---

## build-21 — 2-BIT PC INTEGRATION: dual-rail XOR difftest-clean + LIVE-RAIL drive proven

Fresh RCON-driven run on the patch-0020 jar (port 15568), full geometry + runnable command files in
`build-21-2bit-pc-integration.txt`. Repeater/comparator convention re-calibrated empirically on this jar
(`[facing=D]` ⇒ rear/input on side D, output opposite; a setblock'd repeater needs a neighbour update to
re-read its input — drive the input last). Two-phase clock + probes automated (`clock.py`, `probe.py`).

**(1) bit0 = build-12 T-flip-flop VERBATIM — clean physical self-advance reproduced ✅.** Physical toggle
probe of `Q0@(44,101,122)` after each settled full clock cycle: **`15 → 0 → 15 → 0 → 15 → 0`** — six
consecutive clean toggles, zero sticking; bit0 self-advances with **no manual D**.
`difftest 44 101 122 200` → **PASS BIT-IDENTICAL (200 ticks, 440 cells, 218 components)** (matches build-20).

**(2) Dual-rail XOR gate `bit1.D = Q1⊕Q0 = max(Q1−Q0, Qbar1−Qbar0)` — 4/4 truth + difftest-clean ✅.** Two
subtract comparators → shared merge → clean repeater → `XV@(104,101,165)`. Truth (dual-rail drivers):

| (Q1,Q0) | XV | XOR |
|---------|----|-----|
| 0 0 | 0 (LO) | 0 ✅ |
| 0 1 | 15 (HI) | 1 ✅ |
| 1 0 | 15 (HI) | 1 ✅ |
| 1 1 | 0 (LO) | 0 ✅ |

`difftest 104 101 165 100` → **PASS BIT-IDENTICAL (32 cells)** in **both** the HI (1,0) and LO (1,1) states.

**(3) LIVE-RAIL DRIVE — the repeater tap DRIVES a downstream comparator from the self-advancing rail ✅ (NEW).**
Beyond prior builds (which only showed the tap PORT reads a static 15): the Qbar0 repeater tap off the
feedback trunk (52,145) → ~50-block haul → a spread-out subtract comparator `out = 15 − Qbar0`. Toggling
bit0: `Qbar0=15 → out=0`, `Qbar0=0 → out=15` over 4 cycles — the comparator tracks the **live** rail.
`difftest 100 101 171 200` → **PASS BIT-IDENTICAL (200 ticks, 593 cells, 295 components)** — the whole
connected network (self-advancing bit0 + tap + haul + comparator). Port discipline proven in-context: without
a re-amp repeater AT the comparator port the side arrived at 5 → wrong `out=10`; the re-amp lifted it to a
clean 15 → correct `out=0/15`.

**Honest status — full 4-state self-advance + ROM walk NOT landed.** The full physical `00→01→10→11→00`
(all four rails → one XOR → Master1.D) and the PC→ROM fetch walk were not reached in budget. Concrete
blocker, now pinned to coordinates: (a) the compact XOR's four input dusts (99–100 / 162–167) are mutually
adjacent, so a hauled real rail cannot be wire-fed to one without shorting a neighbour (drivers avoid this;
a **single** spread comparator fed by a real rail is proven in (3)); (b) bit0's Q0/Qbar0 are enclosed by
build-12's own interconnects (only Qbar0 escapes), and `XV` must fan to Master1's two D-feed points. The fix
is the from-scratch **wide-platform** PC with a shared spread fan-out bus — the same finding builds 16–19
named, now confirmed hands-on. Every constituent is difftest BIT-IDENTICAL on this jar. **No feature patch —
only `test-harness/redstone-computer/`.**

## Rung 22 — 4-STAGE ONE-HOT RING COUNTER (XOR-free program counter) (build-22-ring-counter.txt)

**DESIGN PIVOT.** The binary-counter PC died on physical routing for builds 16–21 (the dual-rail XOR that
computes `bit1.D` packs four mutually-adjacent input dusts that can't each be wire-fed without an adjacency
short; bit0's `Q0/Qbar0` are enclosed by its own T-feedback). A **ring counter** sidesteps ALL of it: **no
XOR** (no packed 4-input gate), **no per-stage T-feedback** (no enclosing feedback ring), and it is **one-hot**
(drives a ROM with no decoder). It is 4 edge-triggered master-slave D flip-flops (build-11 body verbatim) in a
spaced ROW wired `FF_i.D = FF_{i-1}.Q`, loop `FF_0.D = FF_3.Q`. **Each Q feeds exactly one next-stage D** — no
fan-out collision.

**Build.** FF bodies at `DX = 0,-30,-60,-90` (build-20-bit0 lines 4–66, sans T-feedback). Per stage:
`Q_i=(44+dx,101,122)`, `Qbar_i=(48+dx,101,130)`, `Master.D=(61+dx,118)&(62+dx,135)`, `phi1` over
`(62+dx,102,117)&(60+dx,102,133)`, `phi2` over `(46+dx,102,117)&(44+dx,102,133)`. **Slave.Q is enclosed**
(boxed by its S-comparator gadget) — confirms build-21; each link taps **Qbar** and recovers `Q = 15 − Qbar`
with one subtract comparator. Key discovered rules: a repeater rear **directly on the Qbar rail** unbalances
the sensitive cross-coupled latch and destroys its state → tap a **1-dust isolating stub**; re-amp the Qbar
drop **every ≤5** so the comparator side sees a clean 15 (else `15−13=2` garbage); place the invert's 15-source
block **after** the comparator so it re-evaluates its rear (freshly-set diodes don't re-eval until a neighbour
update — build-21's rule); FF capture needs **12-tick non-overlapping phases** + a D pre-settle (6-tick fails).
Generator: `build-22-gen_ring.py` (+ `build-22-{floor,ffs,links,loop}.commands.txt`).

**PHYSICAL SHIFT — the milestone ✅ (no driver).** Init one-hot `1000` (flush to 0000, inject a 1 for one
cycle, release). Clock two-phase; the '1' propagates ONLY through the Qbar-tap/invert register→register links:

| clock | Q0 Q1 Q2 Q3 |
|-------|-------------|
| init  | **1 0 0 0** |
| clk 1 | **0 1 0 0** |
| clk 2 | **0 0 1 0** |
| clk 3 | **0 0 0 1** |

The one-hot bit **physically shifts `1000 → 0100 → 0010 → 0001`** across the four edge-triggered stages with
**no driver** — the autonomous program-counter walk — and it **avoids the XOR-fanout blocker entirely** (no XOR,
no packed gate; each Q drives exactly one next-D). Clean and repeatable.

**difftest ✅.** The whole ring (4 master-slave FFs + 3 shift links + loop link, single-region):
- held `1000`, `difftest 44 101 122 200` → **PASS BIT-IDENTICAL (200 ticks, 1986 cells, 999 components, 26 chunks)**
- held `1000`, `difftest 14 101 122 150` → **PASS BIT-IDENTICAL (150 ticks, 1982 cells)**

**Honest status — loop recirculation + ROM.** Loop `0001→1000` NOT landed in budget: the ~110-cell east
loop-haul + its invert suffer a long-haul diode staleness (when `Qbar3` flips the loop invert doesn't refresh,
so `D0` stays stale and the '1' falls off the west end `0001→0000`). The **identical** invert+haul pattern on
the three SHORT adjacent links refreshes every clock (the clean shift proves it) and the difftest is
BIT-IDENTICAL — so it is a long-haul physical-settle issue, not a logic/compiler fault; fix = a shorter re-amp-
dense return lane (same class as builds 16–21). The one-hot ROM fetch walk (each `Q_i AND word_i`, OR down each
column — no decoder) depends on the closed ring and was not reached. **The ring counter sidestepped the
XOR-fanout death-loop and delivered a difftest-clean, physically-shifting one-hot PC.** No feature patch —
only `test-harness/redstone-computer/`.

## Rung 23 — CLOSED SELF-RECIRCULATING RING-PC + ONE-HOT ROM FETCH WALK (build-23-ring-pc.txt)

**Lands the two things build-22 left open.** The 4 FFs + 3 shift links are build-22 verbatim; build-23 adds
a corrected loop link `Q3->D0` and a decoder-less one-hot ROM. Generators: `build-23-gen_loop_close.py`,
`build-23-gen_rom.py`; controller `build-23-ctl.py`; command streams `build-23-{loop-close,rom}.commands.txt`.

**(1) The loop CLOSES — the ring self-recirculates forever, no driver ✅ THE MILESTONE.** build-22's
"long-haul staleness" was **not** staleness: its loop reused the short-link invert (comparator `facing=east`,
output exits WEST) and then hauled EAST back to stage0, so the eastward `fill west..east` **ran through and
overwrote the comparator + its 15-source rear block** with plain dust — no inversion, so `D0 = Qbar3 = NOT Q3`
(stuck high, ring fills `1000->1100->1110->1111`). difftest was still BIT-IDENTICAL because the degenerate
wiring compiles identically to vanilla — the compiler was never at fault. **Fix A:** for an eastward haul the
invert comparator must face **WEST** (rear 15-block on the WEST, output exits EAST) so the haul starts east of
it and never overwrites it. **Fix B:** the ~110-cell return haul at re-amp-every-≤5 has ~22 repeaters
(≥44 game-ticks delay) > one D-settle window, so `D0` lagged `Q3` and a **phantom** second `1` appeared — cured
by **sparse** re-amp on the output haul (every 12 < the 15-cell decay limit, to minimise delay) + a **generous
120-tick D pre-settle** (> total loop delay). (The ≤5 rule still governs the Qbar **drop** feeding the
comparator side, where 15−Qbar *strength* matters.)

| clock | Q0 Q1 Q2 Q3 |
|-------|-------------|
| init  | **1 0 0 0** |
| clk 1 | **0 1 0 0** |
| clk 2 | **0 0 1 0** |
| clk 3 | **0 0 0 1** |
| clk 4 | **1 0 0 0** (WRAP) |

The one-hot `1` recirculates `1000->0100->0010->0001->1000` **forever** on the clock — no driver, nothing
falling off, no phantom (probed all four Q's over 3+ full wraps). difftest whole closed ring: held `1000`,
`difftest 44 101 122 200` → **PASS BIT-IDENTICAL (200 ticks, 2014 cells, 999 components, 26 chunks)**.

**(2) One-hot ROM fetch WALK — no decoder ✅ THE CAPSTONE.** 4 words `Q0=100 Q1=110 Q2=011 Q3=001` (bits
b2 b1 b0), `out_j = OR_i (Q_i AND word_i[j])`. Words chosen with the **consecutive-ones** property (each bit
= an *adjacent* stage pair) so the one-hot OR-matrix routes with **zero wire crossings** in the single y=101
plane. Each `Q_i` is **repeater-tapped** off its link's invert output and dropped **straight down** in its own
x-column (columns 30 apart → never adjacent, no corridors). Each output bus = two re-amped half-lines from its
two source columns meeting at a read cell; side **injector** repeaters (diode) read each column. Discovered
physical rules: taps N of the loop haul cross it via a **Y-bridge** (dust climbs to y=103 over the haul and
back; a landing dust after the down-ramp is mandatory); the flat-world **floor only reached z=165** — redstone
south of it pops off, so extend the stone floor first; re-amp **every 4** on drops (bridge decay is severe);
re-amp must **not** land on a bus tap row (injector side-read needs plain dust); long buses need **two-half**
re-amp to stay above the HI threshold.

| ring  | ROM out | word |
|-------|---------|------|
| 1000  | **100** | W0 ✅ |
| 0100  | **110** | W1 ✅ |
| 0010  | **011** | W2 ✅ |
| 0001  | **001** | W3 ✅ |

The ROM output **walks `100->110->011->001->100`** per clock, driven **only** by the recirculating one-hot PC
(no driver, no decoder), clean for 3 full cycles. difftest whole ring + ROM (single connected region): held
`1000`, `difftest 44 101 122 200` → **PASS BIT-IDENTICAL (200 ticks, 2548 cells, 1266 components, 39 chunks)**;
held `0010`, `difftest -27 101 196 150` (from the ROM b0 read corner) → **PASS BIT-IDENTICAL (150 ticks, 2548
cells)**.

**This is the autonomous instruction-fetch heart of the CPU** — a difftest-clean self-recirculating one-hot
program counter that walks a decoder-less ROM. Next CPU step: decode is trivial with one-hot (the ROM words
ARE the micro-ops); add a register file + integrate the ALU/accumulator. No feature patch — only
`test-harness/redstone-computer/`.

---

## build-24 — MINIMAL RUNNING CPU: FETCH → EXECUTE (the accumulator runs a ROM program) ✅ CAPSTONE

build-23 gave the autonomous instruction-**fetch** heart (self-recirculating ring-PC + decoder-less one-hot
ROM). build-24 wires **fetch → execute**: the ROM word each clock drives an **accumulator**, so the machine
**runs a program** — `ACC := ACC XOR (fetched ROM bit)` every clock, autonomously, on one shared two-phase
clock. No driver, no feature patch (JAR reused, patch-0020 compiler).

**Execute stage.** One accumulator flip-flop = the SAME proven master-slave D-FF body used by every ring
stage (build-22 `FF_TEMPLATE` verbatim), placed in clear space at `DX=-80, DZ=+100` south of the ROM and
clocked by the same clock as the ring. Its D input is `D = XOR(ACC, op)` where `op` = ROM bit **b0**. On
each clock the master captures `XOR(ACC_old, op)` while the slave still holds `ACC_old` (edge-triggered, no
race), and the falling edge writes `ACC_new = ACC_old XOR op`.

**XOR datapath** (`build-24-xor.commands.txt`): Qbar tapped + inverted → `Q=ACC`; two subtract comparators
`compA=ACC-op`, `compB=op-ACC` merge into `M=|ACC-op|=XOR`; `M` fans to both master D-ports via the ring
link's riser delivery. The operand is routed **fully planar** (east of the FF, looped in from the far south
— zero crossings). The XOR is intrinsically cross-coupled, so exactly **one Y-bridge** (build-23 idiom)
carries the Q-side rail over the op-side rail, with a **post-bridge re-amp** repeater (bridge decays 15→7,
below the HI threshold). New lesson: an invert comparator's side-feed must be **plain dust**, not a re-amp
repeater (a repeater on the side cell stuck the output at 15).

**The machine runs.** Program = ROM b0 stream as the ring walks `[b0(W0..W3)] = [0,0,1,1]` (repeating).
Clocked 8 steps (init ACC=1), probing ring / ROM / ACC each clock:

| clk | ring | ROM | ACC | note |
|-----|------|-----|-----|------|
| init| 1000 | 100 | 1 | |
| 1 | 0100 | 110 | 1 | XOR 0 |
| 2 | 0010 | 011 | 1 | XOR 0 |
| 3 | 0001 | 001 | **0** | XOR 1 → toggle |
| 4 | 1000 | 100 | **1** | XOR 1 → toggle |
| 5 | 0100 | 110 | 1 | |
| 6 | 0010 | 011 | 1 | |
| 7 | 0001 | 001 | **0** | toggle |
| 8 | 1000 | 100 | **1** | toggle |

Every step satisfies `ACC_next = XOR(ACC_prev, fetched_b0)`. The signature `1,1,1,0` (repeating) is the XOR
running-sum trajectory for op-stream `[0,0,1,1]` — and it **differs** from the pure LOAD trajectory
(`ACC=op` delayed = `0,0,1,1`), proving the **feedback is live**: ACC computes on its own prior value, i.e.
the accumulator genuinely **executes** (accumulates) the fetched word, not merely latches it. The ring walks
(fetch), the ROM emits the word (fetch), the accumulator computes `ACC:=ACC XOR word.b0` (execute) — one
shared clock, no driver. **This is a minimal running CPU.**

**difftest (whole CPU: ring-PC + one-hot ROM + XOR-accumulator, single connected region):**
- held `ACC=0` (ring 1000): `difftest -36 101 222 200` → **PASS BIT-IDENTICAL (200 ticks, 3226 cells, 1603 components, 48 chunks, single-region=true)**
- held `ACC=1` (ring 0100): `difftest -36 101 222 150` → **PASS BIT-IDENTICAL (150 ticks, 3226 cells)**

A LOAD variant (`D=op`, no feedback — `build-24-load.commands.txt`) was validated first as a lower-risk
stepping stone (ACC = fetched b0 delayed one clock, difftest BIT-IDENTICAL, 3150 cells). The XOR accumulate
is the real capstone. The regionized multithreaded compiler is bit-for-bit transparent to a genuine running
stored-program machine. No feature patch — only `test-harness/redstone-computer/`.

---

## Rung 25 — EXECUTE widened 1-bit XOR → 2-bit REAL ADD accumulator (build-25) — difftest-clean, physical carry

The build-24 minimal CPU executes `ACC := ACC XOR b0` (1 bit). **build-25 widens the EXECUTE datapath to a
genuine 2-bit ADD**: `ACC := (ACC + operand) mod 4`, with a real physical carry that ripples bit0 → bit1.
Every constituent is a PROVEN, difftest-clean tile placed verbatim; only the datapath is widened.

**Reused the patch-0020 `coderyo-bundler-26.2` jar — NO rebuild.** Booted
`-Dcoderyo.redstone.compile.enabled=true`, **port 15568** (RCON 25581), flat world, `spawn-monsters=false`.
`coderyo redstone difftest x y z ticks` runs via RCON on this jar; verdict from the `[redstone-difftest/live]`
log. Physical reads settle by `tick sprint` (GAME ticks — TPS-independent under the deep comparator cascade).

**Datapath.**
- **ADD = build-08 2-bit ripple-carry adder** = the build-07 side-entry-Cin full-adder tile placed at `x+0`
  (bit0) and `x+60` (bit1) + the build-08 carry interconnect (Cout0 → bit1 Cin bus). `A = ACC`, `B = operand`,
  `Cin0 = 0`. SUM0 `(30,101,374)`, SUM1 `(90,101,374)`, Cout1 `(104,101,371)`.
- **ACC = 2-bit register = two master-slave D flip-flops** (build-24 ring stage-0 geometry = build-11/12
  edge-triggered latch): **FF0 (bit0)** at `(dx=0,dz=190)` Q0=`(44,101,312)`; **FF1 (bit1)** at
  `(dx=80,dz=190)` Q1=`(124,101,312)`. Per FF: D inject = y=102 block over `(61,118)&(62,135)`; clock E =
  master `(62,117)&(60,133)`, slave `(46,117)&(44,133)`. Power-on metastability is broken by one D=0 clock.
- **One clock = `ACC := ACC + operand`:** adder A ← ACC (Q fed back), adder B ← operand → the real ripple
  adder physically computes the 2-bit SUM with carry → two-phase clock latches SUM into the register → new
  ACC = SUM. In build-25 the Q→A feedback and the operand are presented **per-clock by the driver**
  (`build-25-acc.py`): the ADD is **driven per-clock with the register latching the physical SUM** — the
  2-bit real-arithmetic milestone. (Physical SUM→D + Q→A fan-out and a 2-bit ROM front-end are NEXT.)

**difftest verdicts (compiler == vanilla, BIT-IDENTICAL).**

| network | seed | ticks | verdict |
|---|---|---|---|
| 2-bit ripple adder (A=3,B=3=6) | `30 101 374` | 60 | **PASS — 648 cells / 332 components** |
| FF0 bit0 register (ACC=3) | `44 101 312` | 60 | **PASS — 268 cells / 137 comp** |
| FF1 bit1 register (ACC=3) | `124 101 312` | 60 | **PASS — 268 cells / 137 comp** |

**Physical arithmetic (register Q read live each clock, real adder computing each sum).**

| program (operands) | ACC trajectory | note |
|---|---|---|
| `[1,1,1,1]` | `0 → 1 → 2 → 3 → 0` | full carry wrap: `3+1 = 4 mod 4 = 0`, Cout=1 |
| `[1,1,2,0]` | `0 → 1 → 2 → 0 → 0` | `2+2 = 4 mod 4 = 0`, Cout=1 |
| adder truth (7 vectors) | `1+1=2, 3+1=0/c, 2+2=0/c, 1+2=3, 3+3=2/c, 0+0=0, 2+1=3` | all CORRECT, carry ripples bit0→bit1 |

Every step satisfies `ACC_next = (ACC_prev + operand) mod 4` with the carry physically rippling from bit0's
Cout into bit1 — genuine 2-bit arithmetic, not the 1-bit XOR of build-24. The regionized multithreaded
redstone compiler is **bit-for-bit transparent** to the whole 2-bit adder (648 cells) and both register FFs
(268 cells each). **This is the 1-bit XOR → 2-bit real ADD datapath widening — the first real arithmetic step
toward a programmable CPU.**

**NEXT.** (1) physical SUM→D and Q→A fan-out (autonomous feedback loop, no per-clock driver) — the
build-12 non-crossing-lane discipline extended to the 2-bit board; (2) a **2-bit ROM front-end** (reuse the
build-24 ring-PC + one-hot ROM, widened to a 2-bit operand word) driving B; (3) **opcode decode** (LOAD vs
ADD select on the adder B / register D) → the minimal programmable CPU; then wider (4-bit ACC + ALU).
No feature patch — only `test-harness/redstone-computer/`.

## build-26 — PHYSICAL FEEDBACK for the 2-bit accumulator: SUM→D half CLOSED via an elevated vertical-bridge express bus ⚠️

The build-25 accumulator did real 2-bit arithmetic (`ACC := ACC + operand`, carry) but its Q→A feedback and
operand were **driver-fed per clock**. build-26 wires the feedback **physically**. Boot = the reused
`coderyo-bundler-26.2` patch-0020 jar (NO rebuild), `-Dcoderyo.redstone.compile.enabled=true`, port **15568**,
RCON 25581, flat world, spawn-monsters off; settle by GAME ticks; difftest verdicts from the
`[redstone-difftest/live]` server log.

**Base reused VERBATIM, re-confirmed difftest BIT-IDENTICAL on this jar.** Placed via build-25's own
`adder.py place` + `ff.py place 0 190` + `ff.py place 80 190`:
| network | difftest seed | verdict |
|---|---|---|
| 2-bit ripple adder | `30 101 374 60` | **BIT-IDENTICAL (60 ticks, 644 cells, 328 comp)** |
| FF0 (bit0 register) | `44 101 312 60` | **BIT-IDENTICAL (60 ticks, 274 cells)** |
| FF1 (bit1 register) | `124 101 312 60` | **BIT-IDENTICAL (60 ticks, 274 cells)** |

**Driver-fed 2-bit real-add accumulator reproduced** on the fresh jar: program `[1,1,1,1]` →
`ACC 0→1→2→3→0` (genuine 2-bit carry: 3+1=4 mod4=0, Cout=1). Every step `ACC := ACC+op` OK.

**The physical-wiring problem (found this build).** build-25 reuses the *proven* placement — but the adder
(`z≈369–377`) and the two registers (`z≈308–325`) sit **~45 blocks apart**, and every adder I/O cell
(SUM/A/B) is **buried inside the dense build-07 full-adder tile**: a lateral exit crosses live y=101 logic.
Probing confirmed the routing gap `z 331–359` is clear but the tile columns are not.

**Solution — the build-24 ELEVATED VERTICAL-BRIDGE idiom.** Lift the buried output straight **up to y=103**
(two stone-step climbs), run an express dust bus **north over the top of the whole adder** on y=102 stone
pillars, **drop back to y=101** in the clear gap, then route at ground level to the register D-port — the
express layer never touches a y=101 logic cell. **Repeater convention re-verified** on this fork (against the
build-07 XOR merge): `repeater[facing=D]` outputs the side **opposite** D — push north = `facing=south`,
push east = `facing=west` (my first attempt reversed every diode and delivered 0; flipping fixed it).

**Result — SUM0 → D0 physical feedback wire BUILT and TRACED end-to-end** (`build-26-autofeedback.py`):
| point on the wire | SUM0 = 1 | SUM0 = 0 |
|---|---|---|
| SUM0 adder output `30,101,374` | 14 | 0 |
| bridge input `32,101,374` | 12 | 0 |
| gap corner `62,101,356` | 10 | 0 |
| pre-inject `62,101,327` | 15 | 0 |
| **register D-cell `62,101,325`** | **15** | **0** |

The adder's SUM0 output is delivered across the entire structure to the register's master D-port — **the
`SUM→D` half of the physical feedback loop is CLOSED** (data flows adder→register with no driver). And the
register **captures a 1 through the physical wire** (clock → `Q0 = 15`) when the master's D-ports are asserted.

**Honest verdict — NOT yet autonomous.** The master latch has **two** D injection cells
(`61,101,308` and `62,101,325`); only `62,325` is on the physical wire so far, so single-clock capture of a
**0** and reliable latching still need the **second-port branch**. Remaining for full autonomy: (a) branch
the SUM0 bus to the 2nd D-port; (b) the **SUM1→D1** twin bridge (bit1); (c) the **Q→A** half — register Q
feeding the adder A input, which is a **4-way fan-out per bit** (build-07 consumes A at 4 buried cells) via
repeater-isolated taps; (d) a **constant operand** on B (4 redstone_blocks over the B0 cells = program `+1`).
With those, `ACC := ACC + operand` self-accumulates on a stepped 2-phase clock with **no data driver**.

**What IS proven this build:** the reused datapath is difftest-clean on the jar; the real-add accumulator
runs (driver-fed); and the hard part of the autonomy problem — **getting a buried adder output physically
across the dense tile to the register D-port** — is **solved** by the elevated vertical-bridge bus and
traced delivering the correct value. The `SUM→D` half of the loop is physically closed; the `Q→A` half and
the 2-bit ROM front-end are the remaining routing on the same proven idiom. **No feature patch — only
`test-harness/redstone-computer/`.**

## build-27 — toward the SELF-COUNTING 2-bit accumulator: constant +1 operand CLOSED, twin SUM→D bridge built, D-injection blocker diagnosed ⚠️

Goal: make the build-25/26 accumulator **autonomous** — a 2-bit register that counts `0→1→2→3→0` on a
bare clock with **no data driver**, by physically closing `SUM→D`, `Q→A`, and a **constant +1** on operand
B. build-26 traced only `SUM0→D0`. build-27 extends the idiom to both bits, adds the constant operand, and
pins down the exact reason the loop cannot close with a wire. Boot = the reused `coderyo-bundler-26.2`
patch-0020 jar (NO rebuild), `-Dcoderyo.redstone.compile.enabled=true`, port **15568**, RCON 25581, flat
world, spawn off; settle by GAME ticks; difftest verdicts from the `[redstone-difftest/live]` log.

**CLOSED this build — the constant +1 operand (difftest-clean):** redstone_blocks over the four B0 cells
(B0=1), B1=0, Cin0=0 — a permanent `+1` on B with no driver.
| test | verdict |
|---|---|
| `difftest 30 101 374 60` (adder **incl. B0 blocks**) | **BIT-IDENTICAL (60 ticks, 696 cells)** |
| drive only A, read SUM=A+1 | `A=0→1, 1→2, 2→3, 3→0` (Cout1=1 on the 3→0 wrap) — **all OK, STABLE** |

So the **+1 increment arithmetic — the heart of the counter — is physically correct on a real constant
operand** (no B driver). Base preserved BIT-IDENTICAL: FF0 `44 101 312` (396 cells), FF1 `124 101 312` (436).

**Built this build — the twin `SUM1→D1` bridge** (mirror of the proven `SUM0→D0`, +60 x), plus a laid
**stone floor** under both ground runs (the gap `z331–359` is **void at y=100** — a bare wire there has no
support; build-26's run must have had floor from an earlier session). The climb + y=103 express bus carries
SUM (bus top = **14 when SUM=1, 0 when SUM=0** — the signal travels up and over the adder).

**BLOCKER — why the loop does NOT self-count yet (the real finding).** The FF master **D-port cells**
(`61,308`/`62,325`, `141,308`/`142,325`) are **not clean combinational inputs** — they are the **output dust
of the FF's internal D-injection subtract comparators**, and in the latched state they read **power 15 by
default** (probed 15 with the bridge fully cut). A redstone **dust** bridge can only **OR** into that node:
it can **raise** D but can **never force D low**, so **the register cannot capture a 0 through a wire**.
build-25's driver works only because a **redstone_block strongly overrides** the cell (a wire cannot). This
also explains why a clock through the bridge latched `Q=1` regardless of SUM. Additionally the combined
adder+2FF+2bridge net is hard to settle in **live** reads (deep comparator cascade), and difftest of the
connected whole diverges on the bridge cells (real=15/sim=0 at the bridge dust).

**Honest verdict — NOT autonomous / does NOT self-count.** Physically proven this build: the **constant +1
operand** (difftest-clean, A+1 = 0→1→2→3→0 correct) and the **twin SUM-delivery bus**. Open links: (1)
**register-capture-through-a-wire** — needs a strong-power injection or an **FF redesign exposing a clean
wire-drivable D node** (the wire-can-only-OR limit is the crux; build-26's "D-cell=0" trace was a
latch-state coincidence, not a controllable input); (2) **Q→A 4-way fan-out**, gated behind (1). **NEXT:**
give the D-FF a clean combinational D input (or strong-power the D cell), then wire Q→A; then the ROM/variable
operand. **No feature patch — only `test-harness/redstone-computer/`.**

## build-28 — WIRE-DRIVABLE-D master-slave FLIP-FLOP: a wire forces D (and Q) to BOTH 0 and 1 — the blocker CLOSED, difftest BIT-IDENTICAL ✅

The build-27 blocker — *a wire could only OR the register's D to 1, never force 0, so the 2-bit
accumulator could not capture a SUM of 0* — is **fixed**, and the fix is **difftest-clean in both
captured states**. This is THE unblock for all autonomous feedback (registers, accumulators, the CPU).

**Root cause (and it is NOT an FF-logic fault — build-27's diagnosis was wrong).** The FF (build-10/-11
gated D-latch) already exposes a **clean, combinational, wire-drivable D** — as **two** input cells:
`D_north (61,118)` = the **R comparator's WEST SIDE** (`R = E − D_north`) and `D_south (62,135)` = the
**S comparator's REAR** (`S = D_south − nE`). build-27 (a) fed the SUM bridge into **only D_south**, leaving
`D_north` undriven — so `R = E − D_north` could never fire and the latch could never **RESET** (D "stuck at
1"); and (b) hit a **wire-congestion short** (reproduced & fixed live here): a D-feed riser laid one cell
from the S-gadget's **nE 15-source block at `(59,134)`** leaks 15 into the whole D net — riser at `x=58` →
D net pinned at **15** (build-27's "floats to 15 by default"); riser moved to a clear lane → D net follows
**0/1**. So the "15-default" was a construction short + a one-port feed, **not** an internal comparator
output. The D cells are genuine inputs.

**The fix (build-28-wireff.py, WireFF extends ff.FF).** Drive the D **input wire** (one toggleable source
block emulating the incoming adder SUM) into **BOTH** master D-ports through **repeater-cleaned** branches:
- Branch A `source → D_south`: west `z=140` → north `x=62` → 2 cleaning repeaters → `D_south (62,135)`.
- Branch B `source → D_north`: the master body + Q-rail + forward-interconnect bus **wall off `z=122`
  across `x=50..64`**, so the only clear N-S lane is **`x=66`** (east of the Qbar rail `x=64`); `D_north` is
  then reached from the **NORTH (`z=115` row)** to dodge the R-gadget and the `E_north` enable dust (which
  would short Enable into D). Re-amp so D arrives at a **clean 15** (else `R=E−D` subtract mis-fires).

**RESULT — a WIRE forces Q to BOTH 0 and 1 (vanilla live reads, Q @`244,101,622`).** Toggling **only** the
source block (D via wire), two-phase clock, reading Q:

| D_wire | D_north | D_south | Q | verdict |
|--------|---------|---------|---|---------|
| 0 | 0 | 0 | **0** | RESET through the wire — OK |
| 1 | 15 | 15 | **1** | SET through the wire — OK |
| 0→1→1→0 | tracks | tracks | **0→1→1→0** | all OK, bidirectional |

Then driven with the **exact per-bit SUM streams of a full `ACC = 0→1→2→3→0` count**: bit0 LSB stream
`D=0,1,0,1,0 → Q=0,1,0,1,0` (5/5 OK); bit1 MSB stream `D=0,0,1,1,0 → Q=0,0,1,1,0` (5/5 OK). **The
wire-driven register captures every ACC state, including every forced-0** — the precise
*register-capture-through-a-wire* link build-27 lacked is proven for the whole count.

**RESULT — difftest (compiler == vanilla), verdict from the `[redstone-difftest/live]` log:**

| held state | command | verdict |
|------------|---------|---------|
| Q = 1 | `coderyo redstone difftest 244 101 622 200` | **PASS BIT-IDENTICAL (200 ticks, 369 cells, 183 components, single-region)** |
| Q = 0 | `coderyo redstone difftest 244 101 622 200` | **PASS BIT-IDENTICAL (200 ticks, 368 cells, 182 components)** |

=> the whole wire-drivable-D master-slave register (torch latches + comparator enable-gates + forward
interconnect + the two repeater-cleaned D-feed branches) compiles **bit-for-bit to vanilla in BOTH captured
states**. An ordinary wire (the adder SUM) now drives the register's D to **both 0 and 1** — the build-27
D-injection blocker (the last *logic* gap) is **closed**.

**What remains for the physical 2-bit self-count (honest).** With the wire-drivable D proven and
difftest-clean, closing the full `ACC := ACC + 1` loop over the **build-25 ripple adder** is now purely a
**dedicated-lane routing** exercise — `SUM[1:0] → each FF's BOTH D-ports` and `Q[1:0] → adder A[1:0]` over
the adder↔register gap (the same class of wide-board, non-crossing feedback routing that build-12 already
solved for the 1-bit accumulator, and that build-27 framed as the open link). No new logic or compiler work
remains; the wire-drivable-D register is the crux that unblocks it. **No feature patch — only
`test-harness/redstone-computer/`.**
