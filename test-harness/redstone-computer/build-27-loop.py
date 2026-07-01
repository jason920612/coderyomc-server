#!/usr/bin/env python3
# build-27: toward the 2-bit AUTONOMOUS accumulator (self-counting 0->1->2->3->0, no driver).
#   Extends build-26 (which traced SUM0->D0 only). This build adds:
#     * SUM1->D1 TWIN elevated vertical bridge (mirror of the proven SUM0->D0 idiom, +60 x)
#     * a floor under both ground runs (the gap z331..359 is VOID at y=100 -- wire needs support)
#     * a CONSTANT +1 operand physically on B (redstone_blocks over the four B0 cells; B1=0)
#     * a shared 2-phase clock helper (clock_both) that drives NO data ports
#   Reuses drv/adder/ff. No feature patch -- test-harness only.
#
# RESULTS (e2e on the cpu2 jar, port 15568; difftest verdicts from the server log):
#   * CONSTANT +1 on B: PLACED and difftest BIT-IDENTICAL. Driving only A, the adder computes
#       A+1 = 0->1->2->3->0 (S1S0 01,10,11,00; Cout1=1 on the 3->0 wrap) -- STABLE, all OK.
#       => the "+1" increment arithmetic is physically correct on a real constant operand.
#   * Base preserved: adder@30,101,374 (696 cells, incl. B0 blocks), FF0@44,101,312 (396),
#       FF1@124,101,312 (436) all difftest BIT-IDENTICAL after the taps are severed.
#   * Both SUM->D bridges BUILT; the climb+express-bus carries SUM (bus top reads 14 when
#       SUM=1, 0 when SUM=0 -- signal travels up and over the adder).
#
#   *** BLOCKER (why the loop does NOT self-count yet) ***
#   The FF master D-port cells (61,308)/(62,325) and (141,308)/(142,325) are NOT clean
#   combinational inputs -- they are the OUTPUT dust of the FF's internal D-injection SUBTRACT
#   comparators, and in the latched state they sit at power 15 by DEFAULT (probed 15 with the
#   bridge fully cut). A redstone dust bridge can only OR into that node, so it can RAISE D but
#   can never FORCE D low: the register cannot capture a 0 through a wire. build-25's driver
#   works only because a redstone_block STRONGLY overrides the cell (a wire cannot). Closing the
#   loop therefore needs either a strong-power injection or an FF redesign that exposes a clean
#   wire-drivable D node. The Q->A 4-way fan-out is gated behind this and was not reached.
#   Additionally the combined adder+2FF+2bridge net is hard to settle in LIVE reads (deep
#   cascade); difftest of the connected whole diverges on the bridge cells.
import sys, drv, adder
from ff import FF
R = drv.R
DZ = 360
F0 = FF(0, 190)    # bit0 register: Q0=(44,101,312), Dports (61,308)&(62,325)
F1 = FF(80, 190)   # bit1 register: Q1=(124,101,312), Dports (141,308)&(142,325)

def sb(x, y, z, b): R.cmd(f"setblock {x} {y} {z} minecraft:{b}")
def floor(x0, z0, x1, z1, y=100):
    lo, hi = min(x0, x1), max(x0, x1)
    R.cmd(f"fill {lo} {y} {min(z0,z1)} {hi} {y} {max(z0,z1)} minecraft:stone")
W = "redstone_wire"; ST = "stone"

# ---------- SUM -> D elevated vertical bridge (build-26 idiom), parametrized ----------
def sum_to_d(bx, dx_dest):
    """bx = adder bridge x column (32 for bit0 @SUM0=30, 92 for bit1 @SUM1=90).
       dx_dest = destination register x (62 for FF0, 142 for FF1)."""
    sumx = bx - 2                       # SUM cell x (30 / 90)
    # tap SUM out east into the bridge input
    sb(sumx+1, 101, 374, W)
    sb(bx, 101, 374, W)
    # climb 101 -> 103 (two stone steps)
    sb(bx, 101, 373, ST); sb(bx, 102, 373, W)
    sb(bx, 102, 372, ST); sb(bx, 103, 372, W)
    # y=103 express bus NORTH over the adder, stone pillars @102
    for z in range(358, 372): sb(bx, 102, z, ST)
    for z in range(358, 372): sb(bx, 103, z, W)
    sb(bx, 103, 367, "repeater[facing=south]")   # push north
    sb(bx, 103, 361, "repeater[facing=south]")
    # drop 103 -> 101 into the empty routing gap
    sb(bx, 101, 357, ST); sb(bx, 102, 357, W)
    sb(bx, 101, 356, W)
    # ground run EAST bx -> dx_dest @ z356 (lay a floor first)
    floor(bx, 356, dx_dest, 356)
    for x in range(bx+1, dx_dest+1): sb(x, 101, 356, W)
    ax = bx + 5
    while ax < dx_dest - 2:
        sb(ax, 101, 356, "repeater[facing=west]")     # push east
        ax += 12
    # ground run NORTH x=dx_dest z356 -> 328, re-amp, inject into D-port (dx_dest,325)
    floor(dx_dest, 328, dx_dest, 356)
    for z in range(328, 356): sb(dx_dest, 101, z, W)
    sb(dx_dest, 101, 349, "repeater[facing=south]")
    sb(dx_dest, 101, 337, "repeater[facing=south]")
    sb(dx_dest, 101, 328, "repeater[facing=south]")
    sb(dx_dest, 101, 327, W)
    sb(dx_dest, 101, 326, "repeater[facing=south]")    # clean inject -> D-port (dx_dest,325)
    print(f"placed SUM->D bridge bx={bx} -> D({dx_dest},325)")

def bridges():
    sum_to_d(32, 62)     # SUM0 -> D0b (62,325)
    sum_to_d(92, 142)    # SUM1 -> D1b (142,325)
    print("both SUM->D bridges placed")

# ---------- constant +1 operand on B: B0=1 (all 4 B0 cells), B1=0 ----------
def const_b():
    for (x, z) in adder.B0:
        sb(x, 102, z+DZ, "redstone_block")
    for (x, z) in adder.B1:
        sb(x, 102, z+DZ, "air")
    # Cin0 = 0
    for (x, z) in adder.CIN0:
        sb(x, 102, z+DZ, "air")
    print("constant +1 on B placed (B0=1, B1=0)")

# ---------- clock (shared 2-phase, master then slave), NO data driver ----------
def clock_both(settle=30):
    drv.sprint(settle)
    F0.setcells(F0.MasterE(), True);  F1.setcells(F1.MasterE(), True);  drv.sprint(14)
    F0.setcells(F0.MasterE(), False); F1.setcells(F1.MasterE(), False); drv.sprint(14)
    F0.setcells(F0.SlaveE(), True);   F1.setcells(F1.SlaveE(), True);   drv.sprint(14)
    F0.setcells(F0.SlaveE(), False);  F1.setcells(F1.SlaveE(), False);  drv.sprint(20)

def read_acc(): return F0.q() + (F1.q() << 1)

def reset0():
    # force both D-ports low, clock twice -> ACC=0
    for c in F0.Dports()+F1.Dports(): sb(c[0],c[1],c[2],"air")
    clock_both(); clock_both()
    return read_acc()

# ---------- tests ----------
def test_sumd():
    # drive adder inputs directly (A,B) so SUM is known, check register captures via bridge.
    for (a,b,exp0,exp1) in [(1,0,1,0),(0,0,0,0),(3,0,1,1),(2,0,0,1)]:
        adder.drive(a,b); drv.sprint(80)
        r=adder.read()
        # clock the register (D fed ONLY by physical bridge)
        clock_both()
        q0,q1=F0.q(),F1.q()
        print(f"A={a} B={b}: SUM=({r['S1']}{r['S0']}) exp D=({exp1}{exp0}) -> Q=({q1}{q0}) "
              f"{'OK' if (q0==exp0 and q1==exp1) else 'XX'}")

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv)>1 else "bridges"
    if cmd=="bridges": bridges()
    elif cmd=="constb": const_b()
    elif cmd=="test_sumd": test_sumd()
    elif cmd=="reset": print("ACC=",reset0())
    elif cmd=="probe":
        print("Q0",F0.q(),"Q1",F1.q(),"ACC",read_acc())
        print("SUM0",drv.probe(30,101,374),"SUM1",drv.probe(90,101,374))
        print("D0b",drv.probe(62,101,325),"D1b",drv.probe(142,101,325))
    elif cmd=="clock": clock_both(); print("ACC",read_acc())
    R.close()
