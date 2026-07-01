#!/usr/bin/env python3
# Place ONE master-slave D flip-flop (build-24 ring stage-0 geometry: master x=62, slave x=46)
# translated by (DX,DZ). Verify D-capture + clock + Q-read empirically (proven block-injection).
import re, sys, drv
R=drv.R
FFS="C:/Users/jason/Desktop/game/coderyoMC/test-harness/redstone-computer/b24src/22-ffs.txt"

def stage0_lines():
    out=[]
    for i,ln in enumerate(open(FFS,encoding="utf8")):
        if i>=63: break   # lines 1..63 = stage-0 master+slave bodies + forward interconnect
        s=ln.strip()
        if s.startswith("fill ") or s.startswith("setblock "): out.append(s)
    return out

def tr(cmd,dx,dz):
    p=cmd.split()
    if p[0]=="fill":
        p[1]=str(int(p[1])+dx);p[3]=str(int(p[3])+dz);p[4]=str(int(p[4])+dx);p[6]=str(int(p[6])+dz)
    else:
        p[1]=str(int(p[1])+dx);p[3]=str(int(p[3])+dz)
    return " ".join(p)

class FF:
    def __init__(s,dx,dz): s.dx=dx; s.dz=dz
    def P(s,x,y,z): return (x+s.dx,y,z+s.dz)
    # ports (base master 62 / slave 46)
    def Dports(s): return [s.P(61,102,118), s.P(62,102,135)]   # y=102 block => D=1
    def MasterE(s): return [s.P(62,102,117), s.P(60,102,133)]
    def SlaveE(s):  return [s.P(46,102,117), s.P(44,102,133)]
    def Q(s):  return s.P(44,101,122)
    def Qb(s): return s.P(48,101,130)
    def place(s):
        R.cmd(f"forceload add {s.dx-2} {s.dz+110} {s.dx+70} {s.dz+140}")
        R.cmd(f"fill {s.dx-2} 100 {s.dz+112} {s.dx+68} 100 {s.dz+140} minecraft:stone")
        R.cmd(f"fill {s.dx-2} 101 {s.dz+112} {s.dx+68} 103 {s.dz+140} minecraft:air")
        for c in stage0_lines(): R.cmd(tr(c,s.dx,s.dz))
    def setcells(s,cells,on):
        for (x,y,z) in cells: R.cmd(f"setblock {x} {y} {z} minecraft:"+("redstone_block" if on else "air"))
    def clock(s,settle=30):
        drv.sprint(settle)
        s.setcells(s.MasterE(),True); drv.sprint(14); s.setcells(s.MasterE(),False); drv.sprint(14)
        s.setcells(s.SlaveE(),True);  drv.sprint(14); s.setcells(s.SlaveE(),False);  drv.sprint(20)
    def setD(s,d): s.setcells(s.Dports(), bool(d))
    def q(s): return drv.bit(*s.Q())

if __name__=="__main__":
    dx=int(sys.argv[2]); dz=int(sys.argv[3]); f=FF(dx,dz)
    cmd=sys.argv[1]
    if cmd=="place": f.place(); print("placed FF at",dx,dz)
    elif cmd=="test":
        # capture D=1 then D=0, verify Q follows on clock
        f.setD(1); f.clock(); print("after D=1 clock: Q=",f.q())
        f.setD(0); f.clock(); print("after D=0 clock: Q=",f.q())
        f.setD(1); f.clock(); print("after D=1 clock: Q=",f.q())
    elif cmd=="probe":
        print("Q=",f.q(),"Qb=",drv.bit(*f.Qb()))
    R.close()
