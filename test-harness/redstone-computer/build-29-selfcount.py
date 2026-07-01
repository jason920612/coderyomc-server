#!/usr/bin/env python3
# build-29: SELF-COUNTING 2-bit accumulator (ACC := ACC + 1, no driver) -- close the loop.
#   Datapath (all PROVEN): build-25 2-bit ripple adder + constant +1 on B (build-27) +
#   TWO build-28 WIRE-DRIVABLE-D master-slave FFs = ACC register (bit0 @dx=0, bit1 @dx=80, dz=190).
#   The 4 feedback links to close:
#     L1 SUM0 -> FF0 D   : elevated vertical bridge (build-26/27 idiom) SUM0(30,374) -> FF0 D-source
#                          node (66,330); WireFF.dnet fans that node into BOTH master D-ports.
#     L2 SUM1 -> FF1 D   : twin bridge SUM1(90,374) -> FF1 D-source node (146,330).
#     L3 Q0   -> adder A0: Q0(44,312) fanned (repeater-isolated) into the 4 buried A0 dust cells.
#     L4 Q1   -> adder A1: Q1(124,312) fanned into the 4 buried A1 dust cells.
#   One shared 12-tick two-phase clock steps both FFs -> loop self-counts 0->1->2->3->0.
# Reuses drv/adder/ff + wireff.WireFF.  No feature patch -- test-harness only.
import sys, drv, adder
from wireff import WireFF
R = drv.R
DZ = 360
SRCZ = 330                      # WireFF D-source-node z (=140+dz, dz=190)
F0 = WireFF(0, 190)             # bit0: Q0=(44,101,312), D-source node (66,101,330)
F1 = WireFF(80, 190)            # bit1: Q1=(124,101,312), D-source node (146,101,330)
SRC0, SRC1 = 66, 146            # source-node x per FF

def sb(x, y, z, b): R.cmd(f"setblock {x} {y} {z} minecraft:{b}")
def floor(x0, z0, x1, z1, y=100):
    R.cmd(f"fill {min(x0,x1)} {y} {min(z0,z1)} {max(x0,x1)} {y} {max(z0,z1)} minecraft:stone")
W = "redstone_wire"; ST = "stone"

# ------------------------------------------------------------------ base
def place_base():
    R.cmd("forceload add -2 300 152 420")
    adder.place()
    # constant +1 on B: B0 blocks, B1 air, Cin0 air
    for (x, z) in adder.B0: sb(x, 102, z+DZ, "redstone_block")
    for (x, z) in adder.B1: sb(x, 102, z+DZ, "air")
    for (x, z) in adder.CIN0: sb(x, 102, z+DZ, "air")
    for f in (F0, F1):
        f.place(); f.dnet()
        for c in f.Dports(): sb(c[0], c[1], c[2], "air")   # D from wire only
        f.setD_wire(0)                                       # no source block; bridge feeds node
    print("placed base: adder + const+1 + two WireFFs")

# --------------------------------------------- L1/L2 : SUM -> FF D-source node
def sum_to_src(sumx, srcx):
    """Elevated vertical bridge: SUM(sumx,101,374) up to y103, north over the adder,
       drop into the gap, ground-run east then north, inject into (srcx,101,330)."""
    bx = sumx + 2                                   # bridge column (32 / 92)
    sb(sumx+1, 101, 374, W); sb(bx, 101, 374, W)    # tap SUM east
    sb(bx, 101, 373, ST); sb(bx, 102, 373, W)       # climb 101->103
    sb(bx, 102, 372, ST); sb(bx, 103, 372, W)
    for z in range(358, 372): sb(bx, 102, z, ST)    # y=103 express bus north, stone pillars
    for z in range(358, 372): sb(bx, 103, z, W)
    sb(bx, 103, 367, "repeater[facing=south]")      # push north (re-amp)
    sb(bx, 103, 361, "repeater[facing=south]")
    sb(bx, 101, 357, ST); sb(bx, 102, 357, W)       # drop 103->101 in the clear gap
    sb(bx, 101, 356, W)
    floor(bx, 356, srcx, 356)                        # ground run east bx->srcx @z356
    for x in range(bx+1, srcx+1): sb(x, 101, 356, W)
    ax = bx + 6
    while ax < srcx - 2:                              # dense re-amp every 7
        sb(ax, 101, 356, "repeater[facing=west]")    # push east
        ax += 7
    floor(srcx, 331, srcx, 356)                      # ground run north srcx z356->331
    for z in range(331, 356): sb(srcx, 101, z, W)
    for rz in (353, 347, 341, 335):                  # dense re-amp every 6
        sb(srcx, 101, rz, "repeater[facing=south]")
    sb(srcx, 101, 332, "repeater[facing=south]")     # clean inject -> (srcx,331)->(srcx,330) node
    sb(srcx, 101, 331, W)
    print(f"placed SUM->D bridge SUM({sumx},374) -> D-source ({srcx},{SRCZ})")

def bridges():
    sum_to_src(30, SRC0)
    sum_to_src(90, SRC1)

# --------------------------------------------- L3/L4 : Q -> adder A (4-way fan-out)
# A dust cells (block removed -> wire-driven).  Reached from a Q distribution bus laid
# in the clear gap (z 335..368) then repeater-injected into each buried cell.
A0CELLS = [(18,369),(23,370),(38,377),(44,377)]
A1CELLS = [(78,369),(83,370),(98,377),(104,377)]

def clear_A_blocks():
    for (x,z) in A0CELLS+A1CELLS: sb(x, 102, z+DZ, "air")

def q_to_a(qx, cells, busx):
    """qx = Q output x (44 / 124) at z=312. Bring Q south across the gap on a private
       column busx, run an east-west distribution bus at z=365 (just north of the tile),
       tap each of the 4 A cells with an isolated repeater injecting from the north."""
    # Q tap: Q dust is at (qx,101,312); pull it south into the gap on column busx.
    floor(busx, 313, busx, 366)
    sb(qx, 101, 312, W)
    # hop from Q(qx,312) laterally to busx@313 then south
    zlane = 313
    if busx != qx:
        floor(min(qx,busx), 313, max(qx,busx), 313)
        for x in range(min(qx,busx), max(qx,busx)+1): sb(x, 101, 313, W)
    for z in range(313, 366): sb(busx, 101, z, W)
    sb(busx, 101, 320, "repeater[facing=north]")     # push south (rear north)
    sb(busx, 101, 332, "repeater[facing=north]")
    sb(busx, 101, 344, "repeater[facing=north]")
    sb(busx, 101, 356, "repeater[facing=north]")
    # distribution bus at z=365 spanning the 4 cells' x-range
    xs = [c[0] for c in cells]; xlo, xhi = min(xs), max(xs)
    floor(min(xlo,busx), 365, max(xhi,busx), 365)
    for x in range(min(xlo,busx), max(xhi,busx)+1): sb(x, 101, 365, W)
    # re-amp along the bus every ~10
    bx = min(xlo,busx)+6
    while bx < max(xhi,busx)-1:
        sb(bx, 101, 365, "repeater[facing=west]"); bx += 11
    # inject each cell from the north (z 365 -> cell z), private lane per cell
    for (cx, cz) in cells:
        wz = cz + DZ                                  # world z of the A cell (729/730/737)
        floor(cx, 366, cx, wz-1)
        for z in range(366, wz): sb(cx, 101, z, W)
        sb(cx, 101, wz-1, "repeater[facing=north]")   # inject south into the A cell
    print(f"placed Q->A fan-out Q({qx},312) -> {cells}")

def qa():
    q_to_a(44, A0CELLS, 50)      # busx 50 (clear of FF0 body x44..66? uses 50 lane)
    q_to_a(124, A1CELLS, 116)    # busx 116

# --------------------------------------------- clock / read
def clock_both(settle=40):
    drv.sprint(settle)
    F0.setcells(F0.MasterE(), True);  F1.setcells(F1.MasterE(), True);  drv.sprint(16)
    F0.setcells(F0.MasterE(), False); F1.setcells(F1.MasterE(), False); drv.sprint(16)
    F0.setcells(F0.SlaveE(), True);   F1.setcells(F1.SlaveE(), True);   drv.sprint(16)
    F0.setcells(F0.SlaveE(), False);  F1.setcells(F1.SlaveE(), False);  drv.sprint(24)

def read_acc(): return F0.q() + (F1.q() << 1)

def probe_all():
    print("  Q0", F0.q(), "Q1", F1.q(), "ACC", read_acc())
    print("  SUM0", drv.probe(30,101,374), "SUM1", drv.probe(90,101,374))
    print("  D0src", drv.probe(SRC0,101,SRCZ), "D1src", drv.probe(SRC1,101,SRCZ))
    print("  D0n", drv.probe(61,101,308), "D0s", drv.probe(62,101,325),
          "D1n", drv.probe(141,101,308), "D1s", drv.probe(142,101,325))

def reset0():
    # force D low at both source nodes + ports, clock twice -> ACC=0
    for x in (SRC0, SRC1): sb(x, 101, SRCZ, "air")
    for c in F0.Dports()+F1.Dports(): sb(c[0],c[1],c[2],"air")
    clock_both(); clock_both()
    for x in (SRC0, SRC1): sb(x, 101, SRCZ, W)   # restore source dust
    return read_acc()

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv)>1 else "probe"
    if cmd == "base": place_base()
    elif cmd == "bridges": bridges()
    elif cmd == "qa": clear_A_blocks(); qa()
    elif cmd == "reset": print("ACC after reset =", reset0())
    elif cmd == "probe": probe_all()
    elif cmd == "clock":
        n = int(sys.argv[2]) if len(sys.argv)>2 else 1
        for i in range(n):
            clock_both(); print(f"clock {i+1}: ACC={read_acc()} (Q1Q0={F1.q()}{F0.q()})")
    elif cmd == "selfcount":
        print("ACC reset ->", reset0())
        seq = []
        for i in range(int(sys.argv[2]) if len(sys.argv)>2 else 8):
            clock_both(); a = read_acc(); seq.append(a)
            print(f"  clock {i+1}: ACC={a} (Q1Q0={F1.q()}{F0.q()})")
        print("SEQUENCE:", seq)
    elif cmd == "difftest":
        (qx,qy,qz) = (int(sys.argv[2]),int(sys.argv[3]),int(sys.argv[4]))
        t = sys.argv[5] if len(sys.argv)>5 else "200"
        print(R.cmd(f"coderyo redstone difftest {qx} {qy} {qz} {t}"))
    R.close()
