#!/usr/bin/env python3
"""chunk_diff.py <regionDirA> <regionDirB>
Identify which chunks differ between two generated worlds and WHICH component
(status / blocks / heightmaps / biomes) drives the difference. Diagnostic for
issue #8 worldgen-determinism investigation."""
import sys, os, glob, struct, hashlib
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import terrain_digest as td

def load(regdir):
    chunks = {}
    for path in sorted(glob.glob(os.path.join(regdir, "r.*.mca"))):
        for ch in td.iter_chunks(path):
            x = ch.get("xPos"); z = ch.get("zPos")
            if x is None or z is None:
                continue
            st = ch.get("Status", "")
            if not (isinstance(st, str) and st.endswith("full")):
                continue  # only compare fully-generated chunks
            chunks[(int(x), int(z))] = ch
    return chunks

def comp_hashes(ch):
    """Return dict of component -> hash, to localize the difference."""
    out = {}
    out["status"] = str(ch.get("Status", ""))
    # blocks
    bparts = []
    secs = ch.get("sections") or []
    for sec in sorted(secs, key=lambda s: s.get("Y",0) if isinstance(s,dict) else 0):
        if not isinstance(sec, dict): continue
        bs = sec.get("block_states")
        if isinstance(bs, dict):
            for e in bs.get("palette", []):
                bparts.append(td._palette_key(e)); bparts.append(b",")
            d = bs.get("data")
            if isinstance(d, list):
                bparts.append(struct.pack(">%dq"%len(d), *d))
    out["blocks"] = hashlib.sha256(b"".join(bparts)).hexdigest()[:12]
    # heightmaps
    hparts = []
    hm = ch.get("Heightmaps")
    if isinstance(hm, dict):
        for k in sorted(hm.keys()):
            v = hm[k]
            if isinstance(v, list):
                hparts.append(k.encode()); hparts.append(struct.pack(">%dq"%len(v), *v))
    out["heightmaps"] = hashlib.sha256(b"".join(hparts)).hexdigest()[:12]
    # biomes
    biparts = []
    for sec in secs:
        if not isinstance(sec, dict): continue
        bi = sec.get("biomes")
        if isinstance(bi, dict):
            for e in bi.get("palette", []):
                biparts.append((e if isinstance(e,str) else repr(e)).encode()); biparts.append(b",")
            d = bi.get("data")
            if isinstance(d, list):
                biparts.append(struct.pack(">%dq"%len(d), *d))
    out["biomes"] = hashlib.sha256(b"".join(biparts)).hexdigest()[:12]
    return out

def main():
    A = load(sys.argv[1]); B = load(sys.argv[2])
    keys = sorted(set(A) | set(B))
    diff_count = 0
    comp_tally = {}
    diff_coords = []
    for k in keys:
        if k not in A or k not in B:
            print("  ONLY in %s: chunk %s" % ("A" if k in A else "B", k))
            diff_count += 1
            continue
        ca, cb = comp_hashes(A[k]), comp_hashes(B[k])
        if ca == cb:
            continue
        diff_count += 1
        diff_coords.append(k)
        comps = [c for c in ca if ca[c] != cb[c]]
        for c in comps:
            comp_tally[c] = comp_tally.get(c, 0) + 1
        if len(diff_coords) <= 20:
            print("  DIFF chunk %s : %s" % (k, ", ".join(
                "%s(A=%s B=%s)" % (c, ca[c], cb[c]) for c in comps)))
    print("---")
    print("total chunks A=%d B=%d ; differing=%d" % (len(A), len(B), diff_count))
    print("component-difference tally: %s" % comp_tally)
    if diff_coords:
        xs = [c[0] for c in diff_coords]; zs = [c[1] for c in diff_coords]
        print("diff-chunk x range [%d..%d], z range [%d..%d]" % (min(xs),max(xs),min(zs),max(zs)))
        # how many diff chunks are on the forceloaded interior vs edge?
        print("diff coords: %s" % sorted(diff_coords))

if __name__ == "__main__":
    main()
