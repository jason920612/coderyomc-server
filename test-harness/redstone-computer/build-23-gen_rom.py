#!/usr/bin/env python3
# One-hot ROM fetch walk for the ring-counter PC (NO decoder).  v2: crossing-free geometry.
# Each ring stage Q_i selects word_i; output bit_j = OR over i of (Q_i AND word_i[j]).
# Words (consecutive-ones so the one-hot OR-matrix routes with ZERO wire crossings):
#   Q0=100  Q1=110  Q2=011  Q3=001   (bits b2 b1 b0)
#   => b2 driven by {Q0,Q1}, b1 by {Q1,Q2}, b0 by {Q2,Q3}  (each = adjacent stage pair)
# As the ring walks Q0->Q1->Q2->Q3->Q0 the ROM output walks 100->110->011->001->100.
#
# Q_i is repeater-TAPPED off each link's invert output (=Q_i) and dropped STRAIGHT DOWN in
# its own x-column (columns are the tap x's, 30 apart -> never adjacent, no corridors, no
# crossing). Q0/Q1/Q2 taps sit NORTH of the loop haul (z=158) so their drops cross it via a
# Y-bridge (dust climbs to y=103 over the haul dust and back); Q3's tap is already on the haul.
# Each output bus spans between its two (adjacent) source columns and taps them via side
# injector repeaters (diode-OR); buses at distinct z never touch.  Floor extended to z=205.
out=[]
def w(s): out.append(s)
def fillx(x1,x2,z): a,b=min(x1,x2),max(x1,x2); w(f"fill {a} 101 {z} {b} 101 {z} minecraft:redstone_wire")
def fillz(x,z1,z2): a,b=min(z1,z2),max(z1,z2); w(f"fill {x} 101 {a} {x} 101 {b} minecraft:redstone_wire")
def rep(x,z,f): w(f"setblock {x} 101 {z} minecraft:repeater[facing={f}]")

HAUL_Z=158
def bridge(x):
    # Y-bridge carrying a north-south dust OVER the loop haul dust at (x,101,158).
    w(f"setblock {x} 101 157 minecraft:stone");  w(f"setblock {x} 102 157 minecraft:redstone_wire")
    w(f"setblock {x} 102 158 minecraft:stone");  w(f"setblock {x} 103 158 minecraft:redstone_wire")
    w(f"setblock {x} 101 159 minecraft:stone");  w(f"setblock {x} 102 159 minecraft:redstone_wire")

BUS_Z={190,193,196}   # injectors side-read the column here -> must stay plain dust
def reamp_z(x, z1, z2, face, step=4):
    fillz(x, z1, z2)
    z=min(z1,z2)+step
    while z<max(z1,z2):
        zz = z-1 if z in BUS_Z else z    # nudge re-amp off a bus tap row
        rep(x,zz,face); z+=step

def deliver(tap_x, tap_z, extent_z):
    # tap branch repeater (reads invert out, outputs south=15), straight drop to extent_z,
    # bridging the loop haul if the tap is north of it.
    rep(tap_x, tap_z+1, "north")
    if tap_z < HAUL_Z < extent_z:
        reamp_z(tap_x, tap_z+2, HAUL_Z-2, "north")       # ...156
        bridge(tap_x)                                    # 156 ^157 ^158 v159
        w(f"setblock {tap_x} 101 {HAUL_Z+2} minecraft:redstone_wire")  # 160 landing
        rep(tap_x, HAUL_Z+3, "north")                    # 161 re-amp
        reamp_z(tap_x, HAUL_Z+4, extent_z, "north")      # 162..extent
    else:
        reamp_z(tap_x, tap_z+2, extent_z, "north")

# columns = tap x's ; extents = southernmost target bus z
deliver(47, 145, 190)   # Q0 -> b2(190)
deliver(17, 145, 193)   # Q1 -> b2,b1(193)
deliver(-13,145, 196)   # Q2 -> b1,b0(196)
deliver(-41,158, 196)   # Q3 -> b0(196)

# --- buses (diode-OR): each bus = two re-amped half-lines from its two source columns,
#     meeting at a central read cell M.  Injector reads a column (rear) -> re-amp toward M. ---
def reamp_x(x1,x2,z,face,step=8):
    fillx(x1,x2,z)
    x=min(x1,x2)+step
    while x<max(x1,x2): rep(x,z,face); x+=step
def bus(z, cW, cE):
    M=(cW+cE)//2
    rep(cE-1, z, "east"); reamp_x(cE-2, M, z, "east")    # east source cE -> flows west to M
    rep(cW+1, z, "west"); reamp_x(cW+2, M, z, "west")    # west source cW -> flows east to M
    return M
bus(190, 17, 47)    # b2 read M=32
bus(193, -13, 17)   # b1 read M=2
bus(196, -41, -13)  # b0 read M=-27

print("\n".join(out))
