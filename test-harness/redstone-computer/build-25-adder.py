#!/usr/bin/env python3
# Build + drive the 2-bit ripple-carry adder (build-07 tile x2 + build-08 carry interconnect).
# Placed at DZ=+360 in the cpu2 world (forceloaded 0..130 x, 300..460 z).
import re, sys, drv
R=drv.R
DZ=360
B07="C:/Users/jason/Desktop/game/coderyoMC/test-harness/redstone-computer/build-07-side-entry-cin-fulladder.txt"
B08="C:/Users/jason/Desktop/game/coderyoMC/test-harness/redstone-computer/build-08-ripple-2bit.txt"

def body_lines(path):
    out=[]
    for ln in open(path,encoding="utf8"):
        s=re.split(r"\s+#",ln.strip())[0].strip()
        if s.startswith("fill ") or s.startswith("setblock "):
            out.append(s)
    return out

def tr(cmd,dx,dz):
    p=cmd.split()
    if p[0]=="fill":
        p[1]=str(int(p[1])+dx); p[3]=str(int(p[3])+dz)
        p[4]=str(int(p[4])+dx); p[6]=str(int(p[6])+dz)
    else:
        p[1]=str(int(p[1])+dx); p[3]=str(int(p[3])+dz)
    return " ".join(p)

# build-07 body: skip its own platform fills (we lay one big platform), keep logic.
b07=[c for c in body_lines(B07) if not c.startswith("fill 2 100") and not c.startswith("fill 2 101")]
# build-08: only the CARRY INTERCONNECT lines (39-45 region: the wires between the tiles).
b08=body_lines(B08)
carry=[c for c in b08 if c not in body_lines(B08)[:2]]  # drop the two platform fills at top
# carry interconnect explicit (build-08 lines 39-45), plus we DON'T want its fixed drivers.
CARRY=[
 "fill 45 101 11 57 101 11 minecraft:redstone_wire",
 "setblock 58 101 11 minecraft:repeater[facing=west]",
 "fill 59 101 11 62 101 11 minecraft:redstone_wire",
 "fill 62 101 12 62 101 19 minecraft:redstone_wire",
 "setblock 62 101 20 minecraft:redstone_wire",
 "setblock 63 101 20 minecraft:repeater[facing=west]",
 "setblock 64 101 20 minecraft:redstone_wire",
]

# A/B driver ports (y=102 redstone_block => input 1)
A0=[(18,9),(23,10),(38,17),(44,17)]
B0=[(22,9),(19,10),(36,17),(50,17)]
A1=[(78,9),(83,10),(98,17),(104,17)]
B1=[(82,9),(79,10),(96,17),(110,17)]
CIN0=[(4,20)]  # over bus start; we keep Cin0=0 always

def place():
    cmds=[]
    cmds.append(f"forceload add 0 {2+DZ} 130 {60+DZ}")
    cmds.append(f"fill 0 100 {0+DZ} 122 100 {42+DZ} minecraft:stone")
    cmds.append(f"fill 0 101 {0+DZ} 122 103 {42+DZ} minecraft:air")
    for c in b07: cmds.append(tr(c,0,DZ))
    for c in b07: cmds.append(tr(c,60,DZ))
    for c in CARRY: cmds.append(tr(c,0,DZ))
    for i,c in enumerate(cmds):
        R.cmd(c)
    print(f"placed adder: {len(cmds)} cmds")

def drive(a,b):
    # a,b are 0..3 (2-bit). bit0=LSB.
    a0,a1=a&1,(a>>1)&1; b0,b1=b&1,(b>>1)&1
    def setp(ports,on):
        for (x,z) in ports:
            R.cmd(f"setblock {x} 102 {z+DZ} minecraft:"+("redstone_block" if on else "air"))
    setp(A0,a0); setp(A1,a1); setp(B0,b0); setp(B1,b1)
    # Cin0 = 0 always: ensure no block over (4,20)
    for (x,z) in CIN0: R.cmd(f"setblock {x} 102 {z+DZ} minecraft:air")

def read():
    s0=drv.bit(30,101,14+DZ); c0=drv.bit(44,101,11+DZ)
    cin1=drv.bit(64,101,20+DZ)
    s1=drv.bit(90,101,14+DZ); c1=drv.bit(104,101,11+DZ)
    val=s0 + (s1<<1) + (c1<<2)
    return dict(S0=s0,Cout0=c0,Cin1=cin1,S1=s1,Cout1=c1,val=val)

if __name__=="__main__":
    cmd=sys.argv[1] if len(sys.argv)>1 else "place"
    if cmd=="place": place()
    elif cmd=="drive":
        a=int(sys.argv[2]); b=int(sys.argv[3]); drive(a,b); drv.sprint(60)
        print(f"A={a} B={b} ->",read())
    elif cmd=="vectors":
        for (a,b) in [(1,1),(3,1),(2,2),(1,2),(3,3),(0,0),(2,1)]:
            drive(a,b); drv.sprint(80)
            r=read(); exp=(a+b)&3; got=r['val']&3
            print(f"A={a}+B={b}: SUM2b={got} (S1S0={r['S1']}{r['S0']}) Cout0={r['Cout0']} Cout1={r['Cout1']} exp={exp} {'OK' if got==exp else 'XX'}")
    R.close()
