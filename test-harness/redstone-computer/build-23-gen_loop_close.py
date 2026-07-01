#!/usr/bin/env python3
# Corrected loop link Q3 -> D0 for the ring counter.
# FIX vs build-22 gen_ring.py `loop` mode: for an EASTWARD haul the original
# `fill west..east` overwrote the invert comparator (at QBx) and its rear 15-block
# (at QBx+1), destroying the inversion (D0 became Qbar3, stuck high -> 1111 fill).
# Here the invert comparator faces WEST (rear 15-block on the WEST, output EAST),
# so the eastward haul starts EAST of the comparator and never overwrites it.
# Re-amp the drop AND the haul every <=5 (discovered rule); 15-source placed AFTER
# the comparator so it re-evaluates its rear each clock.
CORR = 158
QBx  = 48 - 90        # stage3 Slave.Qbar rail x = -42
Rx   = 66            # dest (stage0) east riser x
Dsx  = 62            # dest D_south riser x
lane_w = 59         # z=115 lane west end / D_north drop x

out = []
def w(s): out.append(s)

# 1. tap Qbar3 via isolating 1-dust stub + repeater (rear directly on rail unbalances latch)
w(f"setblock {QBx} 101 131 minecraft:redstone_wire")
w(f"setblock {QBx} 101 132 minecraft:repeater[facing=north]")   # out south -> 133
# 2. drop south 133..CORR-1, re-amp every <=5 so comparator side sees a clean 15
w(f"fill {QBx} 101 133 {QBx} 101 {CORR-1} minecraft:redstone_wire")
for z in range(138, CORR-1, 5):
    w(f"setblock {QBx} 101 {z} minecraft:repeater[facing=north]")
if (CORR-2) not in range(138, CORR-1, 5):
    w(f"setblock {QBx} 101 {CORR-2} minecraft:repeater[facing=north]")   # clean re-amp right above comp side
# 3. INVERT: comparator faces WEST -> rear(15) on WEST (QBx-1), side(north)=drop(QBx,CORR-1),
#    output EAST at (QBx+1,CORR) = 15 - Qbar3 = Q3.
w(f"setblock {QBx} 101 {CORR} minecraft:comparator[facing=west,mode=subtract]")
w(f"setblock {QBx-1} 101 {CORR} minecraft:redstone_block")   # 15 src AFTER comparator (re-eval rear)
Qsrc = QBx + 1   # Q3 now here (-41), haul EAST from here
# 4. horizontal haul EAST from Qsrc to Rx at z=CORR. Signal is already Q3 (0 or 15) so
#    re-amp SPARSELY (every 12 < 15 dust-decay limit) to MINIMISE repeater DELAY on this
#    ~110-cell loop haul (delay, not strength, is the loop's constraint). facing=west => out east.
#    Skip the two riser-tap columns (Dsx, Rx) so the taps read plain dust.
w(f"fill {Qsrc} 101 {CORR} {Rx} 101 {CORR} minecraft:redstone_wire")
x = Qsrc + 12
while x < Rx:
    if x not in (Dsx, Rx):
        w(f"setblock {x} 101 {CORR} minecraft:repeater[facing=west]")
    x += 12
# 5. east riser Rx up to z=115 lane (facing=south => out north/up), sparse re-amp
w(f"fill {Rx} 101 115 {Rx} 101 {CORR-1} minecraft:redstone_wire")
z = CORR-3
while z > 118:
    w(f"setblock {Rx} 101 {z} minecraft:repeater[facing=south]")
    z -= 12
# 6. D_south riser Dsx up to z=136 -> D_south(Dsx,135), sparse re-amp
w(f"fill {Dsx} 101 137 {Dsx} 101 {CORR-1} minecraft:redstone_wire")
z = CORR-4
while z > 141:
    w(f"setblock {Dsx} 101 {z} minecraft:repeater[facing=south]")
    z -= 12
w(f"setblock {Dsx} 101 136 minecraft:repeater[facing=south]")   # final into D_south(Dsx,135)
# 7. z=115 lane Rx -> lane_w, drop, rep -> D_north(61,118)
w(f"fill {lane_w} 101 115 {Rx} 101 115 minecraft:redstone_wire")
w(f"setblock {(Rx+lane_w)//2} 101 115 minecraft:repeater[facing=east]")   # out west
w(f"fill {lane_w} 101 116 {lane_w} 101 118 minecraft:redstone_wire")
w(f"setblock {lane_w+1} 101 118 minecraft:repeater[facing=west]")         # -> D_north (61,118)

print("\n".join(out))
