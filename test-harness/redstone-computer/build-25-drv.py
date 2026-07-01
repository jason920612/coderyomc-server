#!/usr/bin/env python3
# RCON driver for the cpu2 server (port 15568, RCON 25581, pw cpu2).
import socket, struct, sys, time, re
HOST, PORT, PW = "localhost", 25581, "cpu2"

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
    for _ in range(200):
        if gametime()>=t0+n: return
        time.sleep(0.1)
    R.cmd("tick sprint stop")
def probe(x,y,z):
    for p in range(15,-1,-1):
        o=R.cmd(f"execute if block {x} {y} {z} minecraft:redstone_wire[power={p}]")
        if "passed" in o.lower() or "test passed" in o.lower(): return p
    return -1
def setb(x,y,z,b): return R.cmd(f"setblock {x} {y} {z} {b}")
def bit(x,y,z):
    v=probe(x,y,z); return 1 if v>7 else 0

if __name__=="__main__":
    for c in sys.argv[1:]:
        print(">>",c); print("  ",R.cmd(c))
    R.close()
