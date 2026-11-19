"""Writes fixture.ico: an original test icon (teal square with a white diagonal band), 32x32 and 48x48."""
import struct, sys

def image(size):
    rows = []
    for y in range(size - 1, -1, -1):            # BMP rows are bottom-up
        row = b""
        for x in range(size):
            band = abs(x - y) < size // 6
            b, g, r = (255, 255, 255) if band else (150, 140, 20)
            row += bytes((b, g, r, 255))
        rows.append(row)
    pixels = b"".join(rows)
    mask = b"\0" * (((size + 31) // 32) * 4 * size)
    header = struct.pack("<IiiHHIIiiII", 40, size, size * 2, 1, 32, 0, len(pixels) + len(mask), 0, 0, 0, 0)
    return header + pixels + mask

sizes = [32, 48]
blobs = [image(s) for s in sizes]
out = struct.pack("<HHH", 0, 1, len(sizes))
offset = 6 + 16 * len(sizes)
for s, blob in zip(sizes, blobs):
    out += struct.pack("<BBBBHHII", s, s, 0, 0, 1, 32, len(blob), offset)
    offset += len(blob)
out += b"".join(blobs)
open(sys.argv[1], "wb").write(out)
