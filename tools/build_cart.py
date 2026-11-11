#!/usr/bin/env python3
"""Build a TIC-80 cart from a folder of Lua sources plus optional sprite sheet and sound data.

    python build_cart.py --src cart/src --out build/game [--sheet cart/sprites.gif] [--sound cart/sound.txt]
                         [--cover cart/cover.gif]

Writes <out>.lua (code only) and <out>.tic (code, tiles, sprites, palette, waveforms, sfx,
music, cover image). The cover is the 240x136 GIF screenshot shown when the cart is published;
it is stored as-is, so keep the one TIC-80 saved (tic_extract.py --cover) or supply your own. The *.lua files in --src are joined in file-name order into one Lua chunk (locals of
earlier files are visible in later ones); a file whose name starts with "00" is copied verbatim
(the cart metadata header). The code keeps its indentation and as many comments as fit the code
limit, trying in turn: all comments; only "---" doc comments; the first line of each doc
comment; the first lines of the longest functions' docs, as many as fit; section headers only;
no comments; finally minified. Section headers are comment lines of 20+ dashes followed by a name.
"""
import argparse
import pathlib
import struct
import sys

LEVELS = ["all comments", "doc comments", "first line of each doc comment",
          "summaries of the longest functions", "section headers only", "no comments"]
DOC_SUMMARIES, LONGEST_FIRST, HEADERS_ONLY = 2, 3, 4
CODE, TILES, SPRITES, PALETTE, COVER, MAP = 5, 1, 2, 12, 3, 4
SOUND_KINDS = {"wave": (10, 16, 16, 0), "sfx": (9, 66, 64, 0),            # chunk, size, count, first
               "pattern": (13, 192, 60, 1), "track": (14, 51, 8, 0)}


# ---------------------------------------------------------------------- comments
def strip_trailing_comment(line):
    """Remove a ` -- note` after code unless the dashes are inside a string."""
    pos = line.find(" --")
    while pos != -1:
        before = line[:pos]
        if before.count('"') % 2 == 0 and before.count("'") % 2 == 0 and "[[" not in before:
            return before.rstrip()
        pos = line.find(" --", pos + 1)
    return line


def doc_summaries(text):
    """(line number, bytes, length of the code it documents) for each doc comment's first line."""
    lines, found, i = text.splitlines(), [], 0
    while i < len(lines):
        if lines[i].strip().startswith("---") and not lines[i].strip().startswith("-" * 20):
            first = i
            while i < len(lines) and lines[i].strip().startswith("---"):
                i += 1
            body = 0
            while i < len(lines) and lines[i].strip() and not lines[i].strip().startswith("---"):
                body += 1
                i += 1
            found.append((first, len(lines[first].rstrip()) + 1, body))
        else:
            i += 1
    return found


def format_source(text, level, keep_docs=()):
    out, prev_doc = [], False
    for n, line in enumerate(text.splitlines()):
        s = line.strip()
        if not s:
            prev_doc = False
            continue
        if s.startswith("-" * 20):                     # section header
            prev_doc = False
            if level <= HEADERS_ONLY:
                out.append("-- " + s.lstrip("-").strip())
            continue
        if s.startswith("---"):                       # doc comment
            keep = level <= 1 or (level == DOC_SUMMARIES and not prev_doc) or \
                (level == LONGEST_FIRST and n in keep_docs)
            prev_doc = True
            if keep:
                out.append(line.rstrip())
            continue
        prev_doc = False
        if s.startswith("--") and not s.startswith("--[["):   # detail comment
            if level == 0:
                out.append(line.rstrip())
            continue
        out.append(line.rstrip() if level == 0 else strip_trailing_comment(line.rstrip()))
    return "\n".join(out)


def minify(text):
    return "\n".join(l.strip() for l in text.splitlines() if l.strip() and not l.strip().startswith("--"))


def assemble(header, sources, level, budget=0):
    keep, kept = {f: set() for f in sources}, 0
    if level == LONGEST_FIRST:
        docs = sorted(((body, cost, f, n) for f in sources for n, cost, body in doc_summaries(f.read_text())),
                      key=lambda d: -d[0])
        for body, cost, f, n in docs:
            if cost <= budget:
                keep[f].add(n)
                budget -= cost
                kept += 1
    parts = [h.read_text().strip() for h in header]
    for f in sources:
        text = f.read_text()
        parts.append(minify(text) if level is None else format_source(text, level, keep[f]))
    return "\n".join(parts) + "\n", kept


# ---------------------------------------------------------------------- assets
def sheet_chunks(path):
    """128x256 indexed GIF/PNG -> tiles, sprites and palette chunks."""
    from PIL import Image
    im = Image.open(path)
    if im.mode != "P" or im.size != (128, 256):
        sys.exit(f"error: {path} must be a 128x256 indexed image (got {im.mode} {im.size})")
    px = im.load()
    chunks = []
    for half, kind in ((0, TILES), (1, SPRITES)):
        data = bytearray()
        for j in range(16):
            for i in range(16):
                for y in range(8):
                    for x in range(0, 8, 2):
                        X, Y = i * 8 + x, half * 128 + j * 8 + y
                        data.append((px[X, Y] & 15) | ((px[X + 1, Y] & 15) << 4))
        chunks.append((kind, bytes(data)))
    chunks.append((PALETTE, bytes(im.getpalette()[:48])))
    return chunks


def sound_chunks(path):
    mem = {k: bytearray(size * count) for k, (_, size, count, _) in SOUND_KINDS.items()}
    for n, line in enumerate(path.read_text().splitlines(), 1):
        if not line.strip() or line.startswith("#"):
            continue
        parts = line.split()
        if len(parts) != 4 or parts[0] not in SOUND_KINDS:
            sys.exit(f"error: {path}:{n}: expected '<wave|sfx|pattern|track> <index> <name> <hex>'")
        kind, idx, _, data = parts
        _, size, count, first = SOUND_KINDS[kind]
        i, data = int(idx) - first, bytes.fromhex(data)
        if len(data) != size or not 0 <= i < count:
            sys.exit(f"error: {path}:{n}: {kind} needs index {first}..{count - 1 + first} and {size} bytes")
        mem[kind][i * size:(i + 1) * size] = data
    return [(SOUND_KINDS[k][0], bytes(v)) for k, v in mem.items()]


def write_tic(path, chunks):
    with open(path, "wb") as f:
        for kind, data in chunks:
            if len(data) > 0xFFFF:
                sys.exit(f"error: chunk {kind} is {len(data)} bytes; one chunk holds at most 65535")
            f.write(struct.pack("<I", len(data) << 8 | kind) + data)


# ---------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--src", required=True, help="folder with the *.lua sources")
    ap.add_argument("--out", required=True, help="output path without extension")
    ap.add_argument("--sheet", help="128x256 indexed sprite sheet (tiles on top, sprites below)")
    ap.add_argument("--sound", help="sound.txt with waveforms, sfx, music patterns and tracks")
    ap.add_argument("--cover", help="240x136 GIF cover image (stored in the cart as-is)")
    ap.add_argument("--limit", type=int, default=0xFFFF, help="code size limit in bytes (default 65535)")
    ap.add_argument("--all-comments", action="store_true", help="keep every comment (may exceed the limit)")
    ap.add_argument("--bank-data", help="binary data spread over the map memory of banks 1..7")
    ap.add_argument("--lua-only", action="store_true", help="write only the .lua")
    args = ap.parse_args()

    files = sorted(pathlib.Path(args.src).glob("*.lua"))
    if not files:
        sys.exit(f"error: no .lua files in {args.src}")
    header = [f for f in files if f.name.startswith("00")]
    sources = [f for f in files if not f.name.startswith("00")]
    levels = [0] if args.all_comments else list(range(len(LEVELS))) + [None]
    for level in levels:
        budget = 0
        if level == LONGEST_FIRST:
            budget = args.limit - len(assemble(header, sources, HEADERS_ONLY)[0].encode())
        code, kept = assemble(header, sources, level, budget)
        if len(code.encode()) <= args.limit:
            break
    what = "minified" if level is None else LEVELS[level]
    if level == LONGEST_FIRST:
        what += f" ({kept} of {sum(len(doc_summaries(f.read_text())) for f in sources)})"

    out = pathlib.Path(args.out)
    out.parent.mkdir(parents=True, exist_ok=True)
    lua = out.with_suffix(".lua")
    lua.write_text(code)
    size = len(code.encode())
    print(f"{lua}: {size:,} bytes from {len(files)} files, {what} ({args.limit - size:,} bytes left)")
    if args.lua_only:
        return
    if size > args.limit:
        sys.exit("error: the code does not fit the limit even minified")
    chunks = [(CODE, code.encode())]
    if args.sheet:
        chunks += sheet_chunks(args.sheet)
    if args.sound:
        chunks += sound_chunks(pathlib.Path(args.sound))
    if args.cover:
        cover = pathlib.Path(args.cover).read_bytes()
        if not cover.startswith(b"GIF8"):
            sys.exit(f"error: {args.cover} is not a GIF (TIC-80 stores the cover as GIF data)")
        chunks.append((COVER, cover))
    if args.bank_data:
        data = pathlib.Path(args.bank_data).read_bytes()
        size = 32640  # one bank of map memory
        parts = [data[i:i + size] for i in range(0, len(data), size)]
        if len(parts) > 7:
            sys.exit(f"error: {args.bank_data} needs {len(parts)} banks, only 7 are free")
        for bank, part in enumerate(parts, 1):
            chunks.append((MAP | bank << 5, part))
        print(f"{args.bank_data}: {len(data):,} bytes in map banks 1..{len(parts)}")
    tic = out.with_suffix(".tic")
    write_tic(tic, chunks)
    print(f"{tic}: {tic.stat().st_size:,} bytes, chunks {[(k & 31, k >> 5) for k, _ in chunks]}")


if __name__ == "__main__":
    main()
