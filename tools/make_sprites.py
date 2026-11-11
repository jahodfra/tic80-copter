#!/usr/bin/env python3
"""Generate cart/sprites.gif: palette, terrain textures, coast masks, relief and city sprites.

The sheet is 128x256 (tiles 0-255 on top, sprites 256-511 below). Layout (tile ids):
    1..6      water: deep, ocean, shallow (2 variants each)       WATER_T = 1 + level*2 + v
    16..63    dual-grid masks for water level 0,1,2; id = 16 + level*16 + cornermask
    64..115   land textures: 64 + class*4 + variant (13 classes, see build_world.py)
Sprites:
    256..263  hills 8x8: 256 + group*2 + variant  (groups: green, dry, rock, snow)
    272..286  mountains 16x16 at 272,274 (green), 276,278 (dry), 280,282 (rock), 284,286 (snowy)
    304..306  cities: town, capital, metropolis
    320       helicopter body 24x32 (3x4), 324 its dithered shadow 24x32,
    328,332,384,388  main rotor frames 32x32 (colour 1 is transparent)
    392,396,448,452  their dithered shadows
The art is generated, but the GIF can be edited in TIC-80 afterwards (tools/tic_extract.py).
"""
import math
import random
import sys

from PIL import Image

PALETTE = [
    0x10141f,  # 0 black
    0x1b2a5e,  # 1 deep sea
    0x24508e,  # 2 ocean
    0x3483bf,  # 3 shallow
    0x9fd3e3,  # 4 foam / ice shade
    0xf2f5f7,  # 5 snow / white
    0xe3cb8f,  # 6 sand
    0xb8955a,  # 7 dry soil
    0x9da14a,  # 8 olive
    0x6fa23c,  # 9 grass
    0x3c7a33,  # 10 forest
    0x1f4a2c,  # 11 dark forest
    0x8e877e,  # 12 rock light
    0x55504c,  # 13 rock dark
    0xc4402f,  # 14 red
    0xf0c84a,  # 15 yellow
]

sheet = Image.new("P", (128, 256), 0)
flat = []
for c in PALETTE:
    flat += [c >> 16, (c >> 8) & 255, c & 255]
sheet.putpalette(flat + [0] * (768 - len(flat)))
px = sheet.load()
rnd = random.Random(1234)


def tile_xy(tid):
    """Top-left pixel of tile/sprite id on the sheet."""
    half = tid // 256
    t = tid % 256
    return (t % 16) * 8, half * 128 + (t // 16) * 8


def put(tid, x, y, c):
    bx, by = tile_xy(tid)
    if 0 <= x < 8 and 0 <= y < 8:
        px[bx + x, by + y] = c


def fill(tid, c):
    for y in range(8):
        for x in range(8):
            put(tid, x, y, c)


def put16(sid, x, y, c):
    """Draw into a 16x16 sprite made of ids sid, sid+1, sid+16, sid+17."""
    if 0 <= x < 16 and 0 <= y < 16:
        put(sid + (y // 8) * 16 + x // 8, x % 8, y % 8, c)


# ------------------------------------------------------------------ water
WATER_COL = [1, 2, 3]
WAVE_COL = [2, 3, 4]
for lev in range(3):
    for v in range(2):
        tid = 1 + lev * 2 + v
        fill(tid, WATER_COL[lev])
        if v == 1:  # a small wave crest
            x, y = rnd.randrange(1, 5), rnd.randrange(1, 7)
            for i in range(3):
                put(tid, x + i, y if i != 1 else y - 1 + (lev == 2), WAVE_COL[lev])

# ------------------------------------------------------------------ masks
def bilinear(m, u, v):
    a = 1.0 if m & 1 else 0.0  # top-left
    b = 1.0 if m & 2 else 0.0  # top-right
    c = 1.0 if m & 4 else 0.0  # bottom-left
    d = 1.0 if m & 8 else 0.0  # bottom-right
    return (a * (1 - u) + b * u) * (1 - v) + (c * (1 - u) + d * u) * v


def smooth(t):
    return t * t * (3 - 2 * t)


for lev in range(3):
    for m in range(1, 16):
        tid = 16 + lev * 16 + m
        for y in range(8):
            for x in range(8):
                u, v = smooth((x + 0.5) / 8), smooth((y + 0.5) / 8)
                f = bilinear(m, u, v)
                if lev == 2:
                    if f > 0.6:
                        c = 3
                    elif f > 0.5:
                        c = 4          # surf
                    elif f > 0.38:
                        c = 6          # beach
                    else:
                        c = 0
                else:
                    if f > 0.55:
                        c = WATER_COL[lev]
                    elif f > 0.45:
                        c = WATER_COL[lev] if (x + y) % 2 == 0 else 0
                    else:
                        c = 0
                put(tid, x, y, c)

# ------------------------------------------------------------------ land textures
def speckle(tid, base, dots, n, r=rnd):
    fill(tid, base)
    for _ in range(n):
        put(tid, r.randrange(8), r.randrange(8), r.choice(dots))


def blob(tid, x, y, light, mid, dark):
    """A 3x3-ish tree canopy seen from above, lit from the top left."""
    for dx, dy, c in ((0, 0, light), (1, 0, mid), (0, 1, mid), (1, 1, mid), (2, 1, dark), (1, 2, dark), (2, 2, dark)):
        put(tid, (x + dx) % 8, (y + dy) % 8, c)


def snow(tid, v):
    speckle(tid, 5, [4], 3 + v)
    if v >= 2:
        for x in range(8):
            put(tid, x, (x // 3 + v * 2) % 8, 4)


def rock(tid, v):
    speckle(tid, 12, [13, 13, 8], 10 + v * 2)
    for _ in range(2):
        x, y = rnd.randrange(7), rnd.randrange(7)
        put(tid, x, y, 13); put(tid, x + 1, y, 13); put(tid, x, y + 1, 5 if v == 3 else 12)


def desert(tid, v):
    fill(tid, 6)
    ph = rnd.random() * 6.28
    for x in range(8):
        y = int(3.5 + 2.2 * math.sin(x * 0.8 + ph + v))
        put(tid, x, y, 7)
        if v % 2:
            put(tid, x, (y + 4) % 8, 7)
    if v == 3:
        put(tid, 2, 6, 5)


def shrub(tid, v):
    speckle(tid, 7, [6, 6, 8], 12)
    for _ in range(3):
        x, y = rnd.randrange(8), rnd.randrange(8)
        put(tid, x, y, 10); put(tid, x + 1, y + 1, 11)


def grass(tid, v):
    speckle(tid, 9, [8, 10, 8], 14 + v)
    for _ in range(2):
        x, y = rnd.randrange(7), rnd.randrange(8)
        put(tid, x, y, 10); put(tid, x + 1, y, 10)


def savanna(tid, v):
    speckle(tid, 8, [15, 7, 15], 12)
    if v != 1:
        x, y = rnd.randrange(6), rnd.randrange(6)
        put(tid, x, y, 9); put(tid, x + 1, y, 10); put(tid, x, y + 1, 10); put(tid, x + 1, y + 1, 11)


def fields(tid, v, cols):
    """Patchwork of ploughed fields: 2-3 rectangles with row stripes."""
    split = rnd.randrange(3, 6)
    vertical = v % 2 == 0
    for y in range(8):
        for x in range(8):
            a = x if vertical else y
            b = y if vertical else x
            part = 0 if a < split else 1
            c0, c1 = cols[(part + v) % len(cols)]
            put(tid, x, y, c1 if b % 2 else c0)
    # hedge / track on half of the tiles
    for i in range(8 if v in (0, 3) else 0):
        if vertical:
            put(tid, split, i, 7 if v != 3 else 10)
        else:
            put(tid, i, split, 7 if v != 3 else 10)


CROP_COLS = [(9, 8), (15, 8), (9, 9), (7, 6), (8, 9)]


def crop(tid, v):
    fields(tid, v, CROP_COLS[v:] + CROP_COLS[:v])


def mosaic(tid, v):
    fields(tid, v, [(9, 8), (15, 8), (9, 9)])
    for _ in range(2):
        blob(tid, rnd.randrange(8), rnd.randrange(8), 9, 10, 11)


def taiga(tid, v):
    fill(tid, 11)
    for _ in range(9):
        x, y = rnd.randrange(8), rnd.randrange(8)
        put(tid, x, y, 10); put(tid, x, y - 1, 9 if rnd.random() < 0.4 else 10)
    if v == 3:
        put(tid, 3, 3, 5)


def forest(tid, v):
    fill(tid, 10)
    pos = [(0, 0), (4, 1), (2, 4), (6, 5), (5, 2) if v % 2 else (1, 6)]
    for x, y in pos:
        blob(tid, (x + v) % 8, (y + v * 3) % 8, 9, 10, 11)


def jungle(tid, v):
    fill(tid, 11)
    for x, y in [(0, 0), (3, 0), (6, 1), (1, 3), (4, 4), (7, 4), (2, 6), (5, 7)]:
        blob(tid, (x + v * 2) % 8, (y + v) % 8, 9 if rnd.random() < 0.5 else 10, 10, 11)


def wetland(tid, v):
    speckle(tid, 9, [10, 8], 10)
    for _ in range(2 + v % 2):
        x, y = rnd.randrange(7), rnd.randrange(7)
        put(tid, x, y, 3); put(tid, x + 1, y, 3); put(tid, x, y + 1, 3); put(tid, x + 1, y + 1, 4 if v == 2 else 3)


def urban(tid, v):
    fill(tid, 12)
    for i in range(8):
        put(tid, i, 3 + v % 2, 13)
        put(tid, 4 - v % 2, i, 13)
    for _ in range(4):
        x, y = rnd.randrange(7), rnd.randrange(7)
        c = rnd.choice([14, 5, 14, 13])
        put(tid, x, y, c); put(tid, x + 1, y, c)


GENERATORS = [snow, rock, desert, shrub, grass, savanna, crop, mosaic, taiga, forest, jungle, wetland, urban]
for c, gen in enumerate(GENERATORS):
    for v in range(4):
        gen(64 + c * 4, v) if False else gen(64 + c * 4 + v, v)

# ------------------------------------------------------------------ relief sprites
# colour groups: (light, mid, dark)
GROUPS = [(9, 10, 11), (6, 7, 13), (12, 13, 0), (5, 4, 12)]
for g, (light, mid, dark) in enumerate(GROUPS):
    for v in range(2):
        sid = 256 + g * 2 + v
        w = 3 + v  # half width
        cx, top = 4, 2 + v
        for y in range(top, 8):
            hw = int((y - top + 1) * w / (8 - top))
            for x in range(cx - hw, cx + hw + 1):
                if 0 <= x < 8:
                    c = light if x < cx else mid
                    if x == cx + hw or y == 7:
                        c = dark if y > top + 1 else mid
                    put(sid, x, y, c)


def mountain(sid, foot, rockl, rockd, snowcap, seed):
    r = random.Random(seed)
    peak_x = 7 + r.randrange(-1, 2)
    top = 1 + r.randrange(2)
    for y in range(top, 16):
        t = (y - top) / (15 - top)
        hl = int(t * (peak_x - 0.5))
        hr = int(t * (14 - peak_x))
        for x in range(peak_x - hl, peak_x + hr + 1):
            if x < peak_x:
                c = rockl
            else:
                c = rockd
            if snowcap and y < top + 7 - (x > peak_x) + (abs(x - peak_x) < 2):
                c = 5 if x <= peak_x else 4
            if y >= 12 and r.random() < (y - 11) / 5:
                c = foot
            put16(sid, x, y, c)
        # ridge crack
        if 4 < y < 13 and r.random() < 0.5:
            put16(sid, peak_x - hl // 2, y, rockd if not snowcap or y > top + 5 else 4)
    # second smaller peak
    p2 = peak_x + 4 if peak_x < 8 else peak_x - 5
    top2 = top + 5
    for y in range(top2, 16):
        hw = int((y - top2) * 0.7)
        for x in range(p2 - hw, p2 + hw + 1):
            if 0 <= x < 16 and px_get16(sid, x, y) == 0:
                c = rockl if x < p2 else rockd
                if snowcap and y < top2 + 2:
                    c = 5
                if y >= 13:
                    c = foot
                put16(sid, x, y, c)


def px_get16(sid, x, y):
    bx, by = tile_xy(sid + (y // 8) * 16 + x // 8)
    return px[bx + x % 8, by + y % 8]


mountain(272, 10, 12, 13, False, 1)
mountain(274, 10, 12, 13, False, 2)
mountain(276, 7, 12, 13, False, 3)
mountain(278, 7, 12, 13, False, 4)
mountain(280, 13, 12, 13, False, 5)
mountain(282, 13, 12, 13, False, 6)
mountain(284, 12, 12, 13, True, 7)
mountain(286, 13, 12, 13, True, 8)

# ------------------------------------------------------------------ cities
TOWN = [
    "........",
    "..EE....",
    ".E55D...",
    ".55D.EE.",
    "..D.E55D",
    ".EE.55D.",
    "E55D.D..",
    ".DD.....",
]
CAPITAL = [
    "...F....",
    "..FFF...",
    ".EEFEE..",
    "E5555ED.",
    "5D55D5D.",
    "5D55D5D.",
    "555555D.",
    ".DDDDDD.",
]
METRO = [
    "..5.....",
    "..5D.5..",
    ".55D.5D.",
    ".55D55D5",
    "E55D55D5",
    "E55D55D5",
    "E55D55DD",
    ".DDDDDD.",
]
CODES = {".": 0, "E": 14, "5": 5, "D": 13, "F": 15}
for sid, art in ((304, TOWN), (305, CAPITAL), (306, METRO)):
    for y, line in enumerate(art):
        for x, ch in enumerate(line):
            put(sid, x, y, CODES[ch])

# ------------------------------------------------------------------ helicopter
# Top-down rescue helicopter, nose up. Left half of the 24x32 body; the right
# half is mirrored and then shaded (light comes from the top left).
# . transparent  o outline  w white  g light grey  d dark grey  r red
# y yellow  b light glass  B dark glass  k black
COPTER_KEY = 1  # transparent colour of the copter sprites (deep sea is not used in them)
BODY_HALF = [
    "............",
    "..........oo",
    ".........obb",
    "........obbb",
    "........obwb",
    ".......obbbb",
    ".......obbbb",
    "...d...oBBBB",
    "...d...owwww",
    "...dd..owwww",
    "...d.ddorwww",
    "...d...orwwg",
    "...d...orwgd",
    "...d...orwgd",
    "...d...orwgd",
    "...d...orwgd",
    "...d.ddorwwg",
    "...dd..owwww",
    "...d...owwww",
    "...d....owww",
    "........owww",
    ".........oww",
    "..........ow",
    "..........ow",
    "..........ow",
    ".......ooooo",
    ".......orrrr",
    ".......ooooo",
    "..........ow",
    "..........or",
    "..........or",
    "...........o",
]
CODES_COPTER = {".": COPTER_KEY, "o": 0, "w": 5, "g": 12, "d": 13, "r": 14, "y": 15,
                "b": 4, "B": 3, "k": 0}


def copter_body():
    """24x32 colour grid of the body (mirrored, then shaded on the right)."""
    rows = []
    for half in BODY_HALF:
        row = [CODES_COPTER[c] for c in half]
        rows.append(row + row[::-1])
    out = [r[:] for r in rows]
    for y, r in enumerate(rows):
        for x in range(12, 24):
            c = r[x]
            edge = x + 1 < 24 and r[x + 1] == 0
            if c == 5 and (edge or (x + 2 < 24 and r[x + 2] == 0)):
                out[y][x] = 12          # shaded right flank
            elif c == 12 and edge:
                out[y][x] = 13
            elif c == 4 and edge:
                out[y][x] = 3           # darker glass on the right
    return out


def put_grid(sid, grid, w_tiles):
    for y, row in enumerate(grid):
        for x, c in enumerate(row):
            put(sid + (y // 8) * 16 + x // 8, x % 8, y % 8, c)


def rotor_frame(angle):
    """32x32 four-blade main rotor: black blades, yellow tips, grey blur trails."""
    g = [[COPTER_KEY] * 32 for _ in range(32)]
    cx = cy = 15.5
    for b in range(4):
        a = angle + b * math.pi / 2
        # motion blur first, so the blade is drawn over it
        for k, t in enumerate(range(6, 16)):
            if k % 2 == 0:
                ta = a - 0.18
                xi, yi = int(round(cx + math.cos(ta) * t)), int(round(cy + math.sin(ta) * t))
                if 0 <= xi < 32 and 0 <= yi < 32:
                    g[yi][xi] = 12
        steps = 60
        for i in range(steps + 1):
            t = 2 + 13.6 * i / steps
            xi, yi = int(round(cx + math.cos(a) * t)), int(round(cy + math.sin(a) * t))
            if 0 <= xi < 32 and 0 <= yi < 32:
                g[yi][xi] = 15 if t > 13.2 else 0
    for y in range(14, 18):          # hub
        for x in range(14, 18):
            corner = x in (14, 17) and y in (14, 17)
            g[y][x] = COPTER_KEY if corner else 13
    g[15][15] = 12
    g[15][16] = 5
    return g


def rotor_shadow(frame):
    """Dithered black copy of a rotor frame (blades only, no blur)."""
    return [[0 if c in (0, 15, 13) and (x + y) % 2 == 0 else COPTER_KEY
             for x, c in enumerate(row)] for y, row in enumerate(frame)]


def copter_shadow(body):
    """24x32 dithered black silhouette of the body (the rotor's shadow is the
    rotor sprite drawn in black)."""
    g = [[COPTER_KEY] * 24 for _ in range(32)]
    for y in range(32):
        for x in range(24):
            if body[y][x] != COPTER_KEY and (x + y) % 2 == 0:
                g[y][x] = 0
    return g


BODY = copter_body()
put_grid(320, BODY, 3)
put_grid(324, copter_shadow(BODY), 4)
for i, (sid, shadow_sid) in enumerate(((328, 392), (332, 396), (384, 448), (388, 452))):
    frame = rotor_frame(i * math.pi / 8)
    put_grid(sid, frame, 4)
    put_grid(shadow_sid, rotor_shadow(frame), 4)

out = sys.argv[1] if len(sys.argv) > 1 else "cart/sprites.gif"
sheet.save(out, optimize=False)
print("wrote", out)
