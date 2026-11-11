#!/usr/bin/env python3
"""List or extract the contents of a TIC-80 .tic cart.

    python tic_extract.py game.tic --list
    python tic_extract.py game.tic --sheet cart/sprites.gif --sound cart/sound.txt [--cover cart/cover.gif] [--code out.lua]

--sheet writes tiles + sprites as a 128x256 indexed GIF with the cart palette.
--sound writes waveforms, sound effects, music patterns and tracks as sound.txt lines
('kind index name hex'); names and comment lines of an existing file are kept.
--cover saves the cover image (the publishing screenshot, a GIF) byte for byte.
"""
import argparse
import pathlib
import struct
import zlib

NAMES = {1: "tiles", 2: "sprites", 3: "cover", 4: "map", 5: "code", 9: "sfx", 10: "waveforms",
         12: "palette", 13: "music patterns", 14: "music tracks", 16: "code (zlib)",
         15: "music patterns", 17: "default", 18: "cover screen", 19: "binary", 20: "lang"}
SOUND_KINDS = {"wave": (10, 16, 16, 0), "sfx": (9, 66, 64, 0), "pattern": (13, 192, 60, 1),
               "track": (14, 51, 8, 0)}


def chunks(data):
    pos = 0
    while pos + 4 <= len(data):
        head, = struct.unpack_from("<I", data, pos)
        kind, bank, size = head & 0x1F, (head >> 5) & 7, (head >> 8) & 0xFFFF
        if kind == 5 and size == 0:
            size = 0x10000          # a full 64 KB code bank stores size 0 (16-bit field)
        pos += 4
        yield kind, bank, data[pos:pos + size]
        pos += size


def write_sheet(found, path):
    from PIL import Image
    img = Image.new("P", (128, 256), 0)
    pal = list(found.get(12, b""))[:48]
    if len(pal) < 48 and pathlib.Path(path).exists():
        pal = Image.open(path).getpalette()[:48]
    img.putpalette((pal + [0] * 48)[:48] + [0] * (768 - 48))
    for half, kind in ((0, 1), (1, 2)):
        raw = found.get(kind, b"").ljust(8192, b"\x00")
        for t in range(256):
            tx, ty = (t % 16) * 8, half * 128 + (t // 16) * 8
            for i in range(32):
                b = raw[t * 32 + i]
                x, y = (i * 2) % 8, (i * 2) // 8
                img.putpixel((tx + x, ty + y), b & 15)
                img.putpixel((tx + x + 1, ty + y), b >> 4)
    img.save(path, optimize=False)   # optimize=True would renumber palette indices


def write_sound(found, path):
    p = pathlib.Path(path)
    header, names = [], {}
    if p.exists():
        for line in p.read_text().splitlines():
            if line.startswith("#"):
                header.append(line)
            elif line.strip():
                kind, idx, name, _ = line.split()
                names[kind, int(idx)] = name
    lines = list(header)
    for kind, (chunk, size, count, first) in SOUND_KINDS.items():
        data = found.get(chunk, b"").ljust(size * count, b"\x00")
        for i in range(count):
            entry, n = data[i * size:(i + 1) * size], i + first
            if (kind, n) in names or any(entry):
                lines.append(f"{kind:4} {n:2d} {names.get((kind, n), f'{kind}{n}'):10s} {entry.hex()}")
    p.write_text("\n".join(lines) + "\n")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("cart")
    ap.add_argument("--list", action="store_true")
    ap.add_argument("--sheet")
    ap.add_argument("--sound")
    ap.add_argument("--cover")
    ap.add_argument("--code")
    args = ap.parse_args()
    data = pathlib.Path(args.cart).read_bytes()
    found, code = {}, {}
    for kind, bank, body in chunks(data):
        if args.list:
            print(f"chunk {kind:2d} {NAMES.get(kind, '?'):15s} bank {bank}  {len(body):6d} bytes")
        if kind == 5:
            code[bank] = body.rstrip(b"\0")
        elif kind == 16:
            # zlib-compressed code; sizecoded intros cut the stream's tail (checksum), which
            # TIC-80 tolerates, so decompress leniently instead of zlib.decompress()
            code[bank] = zlib.decompressobj().decompress(body)
        elif bank == 0:
            found[kind] = body
    if args.sheet:
        write_sheet(found, args.sheet)
        print("wrote", args.sheet)
    if args.sound:
        write_sound(found, args.sound)
        print("wrote", args.sound)
    if args.cover:
        if found.get(3):
            pathlib.Path(args.cover).write_bytes(found[3])
            print("wrote", args.cover)
        else:
            print("no cover image in", args.cart, "- take a screenshot in TIC-80 (F7) and save the cart")
    if args.code:
        # multi-bank code runs from the highest bank down to bank 0 (the "-- script:"
        # header is in the highest bank)
        pathlib.Path(args.code).write_bytes(b"".join(code[b] for b in sorted(code, reverse=True)))
        print("wrote", args.code)


if __name__ == "__main__":
    main()
