#!/usr/bin/env python3
# coderyoMC redstone-computer MAP -- build-26: PHYSICAL FEEDBACK for the 2-bit accumulator.
#
# GOAL: make the build-25 driver-fed 2-bit REAL-ADD accumulator AUTONOMOUS by wiring the
#   two feedback data paths physically (no per-clock driver):
#       SUM[1:0] (adder output) -> D[1:0] (register)   ["->D" half]
#       Q[1:0]   (register out) -> A[1:0] (adder)       ["Q->" half, feedback operand A]
#   operand -> adder B (constant ROM word); one shared 2-phase clock steps the register.
#
# WHY IT IS HARD (found empirically this build): build-25 reuses the PROVEN placement
#   (adder difftest-clean @DZ=360, two master-slave FFs @dz=190) but they sit ~45 blocks
#   apart in Z and every adder I/O cell (SUM, A, B) is BURIED inside the dense build-07
#   full-adder tile -- any lateral exit crosses live logic. SOLUTION (build-24 idiom):
#   an ELEVATED VERTICAL-BRIDGE express bus -- lift the buried SUM output straight up to
#   y=103 (two stone-step climbs), run it north over the top of the whole adder on stone
#   pillars, drop it back to y=101 in the empty routing gap (z 331..359), then route at
#   ground level to the register D-port. This crosses the dense tile WITHOUT touching any
#   y=101 logic cell.
#
# REPEATER CONVENTION on this fork (verified against the build-07 XOR merge, and re-verified
#   here): a repeater[facing=D] OUTPUTS toward the side OPPOSITE D and reads its REAR from
#   side D.  So to push a signal NORTH (toward -z) use facing=south; EAST (+x) use facing=west.
#
# STATUS (this build, all e2e on the live cpu2 server, port 15568):
#   * base reused verbatim, difftest BIT-IDENTICAL on the patch-0020 jar:
#         adder  @30,101,374 -> 644 cells ; FF0 @44,101,312 -> 274 ; FF1 @124,101,312 -> 274
#   * driver-fed 2-bit real-add accumulator reproduced: program [1,1,1,1] -> ACC 0->1->2->3->0
#         (genuine 2-bit carry, 3+1=4 mod4=0 Cout=1).
#   * PHYSICAL SUM0 -> D0 feedback wire BUILT + TRACED end-to-end (function below):
#         SUM0=1 -> D-cell(62,101,325)=15 ; SUM0=0 -> D-cell=0   (delivers across the bridge)
#     and the register CAPTURES a 1 through the physical wire (Q0 -> 15) when both master
#     D-ports are asserted.  => the "->D" half of the physical feedback loop is CLOSED.
#   * NOT yet autonomous: the master latch has TWO D injection cells ((61,308) & (62,325));
#     only (62,325) is on the physical wire so far -- the second-port branch, the clean
#     capture of a 0, the Q->A half (register Q feeding the adder A, 4-way fan-out per bit),
#     and the constant-operand B are the remaining wiring. See RESULTS build-26 "NEXT".
#
# Reuses build-25-drv.py / -adder.py / -ff.py as importable modules drv/adder/ff.
# No feature patch -- only test-harness/redstone-computer/.
import drv
R = drv.R

# ---- SUM0 (30,101,374) -> FF0 master D-port (62,101,325) : the PROVEN elevated bridge ----
def place_sum0_to_d0():
    def sb(x, y, z, b): R.cmd(f"setblock {x} {y} {z} minecraft:{b}")
    W = "redstone_wire"; ST = "stone"
    # tap: extend SUM0's own dust one cell into the bridge input (small load on an adder
    # OUTPUT net is fine; a rear-reading repeater here read nothing -- SUM0's merge geometry).
    sb(31, 101, 374, W)                     # SUM0(30,374) -> (31,374) -> (32,374)
    sb(32, 101, 374, W)                     # bridge input
    # climb 101 -> 102 -> 103 (two stone steps)
    sb(32, 101, 373, ST); sb(32, 102, 373, W)
    sb(32, 102, 372, ST); sb(32, 103, 372, W)
    # y=103 express bus NORTH over the whole adder, stone pillars @102, re-amp every ~6
    for z in range(358, 372): sb(32, 102, z, ST)
    for z in range(358, 372): sb(32, 103, z, W)
    sb(32, 103, 367, "repeater[facing=south]")   # push north
    sb(32, 103, 361, "repeater[facing=south]")
    # drop 103 -> 101 into the empty routing gap
    sb(32, 101, 357, ST); sb(32, 102, 357, W)
    sb(32, 101, 356, W)
    # ground run EAST across the gap x32->62 @z356 (on the y=100 stone floor), re-amp
    for x in range(33, 63): sb(x, 101, 356, W)
    sb(37, 101, 356, "repeater[facing=west]")     # push east (close re-amp: source ~8 after drop)
    sb(44, 101, 356, "repeater[facing=west]")
    sb(56, 101, 356, "repeater[facing=west]")
    # ground run NORTH x=62 z356->327, re-amp, then inject into the D-port
    for z in range(328, 356): sb(62, 101, z, W)
    sb(62, 101, 349, "repeater[facing=south]")
    sb(62, 101, 337, "repeater[facing=south]")
    sb(62, 101, 328, "repeater[facing=south]")
    sb(62, 101, 327, W)
    sb(62, 101, 326, "repeater[facing=south]")    # cleaning inject -> (62,325) = master D-port
    print("placed physical SUM0->D0 elevated feedback bridge")

if __name__ == "__main__":
    place_sum0_to_d0()
    drv.sprint(60)
    print("SUM0(30,374)      =", drv.probe(30, 101, 374))
    print("D-cell(62,325)    =", drv.probe(62, 101, 325))
    R.close()
