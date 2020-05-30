import PIL.Image
import math
import sys


CLEAR_CODE=2**16-1

def encode_lzw(data, S=16):
    lookup = {bytes([i]): i for i in range(S)}
    result = []
    chain = bytes()
    next_lookup = len(lookup)
    for d in data:
        next_chain = chain + bytes([d])
        if next_chain not in lookup:
            result.append(lookup[chain])
            if len(lookup) < CLEAR_CODE - 1:
                lookup[next_chain] = next_lookup
                next_lookup += 1
            else:
                result.append(CLEAR_CODE)
                lookup = {bytes([i]): i for i in range(S)}
                next_lookup = len(lookup)
            chain = bytes([d])
        else:
            chain = next_chain
    if chain:
        result.append(lookup[chain])
    return result


def decode_lzw(codes, S=16):
    result = []
    for code in [CLEAR_CODE] + codes:
        if code == CLEAR_CODE:
            lookup = {i: bytes([i]) for i in range(S)}
            next_lookup = len(lookup)
            prefix = b""
            continue
        if code in lookup:
            ret = lookup[code]
            if prefix:
                lookup[next_lookup] = prefix + lookup[code][:1]
                next_lookup += 1
        else:
            ret = lookup[next_lookup] = prefix + prefix[:1]
            next_lookup += 1
        prefix = ret
        result.extend(ret)
    return result


def main():
    source = PIL.Image.open(sys.argv[1])
    w, h = source.size
    data = source.load()

    # remove resolution in polar regions
    row = []
    new_data = []
    for y in range(h):
        rw = int(w * math.sin((y+1) / (h+2) * math.pi))
        for x in range(rw):
           item = data[x * w // rw, y]
           row.append(item)
           new_data.append(item)
        new_data.extend([0]*(w-rw))

    # Compress
    print(f"uncompressed {len(row)//2}B")
    encoded = encode_lzw(row)
    print(f"compressed by lzw {2*len(encoded)}B")

    # Write output files
    compressed = []
    for e in encoded:
        compressed.append(e//256)
        compressed.append(e%256)
    L = len(compressed)
    mappart = bytearray([L//256, L%256])
    mappart.extend(compressed[:32640-2])
    spritepart = bytes(compressed[32640-2:])
    open(sys.argv[2] + ".map","wb").write(mappart)
    open(sys.argv[2] + ".tiles","wb").write(spritepart)

    # Check decompression algorithm
    decoded = decode_lzw(encoded)
    assert row == decoded


if __name__ == "__main__":
    main()
