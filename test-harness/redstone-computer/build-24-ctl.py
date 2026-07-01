import socket, struct, sys, time, re
HOST, PORT, PW = "localhost", 25579, "ring2"
class RCON:
    def __init__(s): s.sock=None; s.rid=0
    def connect(s):
        s.sock=socket.create_connection((HOST,PORT),timeout=30); s.sock.settimeout(30); s.rid=0
        s._send(3,PW); s._recv()
    def _send(s,t,p):
        s.rid+=1; d=struct.pack('<ii',s.rid,t)+p.encode('utf8')+b'\x00\x00'
        s.sock.sendall(struct.pack('<i',len(d))+d); return s.rid
    def _ra(s,n):
        b=b''
        while len(b)<n:
            c=s.sock.recv(n-len(b))
            if not c: raise ConnectionError("closed")
            b+=c
        return b
    def _recv(s):
        (l,)=struct.unpack('<i',s._ra(4)); d=s._ra(l); return d[8:-2].decode('utf8','replace')
    def cmd(s,c):
        for a in range(4):
            try: s._send(2,c); return s._recv()
            except Exception:
                time.sleep(0.5)
                try: s.connect()
                except Exception: time.sleep(1)
        return "ERR"
    def close(s):
        try: s.sock.close()
        except: pass
R=RCON(); R.connect()

def gametime():
    o=R.cmd("time query gametime"); m=re.search(r'(\d+)',o); return int(m.group(1)) if m else -1
def sprint(n):
    t0=gametime(); R.cmd(f"tick sprint {n}")
    for _ in range(120):
        if gametime()>=t0+n: return
        time.sleep(0.1)
    R.cmd("tick sprint stop")
def apply(path):
    n=0
    with open(path,encoding='utf8') as f:
        for ln in f:
            ln=ln.strip()
            if not ln or ln.startswith('#'): continue
            R.cmd(ln); n+=1
    return n
def probe(x,y,z):
    for p in range(15,-1,-1):
        o=R.cmd(f"execute if block {x} {y} {z} minecraft:redstone_wire[power={p}]")
        if "passed" in o.lower(): return p
    return -1

# ring stage coords
def Qc(i): dx=-30*i; return (44+dx,101,122)
def probeQ(): return [probe(*Qc(i)) for i in range(4)]
def onehot(q): return ''.join('1' if v>7 else '0' for v in q)

# ring enable blocks
def ring_masters():
    r=[]
    for i in range(4):
        dx=-30*i; r+=[(62+dx,102,117),(60+dx,102,133)]
    return r
def ring_slaves():
    r=[]
    for i in range(4):
        dx=-30*i; r+=[(46+dx,102,117),(44+dx,102,133)]
    return r

# --- accumulator FF (DX=-80, DZ=+100) ---
DX,DZ=-80,100
def tX(x): return x+DX
def tZ(z): return z+DZ
ACC_MASTERS=[(tX(62),102,tZ(117)),(tX(60),102,tZ(133))]
ACC_SLAVES =[(tX(46),102,tZ(117)),(tX(44),102,tZ(133))]
ACC_Q=(tX(44),101,tZ(122))          # (-36,101,222)
ACC_QBAR=(tX(48),101,tZ(130))       # (-32,101,230)
M_CELL=(tX(47),101,tZ(145))         # (-33,101,245)
# ROM read cells
ROM_B=[(32,101,190),(2,101,193),(-27,101,196)]

INCLUDE_ACC=True
def masters(): return ring_masters()+(ACC_MASTERS if INCLUDE_ACC else [])
def slaves():  return ring_slaves()+(ACC_SLAVES if INCLUDE_ACC else [])

def setblk(coords,block):
    for (x,y,z) in coords: R.cmd(f"setblock {x} {y} {z} {block}")
def phase(coords,on,settle):
    setblk(coords,"minecraft:redstone_block"); sprint(on)
    setblk(coords,"minecraft:air"); sprint(settle)
def clock(on=14,gap=14,presettle=120,cycles=1,verbose=True):
    for c in range(cycles):
        sprint(presettle)
        phase(masters(),on,gap)
        phase(slaves(),on,gap)
        if verbose:
            q=probeQ(); print(f"  clk -> Q={q} onehot={onehot(q)}",flush=True)

# stage0 D injection (ring init)
D0_PORTS=[(61,102,118),(62,102,135)]
def d0_on(): setblk(D0_PORTS,"minecraft:redstone_block")
def d0_off(): setblk(D0_PORTS,"minecraft:air")
LOOP_SRC=(-43,101,158)
def loop_cut(): R.cmd(f"setblock {LOOP_SRC[0]} {LOOP_SRC[1]} {LOOP_SRC[2]} minecraft:air")
def loop_restore(): R.cmd(f"setblock {LOOP_SRC[0]} {LOOP_SRC[1]} {LOOP_SRC[2]} minecraft:redstone_block")

def init1000_loop():
    loop_cut(); d0_off()
    for _ in range(6): clock(cycles=1,verbose=False)
    d0_on(); clock(cycles=1,verbose=False); d0_off()
    loop_restore(); sprint(40)
    q=probeQ(); print(f"  init(loop) -> Q={onehot(q)}",flush=True); return q

def rom(): return [probe(*c) for c in ROM_B]
def rs(b): return ''.join('1' if v>7 else '0' for v in b)
def acc(): return probe(*ACC_Q)
def accbit(): return 1 if acc()>7 else 0

# accumulator D-port manual drive (for FF standalone test)
DN=(tX(61),102,tZ(118)); DS=(tX(62),102,tZ(135))
def accd_on(): setblk([DN,DS],"minecraft:redstone_block")
def accd_off(): setblk([DN,DS],"minecraft:air")
def M_on(): R.cmd(f"setblock {M_CELL[0]} 102 {M_CELL[2]} minecraft:redstone_block")
def M_off(): R.cmd(f"setblock {M_CELL[0]} 102 {M_CELL[2]} minecraft:air")

if __name__=="__main__":
    a=sys.argv[1:]; c=a[0]
    if c=="apply": print("applied",apply(a[1]))
    elif c=="raw": print(R.cmd(" ".join(a[1:])))
    elif c=="sprint": sprint(int(a[1])); print("gt",gametime())
    elif c=="probeq": print("Q",probeQ(),"acc",acc(),"qbar",probe(*ACC_QBAR),"M",probe(*M_CELL))
    elif c=="rom": print("ROM",rs(rom()),rom())
    elif c=="fftest":
        # standalone FF: drive D ports, clock (acc only), read Q
        print("D=1..."); accd_on();
        # clock ONLY the accumulator
        sprint(20); phase(ACC_MASTERS,14,14); phase(ACC_SLAVES,14,14); sprint(10)
        print(" after D=1 clk: acc=",acc())
        accd_off(); sprint(10)
        phase(ACC_MASTERS,14,14); phase(ACC_SLAVES,14,14); sprint(10)
        print(" after D=0 clk: acc=",acc())
    elif c=="run":
        n=int(a[1]) if len(a)>1 else 8
        init1000_loop(); sprint(30)
        q=probeQ(); r=rom(); print(f"  init : Q={onehot(q)} ROM={rs(r)} ACC={accbit()}")
        for k in range(n):
            clock(cycles=1,verbose=False); sprint(30)
            q=probeQ(); r=rom(); print(f"  clk{k+1}: Q={onehot(q)} ROM={rs(r)} ACC={accbit()}  (raw acc={acc()})")
    R.close()
