import collections
import heapq

import PIL.ImageShow
import PIL.Image
import PIL.ImageColor
import PIL.ImageFilter
import itertools
import math
import struct
import sys


def huffman(counter):
    items = [(c, k) for k, c in counter.items()]
    heapq.heapify(items)
    tree = {i: i for i in counter}
    i = max(counter) + 1
    while items:
        c1, k1 = heapq.heappop(items)
        c2, k2 = heapq.heappop(items)
        tree[i] = tree[k1], tree[k2]
        if items:
            heapq.heappush(items, (c1 + c2, i))
            i += 1
        else:
            return to_bin(tree[i])

def to_bin(node):
    if isinstance(node, tuple):
        left, right = node
        mapping = {}
        for k, v in to_bin(left).items():
            mapping[k] = '0'+v
        for k, v in to_bin(right).items():
            mapping[k] = '1'+v
        return mapping
    else:
        return {node: ''}

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

def shortest_repeat(chain):
    """return min i, such that chain[:i] * R == chain"""
    L = len(chain)
    for i in range(1, L-1):
        if (chain[:i] * L)[:L] == chain:
            return i
    return -1


def find_match(chain, window):
    start = window.find(chain)
    if start == -1:
        i = shortest_repeat(chain)
        if i == -1:
            return -1
        if window[-i:] == chain[:i]:
            return len(window)-i
        
    return start

assert shortest_repeat("abcabc") == 3
assert shortest_repeat("abcabca") == 3
assert find_match("abcab", "xxxxabc") == 4

def encode_lz77(data):
    max_window_size = 2**15 # 32K
    max_chain_size = 2**5 # 32
    chain = bytearray()
    result = []
    stop = 255
    for i, d in enumerate(data + bytes([stop])):
        window = data[max(0, i-max_window_size) : i]
        chain.append(d)
        if d == stop or find_match(chain, window) == -1 or len(chain) > max_chain_size:
            chain.pop()
            start = find_match(chain, window)
            size = len(chain)
            # 4b per d, 11b per start, 5b per size
            word = d << 15 | start << 5 | size-1
            result.append(word // 256**2)
            result.append(word // 256 % 256)
            result.append(word % 256)
            chain = bytearray()
    return result

def get_huffman_factor(row):
    c = collections.Counter(row)
    enc = huffman(c)
    #print([(c, f) for c, f in sorted(enc.items())])
    return sum(len(enc[c]) for c in row) // 8

import zlib, gzip, bz2

def main():
    source = PIL.Image.open(sys.argv[1])
    w, h = source.size
    data = source.load()
    row = []
    new_image = source.copy()
    print(f"before: {w * h // 2}B")
    new_data = []
    for y in range(h):
        rw = int(w * math.sin((y+1) / (h+2) * math.pi))
        for x in range(rw):
           item = data[x * w // rw, y]
           row.append(item)
           new_data.append(item)
        new_data.extend([0]*(w-rw))
    new_image.putdata(new_data)
    new_image.save("converted.png")
    print(f"after {len(row)//2}B")
    encoded = encode_lzw(row)
    compressed = []
    for e in encoded:
        compressed.append(e//256)
        compressed.append(e%256)

    mappart = bytes(compressed[:32640])
    spritepart = bytes(compressed[32640:])
    open("texture.map","wb").write(mappart)
    open("texture.spr","wb").write(spritepart)
    decoded = decode_lzw(encoded)
    assert row == decoded

    print(f"after lzw {2*len(encoded)}B")
    print(f"different symbols: {len(set(encoded))}")

    lzw_factor = get_huffman_factor(encoded)
    print(f"after lzw+huffman {lzw_factor}B")

    print(f"after zlib {len(zlib.compress(bytes(row), level=9))}B")
    print(f"after gzip {len(gzip.compress(bytes(row)))}B")
    print(f"after bz2 {len(bz2.compress(bytes(row)))}B")
    print(f"after lz77 {len(encode_lz77(bytes(row)))}B")

if __name__ == "__main__":
    main()
