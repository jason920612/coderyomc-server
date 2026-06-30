#!/usr/bin/env python3
"""Analyze a LOD soak run: MSPT drift, GC/heap leak-watch, TPS, LOD fidelity (per-class tally),
contraption-cadence stability, stability (crashes/single-writer). Usage: analyze-soak.py <run-dir>"""
import sys, os, re

run = sys.argv[1]
log = os.path.join(run, "server.log")
gc  = os.path.join(run, "gc.log")
ANSI = re.compile(r'\x1b\[[0-9;]*m')

def clean(p):
    if not os.path.exists(p): return []
    with open(p, encoding="utf-8", errors="replace") as f:
        return [ANSI.sub('', ln.rstrip('\n')) for ln in f]

L = clean(log)

# ---- window markers + per-sample MSPT/TPS time series ----
win_start = win_end = None
samples = []   # (elapsed_s, mspt_avg, mspt_max, tps)
cur_t = None
pend_mspt = None       # set when "Server tick times" header seen; filled by NEXT value line
want_value = False
TRIPLE = re.compile(r'([0-9]+\.[0-9]+)/([0-9]+\.[0-9]+)/([0-9]+\.[0-9]+)')
for ln in L:
    m = re.search(r'===SOAK_T (\d+) (\d+)===', ln)
    if m: cur_t = int(m.group(1)); continue
    if '===SOAK_WINDOW_START' in ln:
        win_start = int(re.search(r'START (\d+)', ln).group(1)); continue
    if '===SOAK_WINDOW_END' in ln:
        win_end = int(re.search(r'END (\d+)', ln).group(1)); continue
    if 'Server tick times' in ln:
        want_value = True
        continue
    if want_value:
        # value line is the NEXT line: "? 146.9/20.8/1697.3, 210.7/..., 155.8/..."
        t = TRIPLE.search(ln)
        if t:
            pend_mspt = (float(t.group(1)), float(t.group(3)))  # 5s avg, 5s max
            want_value = False
        # if this line wasn't the value line, keep waiting one more
        else:
            continue
    mt = re.search(r'TPS from last .*?: ?\*?([0-9]+\.[0-9]+)', ln)
    if mt and pend_mspt is not None and cur_t is not None:
        samples.append((cur_t, pend_mspt[0], pend_mspt[1], float(mt.group(1))))
        pend_mspt = None

def lin(xs, ys):
    n=len(xs)
    if n<2: return 0.0,0.0
    mx=sum(xs)/n; my=sum(ys)/n
    den=sum((x-mx)**2 for x in xs)
    if den==0: return 0.0,my
    sl=sum((x-mx)*(y-my) for x,y in zip(xs,ys))/den
    return sl, my

# drop warmup: samples with elapsed < WARMUP seconds (spawn-storm recovery)
WARMUP = int(os.environ.get("WARMUP", "120"))
S = [s for s in samples if s[0] >= WARMUP] or samples[2:]
ts  = [s[0] for s in S]
av  = [s[1] for s in S]
mx  = [s[2] for s in S]
tp  = [s[3] for s in S]

print("="*70)
print("LOD SOAK ANALYSIS:", run)
print("="*70)
if win_start and win_end:
    print(f"measured window: {win_end-win_start}s ({(win_end-win_start)/60.0:.1f} min)")
print(f"MSPT samples (post-warmup): {len(S)}")
if S:
    slope, mean = lin(ts, av)          # ms per second
    drift_per_min = slope*60.0
    first3 = sum(av[:3])/min(3,len(av))
    last3  = sum(av[-3:])/min(3,len(av))
    print(f"\n--- 1) MSPT / TPS DRIFT ---")
    print(f"MSPT 5s-avg: mean={mean:.2f}ms  first3={first3:.2f}  last3={last3:.2f}  "
          f"min={min(av):.2f}  max={max(av):.2f}")
    print(f"MSPT drift slope = {drift_per_min:+.4f} ms/min  "
          f"(over {(ts[-1]-ts[0])/60.0:.1f} min => {drift_per_min*(ts[-1]-ts[0])/60.0:+.2f} ms total)")
    print(f"MSPT max-column: mean={sum(mx)/len(mx):.2f}  max={max(mx):.2f}")
    tpv=[t for t in tp if t>0]
    if tpv:
        print(f"TPS: mean={sum(tpv)/len(tpv):.2f}  min={min(tpv):.2f}  "
              f"held20={sum(1 for t in tpv if t>=19.5)}/{len(tpv)}")

# ---- 2) GC / heap leak watch ----
print(f"\n--- 2) GC / HEAP LEAK-WATCH ---")
G = clean(gc)
gcs = []  # (uptime_s, before_M, after_M, total_M)
for ln in G:
    # [2.345s][...] GC(12) Pause Young (...) 512M->128M(3072M) 4.5ms     (or K/G units)
    um = re.search(r'\[([0-9.]+)s\]', ln)
    hm = re.search(r'(\d+)([KMG])->(\d+)([KMG])\((\d+)([KMG])\)', ln)
    if um and hm:
        def MB(v,u):
            v=float(v); return v/1024 if u=='K' else (v*1024 if u=='G' else v)
        gcs.append((float(um.group(1)), MB(hm.group(1),hm.group(2)),
                    MB(hm.group(3),hm.group(4)), MB(hm.group(5),hm.group(6))))
fulls=[ln for ln in G if 'Pause Full' in ln]
if gcs:
    afters=[g[2] for g in gcs]; ut=[g[0] for g in gcs]
    sl,mn = lin(ut, afters)
    # post-GC live-set floor over time buckets (leak = floor rises)
    print(f"GC events: {len(gcs)}  (Full GCs: {len(fulls)})")
    print(f"post-GC used-heap: first={afters[0]:.0f}MB  last={afters[-1]:.0f}MB  "
          f"min={min(afters):.0f}  max={max(afters):.0f}  mean={sum(afters)/len(afters):.0f}MB")
    print(f"post-GC heap slope = {sl*60:+.3f} MB/min  "
          f"(over {(ut[-1]-ut[0])/60.0:.1f} min => {sl*(ut[-1]-ut[0])/60.0:+.0f}MB total)")
    # bucketed floor (live set): min after-heap in 5 equal time buckets
    if len(gcs)>=10:
        lo,hi=ut[0],ut[-1]; nb=5; buckets=[[] for _ in range(nb)]
        for u,_,a,_ in gcs:
            i=min(nb-1,int((u-lo)/((hi-lo)/nb+1e-9))); buckets[i].append(a)
        floors=[min(b) if b else float('nan') for b in buckets]
        print("post-GC live-set floor by 1/5 buckets (MB): " +
              "  ".join(f"{f:.0f}" for f in floors))
else:
    print("no parseable GC events (gc.log empty or format mismatch)")

# ---- 3/4) LOD fidelity + contraption cadence: per-class skip tally over time ----
print(f"\n--- 3/4) LOD FIDELITY + CONTRAPTION CADENCE (per-class skip tally) ---")
cls = [ln for ln in L if 'CLASS tally' in ln or ('tally' in ln.lower() and ('HOSTILE' in ln or 'EXEMPT' in ln))]
def parse_cls(ln):
    out={}
    for k in ('EXEMPT','PASSIVE','HOSTILE'):
        m=re.search(k+r'[^0-9]*ran[=: ]*([0-9]+)[^0-9]*skip[=: ]*([0-9]+)', ln, re.I)
        if not m:
            m=re.search(k+r'[^0-9]*([0-9]+)\s*/\s*([0-9]+)', ln)
        if m:
            ran=int(m.group(1)); sk=int(m.group(2)); tot=ran+sk
            out[k]=(sk/tot if tot else 0.0, tot)
    # also a generic skip%% form
    return out
if cls:
    # filter to lines with actual ticking (ran>0 somewhere) -> skip the startup ran=0 line
    real = [ln for ln in cls if 'skip%=-' not in ln and 'ran=0,' not in ln]
    use = real or cls
    print(f"CLASS tally lines: {len(cls)} (non-startup: {len(real)})")
    for ln in [use[0], use[len(use)//2], use[-1]]:
        print("  " + ln.strip()[-150:])
    # cumulative counters: report first(real) & last skip%; EXEMPT must stay 0.000 throughout
    p0=parse_cls(use[0]); p1=parse_cls(use[-1])
    for k in ('EXEMPT','PASSIVE','HOSTILE'):
        if k in p0 and k in p1:
            print(f"  {k}: skip% start={p0[k][0]:.3f} end={p1[k][0]:.3f}")
    # any EXEMPT line with skip>0 = contraption cadence violation
    bad = [ln for ln in use if re.search(r'EXEMPT\(ran=[0-9]+,skip=([1-9][0-9]*)', ln)]
    print(f"  EXEMPT non-zero-skip lines (cadence violations): {len(bad)}")
else:
    # fall back to DAB throttle tally
    dab=[ln for ln in L if 'DAB throttle tally' in ln or 'throttle tally' in ln.lower()]
    print(f"no CLASS tally; DAB tally lines: {len(dab)}")
    for ln in dab[-3:]: print("  "+ln.strip()[-160:])

# frozen-mob / runaway hints
froz = [ln for ln in L if 'stuck' in ln.lower() and 'coderyo' in ln.lower()]
if froz: print(f"  stuck-related coderyo lines: {len(froz)}")

# ---- 5) STABILITY ----
print(f"\n--- 5) STABILITY ---")
def cnt(pat): return sum(1 for ln in L if re.search(pat, ln))
print(f"crashes(Exception ticking/region tick failed/NoSuchElement/Reported): "
      f"{cnt(r'NoSuchElementException|ReportedException|Exception ticking|region tick failed|chunkSystemCrash')}")
print(f"AsyncCatcher: {cnt(r'AsyncCatcher')}   NPE: {cnt(r'NullPointerException')}   "
      f"single-writer: {cnt(r'single-writer')}")
print(f"watchdog/thread-dump: {cnt(r'thread dump|Watchdog|did the system time change')}")
print(f"clean shutdown ('All dimensions are saved'): {cnt(r'All dimensions are saved')}")
fin = [ln for ln in L if re.search(r'There are [0-9]+', ln)]
if fin: print(f"final /list: {fin[-1].strip()[-100:]}")
wk = [ln for ln in L if 'coderyo-region-worker' in ln]
print(f"region-worker thread lines: {len(wk)}")
print("="*70)
