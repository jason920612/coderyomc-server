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
    o=R.cmd("time query gametime")
    m=re.search(r'(\d+)',o); return int(m.group(1)) if m else -1

def sprint(n):
    """Advance exactly n game ticks deterministically via /tick sprint, poll gametime."""
    t0=gametime(); R.cmd(f"tick sprint {n}")
    for _ in range(120):
        if gametime()>=t0+n: return
        time.sleep(0.1)
    # tick sprint may auto-stop; ensure normal rate resumes
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
    """Return redstone_wire power 0..15 at coord, or -1 if not wire."""
    for p in range(15,-1,-1):
        o=R.cmd(f"execute if block {x} {y} {z} minecraft:redstone_wire[power={p}]")
        if "passed" in o.lower(): return p
    return -1

# stage FF Q coords
def Qc(i): dx=-30*i; return (44+dx,101,122)
def Qbarc(i): dx=-30*i; return (48+dx,101,130)

def probeQ():
    return [probe(*Qc(i)) for i in range(4)]
def probeQbar():
    return [probe(*Qbarc(i)) for i in range(4)]

# enable block coords
def masters():
    r=[]
    for i in range(4):
        dx=-30*i; r+=[(62+dx,102,117),(60+dx,102,133)]
    return r
def slaves():
    r=[]
    for i in range(4):
        dx=-30*i; r+=[(46+dx,102,117),(44+dx,102,133)]
    return r

def setblk(coords,block):
    for (x,y,z) in coords: R.cmd(f"setblock {x} {y} {z} {block}")

def phase(coords,on_ticks,settle):
    setblk(coords,"minecraft:redstone_block"); sprint(on_ticks)
    setblk(coords,"minecraft:air"); sprint(settle)

def clock(on=14, gap=14, presettle=120, cycles=1, verbose=True):
    for c in range(cycles):
        sprint(presettle)                 # let D's settle from current Q's (long for loop haul)
        phase(masters(), on, gap)          # phi1: load masters from D
        phase(slaves(),  on, gap)          # phi2: load slaves from masters
        if verbose:
            q=probeQ(); print(f"  clk -> Q={q} onehot={''.join('1' if v>7 else '0' for v in q)}",flush=True)

# stage0 D injection ports (drive redstone_block above the D dust cells)
D0_PORTS=[(61,102,118),(62,102,135)]
def d0_on():  setblk(D0_PORTS,"minecraft:redstone_block")
def d0_off(): setblk(D0_PORTS,"minecraft:air")

def onehot(q): return ''.join('1' if v>7 else '0' for v in q)

def flush():
    """Drive D0=0 and clock 6x -> all stages 0000."""
    d0_off()
    for _ in range(6):
        clock(cycles=1, verbose=False)
    return probeQ()

def inject1():
    """Load a single 1 into stage0: D0=1 for exactly one clock, then release."""
    d0_on()
    clock(cycles=1, verbose=False)
    d0_off()
    return probeQ()

def init1000():
    flush(); q=inject1()
    print(f"  init -> Q={q} ({onehot(q)})",flush=True)
    return q

# --- loop-aware init: temporarily cut the loop invert's 15-source so D0 gets 0 during flush ---
LOOP_SRC=(-43,101,158)   # redstone_block feeding the loop invert comparator rear (facing=west => rear on WEST)
def loop_cut():  R.cmd(f"setblock {LOOP_SRC[0]} {LOOP_SRC[1]} {LOOP_SRC[2]} minecraft:air")
def loop_restore(): R.cmd(f"setblock {LOOP_SRC[0]} {LOOP_SRC[1]} {LOOP_SRC[2]} minecraft:redstone_block")

def init1000_loop():
    """With the loop closed: cut loop feed, flush to 0000, inject one 1, restore loop feed."""
    loop_cut()
    d0_off()
    for _ in range(6): clock(cycles=1, verbose=False)
    d0_on();  clock(cycles=1, verbose=False); d0_off()
    q=probeQ(); print(f"  init(loop) pre-restore -> Q={q} ({onehot(q)})",flush=True)
    loop_restore()
    sprint(40)
    q=probeQ(); print(f"  init(loop) post-restore -> Q={q} ({onehot(q)})",flush=True)
    return q

if __name__=="__main__":
    import sys
    a=sys.argv[1:]
    cmd=a[0]
    if cmd=="apply": print("applied",apply(a[1]))
    elif cmd=="probeq": print("Q=",probeQ(),"Qbar=",probeQbar())
    elif cmd=="raw": print(R.cmd(" ".join(a[1:])))
    elif cmd=="sprint": sprint(int(a[1])); print("gt=",gametime())
    elif cmd=="init": init1000()
    elif cmd=="shift":
        n=int(a[1]) if len(a)>1 else 4
        init1000()
        clock(cycles=n, verbose=True)
    elif cmd=="clock":
        n=int(a[1]) if len(a)>1 else 1
        clock(cycles=n, verbose=True)
    elif cmd=="d0on": d0_on(); print("D0 driven 1")
    elif cmd=="d0off": d0_off(); print("D0 released")
    elif cmd=="flush": print("flushed ->",flush())
    elif cmd=="rom":
        # b2@(15,190) b1@(9,193) b0@(3,196)
        b=[probe(32,101,190),probe(2,101,193),probe(-27,101,196)]
        print("ROM b2,b1,b0 =",b,"->",''.join('1' if v>7 else '0' for v in b))
    elif cmd=="romwalk":
        n=int(a[1]) if len(a)>1 else 8
        init1000_loop(); sprint(30)
        def rom(): return [probe(32,101,190),probe(2,101,193),probe(-27,101,196)]
        def rs(b): return ''.join('1' if v>7 else '0' for v in b)
        q=probeQ(); print(f"  init : Q={onehot(q)}  ROM={rs(rom())} {rom()}")
        for c in range(n):
            clock(cycles=1,verbose=False); sprint(30)
            q=probeQ(); r=rom()
            print(f"  clk{c+1}: Q={onehot(q)}  ROM={rs(r)} {r}")
    elif cmd=="initloop": init1000_loop()
    elif cmd=="ring":
        n=int(a[1]) if len(a)>1 else 8
        init1000_loop()
        clock(cycles=n, verbose=True)
    R.close()
