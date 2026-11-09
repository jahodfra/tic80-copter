"""
https://visibleearth.nasa.gov/images/61004/new-land-cover-classification-maps

Types:
  0 - water
  1-16 accoding to guide
  17 - lakes and rivers
"""
import PIL.Image
import math
import sys


def split_into_chunks(w, row, splits):
    free_space = w - len(row)
    chunk_size = len(row) / splits
    part_size = w // splits
    new_row = []
    start = 0
    for i in range(splits-1):
        end = start + chunk_size
        chunk = row[round(start):round(end)]
        new_row.extend(chunk)
        chunk_space = min(part_size  - len(chunk), free_space)
        free_space -= chunk_space
        new_row.extend([16] * chunk_space)
        start = end
    new_row.extend(row[round(start):])
    new_row.extend([16] * free_space)
    if len(new_row) > 240:
        # should not happen
        print(len(new_row), len(row), chunk_size, part_size)
    return new_row
    


def main():
    source = PIL.Image.open(sys.argv[1])
    w, h = source.size
    image_data = source.load()
    splits = 8

    orig_data = []
    # remove resolution in polar regions
    for y in range(17, h-16):
        rw = int(w * math.sin(y / (h+2) * math.pi))
        row = []
        for x in range(rw):
           item = image_data[x * w // rw, y]
           row.append(item)
        orig_data.extend(split_into_chunks(w, row, splits))

    mappart = bytearray()
    mappart.extend(orig_data)
    open(sys.argv[2] + ".map","wb").write(mappart)


if __name__ == "__main__":
    main()
