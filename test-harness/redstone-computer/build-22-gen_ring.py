#!/usr/bin/env python3
# Ring-counter generator for coderyoMC redstone-computer map.
# 4 edge-triggered master-slave D flip-flops (build-11/build-20 body VERBATIM) in a spaced ROW.
# FF_i.D = FF_{i-1}.Q (shift). Optional loop close FF_0.D = FF_3.Q => one-hot ring counter.
# Each FF at DX = -30*i (stage0 easternmost). y=101 plane. Data flows EAST->WEST for adjacent links.
import sys

STRIDE = 30
NST = 4
CORR = 145        # adjacent-link south corridor z
LOOPCORR = 158    # loop-link corridor z

# --- FF body template = build-20-bit0 lines 4-66 (master+slave bodies + internal forward), NO T-feedback ---
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

def tr(cmd, dx):
    p = cmd.split()
    if p[0] == "fill":
        p[1] = str(int(p[1])+dx); p[4] = str(int(p[4])+dx)
    else:
        p[1] = str(int(p[1])+dx)
    return " ".join(p)

def ff(dx):
    return [tr(c, dx) for c in FF_TEMPLATE.strip().splitlines()]

def hseg(x1, x2, z, y=101):
    a, b = min(x1, x2), max(x1, x2)
    return f"fill {a} {y} {z} {b} {y} {z} minecraft:redstone_wire"

def vseg(x, z1, z2, y=101):
    a, b = min(z1, z2), max(z1, z2)
    return f"fill {x} {y} {a} {x} {y} {b} minecraft:redstone_wire"

def rep(x, z, facing, y=101):
    return f"setblock {x} {y} {z} minecraft:repeater[facing={facing}]"

def blk(x, z, y=101):
    return f"setblock {x} {y} {z} minecraft:redstone_block"

def comp(x, z, facing, y=101):
    return f"setblock {x} {y} {z} minecraft:comparator[facing={facing},mode=subtract]"

def link(src_dx, dst_dx, corr):
    """Route Q(src) -> Master.D(dst). Q is recovered from Qbar (which escapes cleanly) via 15-Qbar.
       corr = z-row of the horizontal haul (also the invert-output row)."""
    out = []
    QBx = 48 + src_dx                # source Slave.Qbar rail x (rail z=122..130)
    Mx = 62 + dst_dx                 # dest master base x
    Rx = 66 + dst_dx                 # dest east riser x  (feeds D_north via z=115 lane)
    Dsx = 62 + dst_dx                # dest D_south riser x (z=135)
    lane_w = 59 + dst_dx             # z=115 lane west end / D_north drop x
    # 1. tap Qbar via an ISOLATING STUB: dust at (QBx,131) extends the rail (gentle 1-cell load),
    #    repeater at (QBx,132) reads the stub (rear directly on the rail unbalances the latch).
    out.append(f"setblock {QBx} 101 131 minecraft:redstone_wire")
    out.append(rep(QBx, 132, "north"))       # out south (QBx,133)
    # 2. drop south QBx 133..(corr-1), reamp every ~5 incl. a CLEAN repeater at corr-2 so the
    #    comparator side input (QBx,corr-1) arrives at a full 15 (attenuation there => wrong 15-Qbar)
    out.append(vseg(QBx, 133, corr - 1))
    zs = list(range(138, corr - 1, 5))
    if (corr - 2) not in zs:
        zs.append(corr - 2)                   # clean repeater right above the comparator side
    for z in zs:
        out.append(rep(QBx, z, "north"))
    # 3. INVERT: comparator[facing=east] (rear on EAST per fork convention) at (QBx,corr):
    #    rear east=15blk(QBx+1), north side=(QBx,corr-1)=Qbar, out west=(QBx-1,corr) = 15 - Qbar = Q
    out.append(comp(QBx, corr, "east"))
    out.append(blk(QBx + 1, corr))          # 15 src placed AFTER comp so comp re-evaluates rear (else stale)
    Qsrc = QBx - 1                          # Q now at (Qsrc, corr)
    # 4. horizontal haul at z=corr from Qsrc to the dst risers
    west_x = min(Rx, Dsx, Qsrc); east_x = max(Rx, Dsx, Qsrc)
    out.append(hseg(west_x, east_x, corr))
    if Qsrc > Rx:                            # flow west: input east -> facing=east
        x = Qsrc - 8
        while x > west_x:
            out.append(rep(x, corr, "east")); x -= 8
    else:                                    # flow east: facing=west
        x = Qsrc + 8
        while x < east_x:
            out.append(rep(x, corr, "west")); x += 8
    # 5. east riser Rx from corr up to z=115 (flow north): facing=south
    out.append(vseg(Rx, 115, corr - 1))
    z = corr - 7
    while z > 118:
        out.append(rep(Rx, z, "south")); z -= 8
    # 6. D_south riser Dsx from corr up to z=136 -> D_south(Dsx,135)
    out.append(vseg(Dsx, 137, corr - 1))
    z = corr - 5
    while z > 143:
        out.append(rep(Dsx, z, "south")); z -= 8
    out.append(rep(Dsx, 136, "south"))       # final into D_south(Dsx,135)
    # 7. z=115 lane Rx -> lane_w, drop, rep -> D_north(61+dst,118)
    out.append(hseg(lane_w, Rx, 115))
    if Rx - lane_w > 8:
        out.append(rep((Rx + lane_w)//2, 115, "east"))
    out.append(vseg(lane_w, 116, 118))
    out.append(rep(lane_w + 1, 118, "west"))
    return out

def enables():
    """redstone_block coords (y=102) for phi1(master) and phi2(slave) per stage."""
    m = []; s = []
    for i in range(NST):
        dx = -STRIDE*i
        m.append((62+dx,102,117)); m.append((60+dx,102,133))
        s.append((46+dx,102,117)); s.append((44+dx,102,133))
    return m, s

if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "build"
    cmds = []
    if mode == "floor":
        cmds.append("forceload add -60 108 72 165")
        cmds.append("fill -60 100 108 72 100 165 minecraft:stone")
        cmds.append("fill -60 101 108 72 103 165 minecraft:air")
    elif mode == "ffs":
        for i in range(NST):
            cmds += ff(-STRIDE*i)
    elif mode == "links":   # 3 adjacent shift links
        for i in range(NST-1):
            cmds += link(-STRIDE*i, -STRIDE*(i+1), CORR)
    elif mode == "loop":    # Q3 -> D0
        cmds += link(-STRIDE*(NST-1), 0, LOOPCORR)
    for c in cmds:
        print(c)
