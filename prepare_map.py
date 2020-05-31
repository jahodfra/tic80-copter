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
            lookup = [bytes([i]) for i in range(S)]
            prefix = b""
            continue
        if code < len(lookup):
            ret = lookup[code]
            if prefix:
                lookup.append(prefix + lookup[code][:1])
            prefix = ret
            result.extend(ret)
        else:
            prefix = prefix + prefix[:1]
            lookup.append(prefix)
            result.extend(prefix)
    return result


def main():
    source = PIL.Image.open(sys.argv[1])
    w, h = source.size
    image_data = source.load()

    # remove resolution in polar regions
    orig_data = []
    for y in range(h):
        rw = int(w * math.sin((y+1) / (h+2) * math.pi))
        for x in range(rw):
           item = image_data[x * w // rw, y]
           orig_data.append(item)
    print("checksum: ", sum(orig_data))

    # Compress
    print(f"uncompressed {len(orig_data)//2}B")
    encoded = encode_lzw(orig_data)
    print(f"compressed by lzw {2*len(encoded)}B")
    print("checksum encoded: ", sum(encoded))

    # Write output files
    compressed = []
    for e in encoded:
        compressed.append(e//256)
        compressed.append(e%256)
    L = len(encoded)
    mappart = bytearray([L//256, L%256])
    mappart.extend(compressed[:32640-2])
    spritepart = bytes(compressed[32640-2:])
    open(sys.argv[2] + ".map","wb").write(mappart)
    open(sys.argv[2] + ".tiles","wb").write(spritepart)

    # Check decompression algorithm
    decoded = decode_lzw(encoded)
    assert orig_data == decoded


if __name__ == "__main__":
    main()
