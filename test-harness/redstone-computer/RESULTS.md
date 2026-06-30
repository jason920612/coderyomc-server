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
the half-adder, **and the complete 1-bit full adder (SUM + Cout)** are bit-identical
to vanilla and logically correct across their full truth tables. Running difftest
totals: **30 (gates+half-adder) + 16 (full-adder SUM/Cout) = 46 BIT-IDENTICAL cases,
0 divergences.** The full adder is the first true arithmetic block and the unit that
tiles into the 4-bit ripple-carry adder (chain 4, Cout→Cin).

Rung 2 (sequential / memory) is opened: a comparator-NOR RS latch was built and the
HOLD failure was diagnosed to dust-attenuation in the feedback (not the compiler) —
the fix is a torch-based latch, queued next. **No feature patch was added — only
`test-harness/redstone-computer/`** (build scripts + this file).

### What the CPU rung needs next
1. **1-bit memory (torch RS latch / D-latch)** — the missing pillar; build-04 has the
   exact diagnosis and the torch recipe to use.
2. **4-bit ripple-carry adder** — tile 4 of this validated full adder, Cout→Cin, and
   difftest an input sweep (the full-adder map is ready to be instantiated 4×).
3. With a working register (4× D-latch + shared enable) and the adder, an
   accumulator/ALU slice becomes assemblable — the first CPU-shaped datapath.
