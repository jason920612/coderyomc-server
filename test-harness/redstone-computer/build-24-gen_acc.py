#!/usr/bin/env python3
# build-24: EXECUTE stage = a 1-bit accumulator FF driven by a ROM operand bit.
# Wires FETCH (build-23 ring-PC + one-hot ROM) -> EXECUTE: the ROM word each clock drives
# the accumulator, so the machine RUNS the ROM program.
#
# The accumulator is the SAME proven master-slave D-FF body used by every ring stage
# (build-22 FF_TEMPLATE, verbatim), placed in clear space SOUTH of the ROM at (DX,DZ),
# clocked by the SAME two-phase clock as the ring.  Its D input is:
#   LOAD mode      : D = op            -> ACC := op          (register loads fetched bit)
#   ACCUMULATE mode: D = XOR(Q, op)    -> ACC := ACC XOR op  (1-bit running sum, gated toggle)
# where op = one ROM output bit (default b0 read cell), re-amped to a clean 15.
#
# Delivery of the computed D to BOTH master D-ports reuses the ring link's riser fan-out
# (build-22 gen_ring link steps 5-7), translated to (DX,DZ). Operand is routed from the ROM
# read cell around the EAST of the FF and back in from the SOUTH -> a fully planar path
# (no wire crossing, so no Y-bridge needed).
import sys

DX, DZ = -80, 100          # FF placement offset (clear area south of the ROM)
CORR = 145                 # local delivery corridor z (matches link)

FF_TEMPLATE = """
setblock 62 101 122 minecraft:stone
setblock 61 101 122 minecraft:redstone_wall_torch[facing=west]
setblock 62 101 121 minecraft:repeater[facing=north]
setblock 63 101 122 minecraft:repeater[facing=east]
setblock 62 101 130 minecraft:stone
setblock 63 101 130 minecraft:redstone_wall_torch[facing=east]
setblock 62 101 131 minecraft:repeater[facing=south]
setblock 61 101 130 minecraft:repeater[facing=west]
setblock 60 101 122 minecraft:redstone_wire
fill 60 101 123 60 101 130 minecraft:redstone_wire
setblock 64 101 130 minecraft:redstone_wire
fill 64 101 122 64 101 129 minecraft:redstone_wire
setblock 62 101 118 minecraft:comparator[facing=north,mode=subtract]
setblock 62 101 117 minecraft:redstone_wire
setblock 61 101 118 minecraft:redstone_wire
setblock 62 101 119 minecraft:redstone_wire
setblock 62 101 120 minecraft:redstone_wire
setblock 59 101 134 minecraft:redstone_block
setblock 60 101 134 minecraft:comparator[facing=west,mode=subtract]
setblock 60 101 133 minecraft:redstone_wire
setblock 61 101 134 minecraft:redstone_wire
setblock 62 101 134 minecraft:comparator[facing=south,mode=subtract]
setblock 62 101 135 minecraft:redstone_wire
setblock 62 101 133 minecraft:redstone_wire
setblock 62 101 132 minecraft:redstone_wire
setblock 46 101 122 minecraft:stone
setblock 45 101 122 minecraft:redstone_wall_torch[facing=west]
setblock 46 101 121 minecraft:repeater[facing=north]
setblock 47 101 122 minecraft:repeater[facing=east]
setblock 46 101 130 minecraft:stone
setblock 47 101 130 minecraft:redstone_wall_torch[facing=east]
setblock 46 101 131 minecraft:repeater[facing=south]
setblock 45 101 130 minecraft:repeater[facing=west]
setblock 44 101 122 minecraft:redstone_wire
fill 44 101 123 44 101 130 minecraft:redstone_wire
setblock 48 101 130 minecraft:redstone_wire
fill 48 101 122 48 101 129 minecraft:redstone_wire
setblock 46 101 118 minecraft:comparator[facing=north,mode=subtract]
setblock 46 101 117 minecraft:redstone_wire
setblock 45 101 118 minecraft:redstone_wire
setblock 46 101 119 minecraft:redstone_wire
setblock 46 101 120 minecraft:redstone_wire
setblock 43 101 134 minecraft:redstone_block
setblock 44 101 134 minecraft:comparator[facing=west,mode=subtract]
setblock 44 101 133 minecraft:redstone_wire
setblock 45 101 134 minecraft:redstone_wire
setblock 46 101 134 minecraft:comparator[facing=south,mode=subtract]
setblock 46 101 135 minecraft:redstone_wire
setblock 46 101 133 minecraft:redstone_wire
setblock 46 101 132 minecraft:redstone_wire
fill 50 101 122 59 101 122 minecraft:redstone_wire
setblock 50 101 121 minecraft:repeater[facing=south]
fill 50 101 116 50 101 120 minecraft:redstone_wire
setblock 50 101 115 minecraft:repeater[facing=south]
fill 41 101 114 50 101 114 minecraft:redstone_wire
setblock 45 101 114 minecraft:repeater[facing=east]
fill 43 101 115 43 101 118 minecraft:redstone_wire
setblock 44 101 118 minecraft:repeater[facing=west]
fill 41 101 115 41 101 137 minecraft:redstone_wire
setblock 41 101 122 minecraft:repeater[facing=north]
setblock 41 101 130 minecraft:repeater[facing=north]
fill 42 101 137 46 101 137 minecraft:redstone_wire
setblock 46 101 136 minecraft:repeater[facing=south]
"""

out = []
def w(s): out.append(s)

def tX(x): return x + DX
def tZ(z): return z + DZ

def emit_translated(cmd):
    p = cmd.split()
    if p[0] == "fill":
        p[1] = str(tX(int(p[1]))); p[3] = str(tZ(int(p[3])))
        p[4] = str(tX(int(p[4]))); p[6] = str(tZ(int(p[6])))
    else:  # setblock
        p[1] = str(tX(int(p[1]))); p[3] = str(tZ(int(p[3])))
    w(" ".join(p))

def ff():
    for c in FF_TEMPLATE.strip().splitlines():
        emit_translated(c)

# --- delivery: source dust at M=(tX(47),tZ(145)) -> both master D-ports, reuse link risers 5-7 ---
def hseg(x1,x2,z): a,b=min(x1,x2),max(x1,x2); w(f"fill {a} 101 {z} {b} 101 {z} minecraft:redstone_wire")
def vseg(x,z1,z2): a,b=min(z1,z2),max(z1,z2); w(f"fill {x} 101 {a} {x} 101 {b} minecraft:redstone_wire")
def rep(x,z,f): w(f"setblock {x} 101 {z} minecraft:repeater[facing={f}]")
def comp(x,z,f): w(f"setblock {x} 101 {z} minecraft:comparator[facing={f},mode=subtract]")
def blk(x,z): w(f"setblock {x} 101 {z} minecraft:redstone_block")

def deliver():
    # translated link riser fan-out: source at (Qsrc,corr) -> D_north(61,118) & D_south(62,135)
    corr = tZ(CORR)
    Rx=tX(66); Dsx=tX(62); lane_w=tX(59); Qsrc=tX(47)
    # step4 haul Qsrc..Rx at corr (flow east: facing=west)
    hseg(Qsrc, Rx, corr)
    x=Qsrc+8
    while x < Rx:
        if x not in (Dsx,):
            rep(x, corr, "west")
        x+=8
    # step5 east riser Rx up to z=tZ(115)
    vseg(Rx, tZ(115), corr-1)
    z=corr-7
    while z > tZ(118): rep(Rx, z, "south"); z-=8
    # step6 D_south riser Dsx up to z=tZ(136) -> D_south(tX(62),tZ(135))
    vseg(Dsx, tZ(137), corr-1)
    z=corr-5
    while z > tZ(143): rep(Dsx, z, "south"); z-=8
    rep(Dsx, tZ(136), "south")
    # step7 z=tZ(115) lane Rx->lane_w, drop -> D_north(tX(61),tZ(118))
    hseg(lane_w, Rx, tZ(115))
    rep((Rx+lane_w)//2, tZ(115), "east")
    vseg(lane_w, tZ(116), tZ(118))
    rep(lane_w+1, tZ(118), "west")

# --- operand: b0 read cell (-27,196) re-amped, routed planar (east of FF, loop in from south) to M ---
B0 = (-27, 196)   # b0 ROM read cell
M  = (tX(47), tZ(145))   # delivery source cell = (-33, 245)

def op_reamp_to_south():
    """Re-amp op at the read cell and haul it to a staging cell (M[0], M[1]+5) approaching M from SOUTH.
       Planar route: read -> east to x=-12 (east of FF & risers) -> south below everything ->
       west to M column -> north up to just south of M. Returns the staging cell feeding M's south."""
    bx, bz = B0
    rep(bx, bz+1, "north")               # rear=read(196) out south -> (bx,197) clean op=15
    EASTX = -12                          # east of FF (x>=-16) and risers (Rx=-14)
    SOUTHZ = M[1] + 5                     # 250, south of FF(<=237) and risers(<=245)
    # east leg at z=bz+2 (198)
    hseg(bx, EASTX, bz+2)
    xr = bx+6
    while xr < EASTX:
        rep(xr, bz+2, "west"); xr+=6      # flow east -> facing=west
    # south leg column x=EASTX from bz+2 to SOUTHZ
    vseg(EASTX, bz+2, SOUTHZ)
    zz = bz+2+6
    while zz < SOUTHZ:
        rep(EASTX, zz, "north"); zz+=6    # flow south -> facing=north
    # west leg at z=SOUTHZ from EASTX to M[0]
    hseg(M[0], EASTX, SOUTHZ)
    xr = EASTX-6
    while xr > M[0]:
        rep(xr, SOUTHZ, "east"); xr-=6    # flow west -> facing=east
    # north leg column x=M[0] from SOUTHZ up to M[1]+1
    vseg(M[0], M[1]+1, SOUTHZ)
    return (M[0], M[1]+1)                 # staging cell just SOUTH of M

def load():
    """D = op : op staged south of M, one repeater pushes it north into M."""
    sc = op_reamp_to_south()
    rep(sc[0], sc[1], "south")            # rear south=(sc) out north -> M

def xor_accumulate():
    """D = XOR(Q, op) : the proven, difftest-clean accumulate insert.
    Replaces LOAD's op->M push with an XOR(Q,op) merge at M=(-33,245):
      Q from Qbar_acc(-32,230) tap+invert -> (-33,241)
      compA@(-33,243)[north] rear=Q side=op  => Q-op -> M
      compB@(-33,247)[south] rear=op side=Q  => op-Q -> M
      M = |Q-op| = XOR.  op arrives from the south loop at (-33,250).
      One Y-bridge: the Q-side rail (x=-35) hops the op-side rail at (-35,243).
    The exact block lives in build-24-xor.commands.txt (empirically calibrated + committed);
    emit it verbatim so `gen xor` reproduces the tested wiring."""
    import os
    p = os.path.join(os.path.dirname(os.path.abspath(__file__)), "build-24-xor.commands.txt")
    with open(p, encoding="utf8") as f:
        for ln in f:
            ln = ln.rstrip("\n")
            if ln.strip():
                w(ln)

if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv)>1 else "ff"
    if mode=="ff": ff()
    elif mode=="deliver": deliver()
    elif mode=="load": load()
    elif mode=="xor": xor_accumulate()
    elif mode=="all_load":
        ff(); deliver(); load()
    print("\n".join(out))
