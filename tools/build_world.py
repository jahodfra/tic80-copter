#!/usr/bin/env python3
"""Build the world terrain grid for the cart from land cover + elevation data.

Inputs (see README):
  lcc_global_8192.tif      NASA land cover classification, 8192x4096, lon -180..180
  raw/etopo5/ETOPO5.DOS    NOAA ETOPO5 elevation/bathymetry, 4320x2160 int16 LE, lon 0..360

The world is stored as an equal-area (sinusoidal) grid: H rows from the north pole to the south
pole, row y holds rw(y) = W * sin(pi*(y+0.5)/H) cells (rounded to a multiple of 128) around the globe, starting at
lon -180. Each cell is one byte:

  0 deep ocean, 1 ocean, 2 shallow water (shelf seas, lakes)
  4 + class*4 + relief   for land; relief 0 flat, 1 hills, 2 mountains, 3 snowy peaks

The rows are run-length encoded (see encode_rows) and split over the map/tiles/sprites memory
of cart banks 1..7 plus the map of bank 0.

Usage: python3 tools/build_world.py --out build/world.bin [--preview build/world.png]
"""
import argparse
import math
import pathlib

import numpy as np
from PIL import Image

Image.MAX_IMAGE_PIXELS = None

W, H = 2048, 1024
BAND = 128

# land classes (index into class list used by the cart)
SNOW, ROCK, DESERT, SHRUB, GRASS, SAVANNA, CROP, MOSAIC, TAIGA, FOREST, JUNGLE, WETLAND, URBAN = range(13)
CLASS_NAMES = ["snow", "rock", "desert", "shrub", "grass", "savanna", "crop", "mosaic",
               "taiga", "forest", "jungle", "wetland", "urban"]
WATER = -1
BARREN = 100  # resolved into ROCK or DESERT later

# LCC legend colours (from topomap.png palette) -> our class
LCC = [
    ((23, 23, 115), WATER),
    ((255, 249, 249), SNOW),
    ((245, 222, 180), SHRUB),     # open shrublands
    ((189, 189, 189), BARREN),
    ((249, 237, 115), CROP),
    ((240, 183, 104), GRASS),
    ((48, 205, 52), JUNGLE),      # evergreen broadleaf
    ((144, 187, 142), FOREST),    # mixed
    ((218, 235, 157), SAVANNA),   # woody savanna
    ((33, 138, 33), TAIGA),       # evergreen needleleaf
    ((255, 214, 0), SAVANNA),
    ((154, 205, 50), TAIGA),      # deciduous needleleaf
    ((154, 147, 92), MOSAIC),
    ((229, 242, 255), WATER),     # lakes
    ((153, 249, 151), FOREST),    # deciduous broadleaf
    ((70, 131, 178), WETLAND),
    ((188, 142, 144), SHRUB),     # closed shrublands
    ((254, 0, 0), URBAN),
]
NSRC = len(LCC)


def classify_lcc(path):
    """Nearest legend colour for every pixel of the land cover image -> uint8 legend index."""
    img = np.asarray(Image.open(path).convert("RGB"))
    cols = np.array([c for c, _ in LCC], dtype=np.int32)
    # 32-level LUT per channel
    q = np.arange(32) * 8 + 4
    r, g, b = np.meshgrid(q, q, q, indexing="ij")
    grid = np.stack([r, g, b], -1).reshape(-1, 1, 3)
    lut = np.argmin(((grid - cols[None]) ** 2).sum(-1), 1).astype(np.uint8)
    idx = (img[..., 0] >> 3).astype(np.int32) << 10 | (img[..., 1] >> 3).astype(np.int32) << 5 | (img[..., 2] >> 3)
    return lut[idx]


def load_etopo(path):
    e = np.fromfile(path, "<i2").reshape(2160, 4320).astype(np.float32)
    return np.roll(e, 2160, axis=1)  # start at lon -180


def row_widths():
    # multiples of BAND cells: neighbouring rows of equal length scroll together
    return [BAND * max(1, math.floor(W * math.sin(math.pi * (y + 0.5) / H) / BAND + 0.5)) for y in range(H)]


def resample_row(src_rows, rw, reducer):
    """Aggregate src_rows (k x N) into rw cells along x with reducer(segment)->value."""
    n = src_rows.shape[1]
    edges = np.round(np.linspace(0, n, rw + 1)).astype(int)
    return np.array([reducer(src_rows[:, edges[i]:max(edges[i + 1], edges[i] + 1)]) for i in range(rw)])


def build_grid(lcc_idx, etopo):
    rws = row_widths()
    lh, eh = lcc_idx.shape[0], etopo.shape[0]
    # roughness of terrain: std dev over a 3x3 ETOPO5 window (~27 km)
    from scipy.ndimage import uniform_filter, maximum_filter, minimum_filter
    m = uniform_filter(etopo, 3, mode="wrap")
    m2 = uniform_filter(etopo * etopo, 3, mode="wrap")
    rough = np.sqrt(np.maximum(m2 - m * m, 0))
    relief_range = maximum_filter(etopo, 5, mode="wrap") - minimum_filter(etopo, 5, mode="wrap")

    rows = []
    stats = np.zeros(64, int)
    for y in range(H):
        rw = rws[y]
        lat = 90 - (y + 0.5) * 180 / H
        # land cover: class histogram per cell, pick majority (land wins ties > 35%)
        ly0, ly1 = y * lh // H, (y + 1) * lh // H
        src = lcc_idx[ly0:ly1]
        n = src.shape[1]
        edges = np.round(np.linspace(0, n, rw + 1)).astype(int)
        onehot = np.zeros((NSRC, n + 1), np.int32)
        for k in range(NSRC):
            onehot[k, 1:] = np.cumsum((src == k).sum(0))
        counts = onehot[:, edges[1:]] - onehot[:, edges[:-1]]
        e1 = np.maximum(edges[1:], edges[:-1] + 1)
        counts = np.where(counts.sum(0) == 0, onehot[:, e1] - onehot[:, edges[:-1]], counts)
        water = counts[0] + counts[13]
        total = counts.sum(0)
        landc = counts.copy()
        landc[0] = landc[13] = 0
        best_land = landc.argmax(0)
        is_land = (total - water) > 0.38 * total
        # elevation per cell
        ey0, ey1 = y * eh // H, max(y * eh // H + 1, (y + 1) * eh // H)
        en = etopo.shape[1]
        eedges = np.round(np.linspace(0, en, rw + 1)).astype(int)
        ee1 = np.maximum(eedges[1:], eedges[:-1] + 1)

        def agg(a, f):
            seg = a[ey0:ey1]
            return np.array([f(seg[:, eedges[i]:ee1[i]]) for i in range(rw)])

        elev = agg(etopo, np.mean)
        emax = agg(etopo, np.max)
        rgh = agg(rough, np.max)
        rng = agg(relief_range, np.max)

        row = np.zeros(rw, np.uint8)
        snowline = 5000 - 4000 * max(0.0, (abs(lat) - 20) / 50) if abs(lat) < 70 else 600
        for x in range(rw):
            if not is_land[x]:
                d = elev[x]
                row[x] = 2 if d > -160 else (1 if d > -2600 else 0)
                continue
            c = LCC[best_land[x]][1]
            if c == BARREN:
                c = ROCK if (abs(lat) > 48 or elev[x] > 2200) else DESERT
            e, r, g = elev[x], rng[x], rgh[x]
            if c == SNOW:
                relief = 3 if g > 250 and e > 800 else (2 if g > 300 else (1 if g > 180 else 0))
            elif (emax[x] > snowline and r > 900) or emax[x] > snowline + 1200:
                relief = 3
            elif r > 1300 or (e > 1800 and r > 800) or g > 420:
                relief = 2
            elif r > 500 or g > 160:
                relief = 1
            else:
                relief = 0
            row[x] = 4 + c * 4 + relief
        for v in row:
            stats[v] += 1
        rows.append(row)
    return rows, stats


def smooth_rows(rows, rws):
    """Majority filter of land classes against neighbouring rows to remove speckle."""
    out = []
    for y, row in enumerate(rows):
        rw = len(row)
        new = row.copy()
        cls = np.where(row >= 4, (row - 4) // 4, -1)
        nbrs = [np.roll(cls, 1), np.roll(cls, -1)]
        for dy in (-1, 1):
            yy = y + dy
            if 0 <= yy < len(rows):
                o = rows[yy]
                idx = ((np.arange(rw) + 0.5) * len(o) / rw).astype(int)
                oc = np.where(o[idx] >= 4, (o[idx] - 4) // 4, -1)
                nbrs.append(oc)
        nb = np.stack(nbrs)
        for x in range(rw):
            c = cls[x]
            if c < 0:
                continue
            vals = nb[:, x]
            if (vals == c).sum() == 0:
                land = vals[vals >= 0]
                if len(land) >= 3:
                    u, n = np.unique(land, return_counts=True)
                    if n.max() >= 3:
                        new[x] = 4 + u[n.argmax()] * 4 + (row[x] - 4) % 4
        out.append(new)
    return out


def encode_rows(rows):
    """RLE: byte b<192: value b&63 repeated (b>>6)+1 times (1..3);
    b>=192: value b&63, next byte n: repeated n+4 times (4..259)."""
    out = bytearray()
    for row in rows:
        i, n = 0, len(row)
        while i < n:
            v = int(row[i])
            j = i
            while j < n and row[j] == v and j - i < 259:
                j += 1
            run = j - i
            if run <= 3:
                out.append(((run - 1) << 6) | v)
            else:
                out.append(192 | v)
                out.append(run - 4)
            i = j
    return bytes(out)


def preview(rows, path):
    pal = {0: (27, 47, 107), 1: (40, 86, 160), 2: (61, 139, 196)}
    ccol = [(244, 248, 251), (140, 130, 120), (232, 211, 154), (190, 170, 110), (170, 190, 90),
            (200, 190, 90), (225, 215, 120), (150, 160, 80), (40, 90, 50), (60, 130, 50),
            (30, 120, 40), (90, 140, 140), (200, 60, 50)]
    img = np.zeros((H, W, 3), np.uint8)
    for y, row in enumerate(rows):
        rw = len(row)
        off = (W - rw) // 2
        for x, v in enumerate(row):
            if v < 4:
                c = pal[int(v)]
            else:
                c = ccol[(v - 4) // 4]
                rel = (v - 4) % 4
                if rel:
                    c = tuple(int(k * (1 - 0.18 * rel)) for k in c) if rel < 3 else (255, 255, 255)
            img[y, off + x] = c
    Image.fromarray(img).save(path)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--lcc", default="lcc_global_8192.tif")
    ap.add_argument("--etopo", default="raw/etopo5/ETOPO5.DOS")
    ap.add_argument("--out", default="build/world.bin")
    ap.add_argument("--preview")
    args = ap.parse_args()
    lcc = classify_lcc(args.lcc)
    etopo = load_etopo(args.etopo)
    rows, stats = build_grid(lcc, etopo)
    rows = smooth_rows(rows, row_widths())
    data = encode_rows(rows)
    total = sum(len(r) for r in rows)
    print(f"{W}x{H}: {total:,} cells, RLE {len(data):,} bytes")
    pathlib.Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    pathlib.Path(args.out).write_bytes(data)
    if args.preview:
        preview(rows, args.preview)


if __name__ == "__main__":
    main()
