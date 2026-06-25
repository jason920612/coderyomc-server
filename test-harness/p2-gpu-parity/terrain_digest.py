#!/usr/bin/env python3
"""
terrain_digest.py -- deterministic digest of a generated Minecraft world's
terrain, computed straight off the real `.mca` region files the server wrote.

Used by the worldgen-determinism e2e (issue #8): boot a server with a fixed
seed, forceload + fully generate a fixed area, stop, then digest the resulting
region files. Two fresh boots with the same seed must produce the SAME digest
if worldgen is deterministic.

This is mock-free: it parses the REAL production world output (the Anvil region
files), not a model. Only the Java stdlib-equivalent (zlib/struct) is used --
no third-party NBT library, so it runs anywhere Python 3 is present.

WHAT IS HASHED (deterministic terrain content only):
  - per chunk-section: the block_states palette (block names + properties) and
    the packed block-state index data, plus the biomes palette + data.
  - chunk Status (so we only digest fully-generated chunks).
  - the heightmaps (WORLD_SURFACE / OCEAN_FLOOR) when present.

WHAT IS DELIBERATELY IGNORED (volatile, non-terrain, run-to-run noise):
  - InhabitedTime, LastUpdate, isLightOn, block_ticks/fluid_ticks scheduling,
  - block_entities, entities, structures bookkeeping, sky/block light arrays.
These vary with ticking/timing and are not "the generated terrain".

Usage:
    terrain_digest.py <region-dir> [--region-dir DIR ...] [--verbose]
    terrain_digest.py <world-dir>            # auto-finds <world>/region

Output: one line  TERRAIN_DIGEST <sha256>  plus a per-chunk count summary.
Exit 0 on success, non-zero if no chunks were found.
"""

import sys
import os
import zlib
import struct
import hashlib
import glob

# ---------------------------------------------------------------------------
# Minimal NBT reader (big-endian, Java edition). Returns nested python objects.
# Tag IDs per https://minecraft.wiki/w/NBT_format .
# ---------------------------------------------------------------------------

class _Reader:
    __slots__ = ("b", "i")
    def __init__(self, b):
        self.b = b
        self.i = 0
    def u1(self):
        v = self.b[self.i]; self.i += 1; return v
    def i1(self):
        v = struct.unpack_from(">b", self.b, self.i)[0]; self.i += 1; return v
    def i2(self):
        v = struct.unpack_from(">h", self.b, self.i)[0]; self.i += 2; return v
    def u2(self):
        v = struct.unpack_from(">H", self.b, self.i)[0]; self.i += 2; return v
    def i4(self):
        v = struct.unpack_from(">i", self.b, self.i)[0]; self.i += 4; return v
    def i8(self):
        v = struct.unpack_from(">q", self.b, self.i)[0]; self.i += 8; return v
    def f4(self):
        v = struct.unpack_from(">f", self.b, self.i)[0]; self.i += 4; return v
    def f8(self):
        v = struct.unpack_from(">d", self.b, self.i)[0]; self.i += 8; return v
    def s(self):
        n = self.u2()
        v = self.b[self.i:self.i + n].decode("utf-8", "replace"); self.i += n; return v


def _read_payload(r, tid):
    if tid == 1:   # byte
        return r.i1()
    if tid == 2:   # short
        return r.i2()
    if tid == 3:   # int
        return r.i4()
    if tid == 4:   # long
        return r.i8()
    if tid == 5:   # float
        return r.f4()
    if tid == 6:   # double
        return r.f8()
    if tid == 7:   # byte array
        n = r.i4()
        v = r.b[r.i:r.i + n]; r.i += n; return bytes(v)
    if tid == 8:   # string
        return r.s()
    if tid == 9:   # list
        et = r.u1(); n = r.i4()
        return [_read_payload(r, et) for _ in range(n)]
    if tid == 10:  # compound
        d = {}
        while True:
            t = r.u1()
            if t == 0:
                break
            name = r.s()
            d[name] = _read_payload(r, t)
        return d
    if tid == 11:  # int array
        n = r.i4()
        v = struct.unpack_from(">%di" % n, r.b, r.i); r.i += 4 * n
        return list(v)
    if tid == 12:  # long array
        n = r.i4()
        v = struct.unpack_from(">%dq" % n, r.b, r.i); r.i += 8 * n
        return list(v)
    raise ValueError("bad tag id %d at %d" % (tid, r.i))


def parse_nbt(data):
    r = _Reader(data)
    t = r.u1()
    if t == 0:
        return {}
    _ = r.s()            # root name (usually empty)
    return _read_payload(r, t)


# ---------------------------------------------------------------------------
# Anvil region file (.mca): 1024 chunks, 4 KiB sectors, headers in sector 0.
# ---------------------------------------------------------------------------

def iter_chunks(path):
    with open(path, "rb") as f:
        header = f.read(4096)
        if len(header) < 4096:
            return
        for idx in range(1024):
            off = struct.unpack_from(">I", header, idx * 4)[0]
            sector = off >> 8
            count = off & 0xFF
            if sector == 0 or count == 0:
                continue
            f.seek(sector * 4096)
            blob = f.read(count * 4096)
            if len(blob) < 5:
                continue
            length = struct.unpack_from(">I", blob, 0)[0]
            comp = blob[4]
            payload = blob[5:5 + length - 1]
            try:
                if comp == 1:      # gzip
                    raw = zlib.decompress(payload, 31)
                elif comp == 2:    # zlib
                    raw = zlib.decompress(payload)
                elif comp == 3:    # uncompressed
                    raw = payload
                else:
                    continue
            except Exception:
                continue
            try:
                yield parse_nbt(raw)
            except Exception:
                continue


# ---------------------------------------------------------------------------
# Deterministic per-chunk digest of terrain-only content.
# ---------------------------------------------------------------------------

def _palette_key(entry):
    # entry: compound {Name: str, Properties: {k:v}}
    if not isinstance(entry, dict):
        return repr(entry).encode()
    name = entry.get("Name", "")
    props = entry.get("Properties", {})
    if isinstance(props, dict):
        propstr = ";".join("%s=%s" % (k, props[k]) for k in sorted(props.keys()))
    else:
        propstr = ""
    return ("%s|%s" % (name, propstr)).encode("utf-8")


def chunk_terrain_bytes(chunk):
    """Return a stable byte string capturing this chunk's GENERATED TERRAIN only.
    Returns None if the chunk is not fully generated (so we skip partials)."""
    # 26.2 / 1.18+ flattened format: top-level keys, status, sections[].
    status = chunk.get("Status", chunk.get("status", ""))
    # ONLY digest fully-generated chunks ("minecraft:full" is the terminal
    # status). Partially-generated edge chunks (structure_starts, biomes,
    # features, ...) reach different stages depending on when the save flush
    # caught them and are NOT a determinism signal -- skip them entirely so the
    # digest reflects only finished terrain.
    if not (isinstance(status, str) and status.endswith("full")):
        return None

    parts = []
    xpos = chunk.get("xPos", chunk.get("Level", {}).get("xPos") if isinstance(chunk.get("Level"), dict) else None)
    zpos = chunk.get("zPos", chunk.get("Level", {}).get("zPos") if isinstance(chunk.get("Level"), dict) else None)
    parts.append(b"chunk")
    parts.append(struct.pack(">ii", int(xpos) if xpos is not None else 0,
                                     int(zpos) if zpos is not None else 0))
    if isinstance(status, str):
        parts.append(status.encode())

    sections = chunk.get("sections")
    if sections is None and isinstance(chunk.get("Level"), dict):
        sections = chunk["Level"].get("Sections")
    if not isinstance(sections, list):
        return None

    have_blocks = False
    for sec in sorted(sections, key=lambda s: s.get("Y", 0) if isinstance(s, dict) else 0):
        if not isinstance(sec, dict):
            continue
        y = sec.get("Y", 0)
        bs = sec.get("block_states")
        if isinstance(bs, dict):
            pal = bs.get("palette", [])
            parts.append(b"S")
            parts.append(struct.pack(">i", int(y)))
            for e in pal:
                parts.append(_palette_key(e))
                parts.append(b",")
            data = bs.get("data")
            if isinstance(data, list):
                parts.append(struct.pack(">%dq" % len(data), *data))
                have_blocks = True
            elif len(pal) > 0:
                have_blocks = True   # single-state section (e.g. all air/stone), no data array
        bi = sec.get("biomes")
        if isinstance(bi, dict):
            pal = bi.get("palette", [])
            parts.append(b"B")
            for e in pal:
                parts.append((e if isinstance(e, str) else repr(e)).encode())
                parts.append(b",")
            data = bi.get("data")
            if isinstance(data, list):
                parts.append(struct.pack(">%dq" % len(data), *data))

    # Heightmaps: deterministic surface shape (a strong terrain signal).
    hm = chunk.get("Heightmaps")
    if isinstance(hm, dict):
        for key in ("WORLD_SURFACE", "OCEAN_FLOOR", "MOTION_BLOCKING"):
            arr = hm.get(key)
            if isinstance(arr, list):
                parts.append(key.encode())
                parts.append(struct.pack(">%dq" % len(arr), *arr))

    if not have_blocks:
        return None
    return b"".join(parts)


def digest_region_dirs(dirs, verbose=False):
    chunk_digests = []
    files = []
    for d in dirs:
        files.extend(sorted(glob.glob(os.path.join(d, "r.*.mca"))))
    for path in files:
        for chunk in iter_chunks(path):
            tb = chunk_terrain_bytes(chunk)
            if tb is None:
                continue
            h = hashlib.sha256(tb).hexdigest()
            chunk_digests.append(h)
    # Sort chunk digests so region-file iteration order / threading cannot affect
    # the result -- only the SET of generated chunk contents matters.
    chunk_digests.sort()
    final = hashlib.sha256("\n".join(chunk_digests).encode()).hexdigest()
    if verbose:
        for h in chunk_digests:
            sys.stderr.write("  chunk %s\n" % h)
    return final, len(chunk_digests)


def main(argv):
    args = [a for a in argv[1:] if not a.startswith("--")]
    verbose = "--verbose" in argv
    if not args:
        sys.stderr.write("usage: terrain_digest.py <region-dir-or-world-dir> ...\n")
        return 2
    dirs = []
    for a in args:
        if os.path.isdir(os.path.join(a, "region")):
            dirs.append(os.path.join(a, "region"))
        else:
            dirs.append(a)
    final, n = digest_region_dirs(dirs, verbose=verbose)
    if n == 0:
        sys.stderr.write("ERROR: no fully-generated chunks found under: %s\n" % ", ".join(dirs))
        print("TERRAIN_DIGEST_EMPTY 0")
        return 3
    print("TERRAIN_CHUNKS %d" % n)
    print("TERRAIN_DIGEST %s" % final)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
