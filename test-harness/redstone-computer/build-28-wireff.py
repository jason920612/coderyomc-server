#!/usr/bin/env python3
# build-28: WIRE-DRIVABLE-D master-slave flip-flop.
#   The blocker (build-27): the loop's SUM->D bridge fed only ONE master D-port (D_south),
#   leaving D_north unfed, so R=E-D_north could not fire to force Q=0 -> a wire could only OR
#   D to 1, never force 0.  FIX: feed the D INPUT WIRE (a toggleable source, emulating the
#   adder SUM) into BOTH master D-ports (D_north = R-comp side, D_south = S-comp rear) through
#   repeater-cleaned branches -- exactly the proven build-11 forward-interconnect idiom, but on
#   the MASTER's D.  Then a wire drives Q to BOTH 0 and 1 (build-10 gates: S=D&E, R=Dbar&E).
import re, sys, drv
from ff import FF
R = drv.R

class WireFF(FF):
    """FF (build-11 master-slave) whose master D is driven by an ordinary WIRE fed from a
       single toggleable source block, fanned out (repeater-cleaned) into BOTH master D-ports."""
    def Dsrc(s):  return s.P(66, 102, 140)   # block over the D source dust -> D wire = 15/0
    def Dsrc_dust(s): return s.P(66, 101, 140)
    def dnet(s):
        """Place the wire net: source dust -> two cleaned branches -> D_north & D_south.
           The master body + Q-rail + forward-interconnect bus wall off z=122 across x=50..64,
           so the only clear N-S lane is x=66 (east of the Qbar rail); D_north is then reached
           from the NORTH (z=115 row) to avoid the R-gadget and the E_north enable dust."""
        def w(x, z): R.cmd(f"setblock {x+s.dx} 101 {z+s.dz} minecraft:redstone_wire")
        def rep(x, z, f): R.cmd(f"setblock {x+s.dx} 101 {z+s.dz} minecraft:repeater[facing={f}]")
        # --- source node (66,140): a wire fed by a block above (toggled = the 'incoming SUM wire') ---
        w(66, 140)
        # --- Branch A: source -> D_south (62,135) [S-comp REAR] ---
        for x in range(62, 67): w(x, 140)          # west along z=140  x66..62
        w(62, 139); w(62, 138); w(62, 137)         # north up x=62
        rep(62, 138, "south")                       # re-amp, push north (rear=south)
        rep(62, 136, "south")                       # clean inject -> D_south (62,135)
        # --- Branch B: source -> D_north (61,118) via CLEAR x=66 lane + z=115 north row ---
        for z in range(115, 141): w(66, z)          # riser x=66  z140..115 (clear of Qbar rail x64)
        rep(66, 132, "south"); rep(66, 122, "south")   # re-amp northward
        for x in range(58, 67): w(x, 115)           # row z=115 west  x66..58 (north of R gadget)
        rep(64, 115, "east")                         # re-amp westward (rear east, out west)
        w(58, 116); w(58, 117); w(58, 118); w(59, 118)  # drop south then east to repeater rear
        rep(60, 118, "west")                         # clean inject east -> D_north (61,118)
    def setD_wire(s, d):
        (x, y, z) = s.Dsrc()
        R.cmd(f"setblock {x} {y} {z} minecraft:" + ("redstone_block" if d else "air"))
    def clock_wire(s, settle=40):
        # D already presented on the wire; settle it, then two-phase (master then slave).
        drv.sprint(settle)
        s.setcells(s.MasterE(), True);  drv.sprint(16); s.setcells(s.MasterE(), False); drv.sprint(16)
        s.setcells(s.SlaveE(), True);   drv.sprint(16); s.setcells(s.SlaveE(), False);  drv.sprint(24)

def probe_report(f):
    dn = drv.probe(*f.P(61,101,118)); ds = drv.probe(*f.P(62,101,135))
    src = drv.probe(*f.Dsrc_dust())
    print(f"  D_src={src} D_north={dn} D_south={ds} Q={f.q()} Qbar={drv.bit(*f.Qb())}")

if __name__ == "__main__":
    dx = int(sys.argv[2]); dz = int(sys.argv[3]); f = WireFF(dx, dz)
    cmd = sys.argv[1]
    if cmd == "place":
        f.place(); f.dnet()
        # ensure ff.py block D-ports are AIR (D comes ONLY from the wire)
        for c in f.Dports(): R.cmd(f"setblock {c[0]} {c[1]} {c[2]} minecraft:air")
        f.setD_wire(0)
        print("placed WireFF at", dx, dz)
    elif cmd == "test":
        print("== wire-drive test: force D via wire only, clock, read Q ==")
        for d in [0, 1, 0, 1, 1, 0]:
            f.setD_wire(d); f.clock_wire()
            q = f.q()
            print(f"  set D_wire={d} -> Q={q}  {'OK' if q==d else 'XX'}")
            probe_report(f)
    elif cmd == "hold":
        d = int(sys.argv[4]); f.setD_wire(d); f.clock_wire(); drv.sprint(40)
        print(f"held D={d}: Q={f.q()}"); probe_report(f)
    elif cmd == "probe":
        probe_report(f)
    elif cmd == "difftest":
        (qx,qy,qz) = f.Q(); t = sys.argv[4] if len(sys.argv)>4 else "200"
        print(R.cmd(f"coderyo redstone difftest {qx} {qy} {qz} {t}"))
    R.close()
