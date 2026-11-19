"""Draw Bendit's icon: a gold check mark inside a gold ring on a navy rounded
square. Pure standard library (zlib + struct), anti-aliased with signed
distance fields. Usage: python3 make_icon.py OUT.png [SIZE]"""
import math
import struct
import sys
import zlib

OUT = sys.argv[1]
N = int(sys.argv[2]) if len(sys.argv) > 2 else 1024

NAVY = (22, 33, 58)
GOLD = (242, 184, 48)
S = N / 1024.0  # design is laid out on a 1024 grid


def clamp(x, a=0.0, b=1.0):
    return a if x < a else b if x > b else x


def cover(d):
    """Signed distance (px, negative inside) -> coverage 0..1, 1px AA edge."""
    return clamp(0.5 - d)


def rounded_square(x, y, half, r):
    qx, qy = abs(x) - (half - r), abs(y) - (half - r)
    ox, oy = max(qx, 0.0), max(qy, 0.0)
    return math.hypot(ox, oy) + min(max(qx, qy), 0.0) - r


def segment(px, py, ax, ay, bx, by):
    vx, vy, wx, wy = bx - ax, by - ay, px - ax, py - ay
    t = clamp((wx * vx + wy * vy) / (vx * vx + vy * vy))
    return math.hypot(wx - t * vx, wy - t * vy)


c = N / 2.0
ring_r, ring_w = 300 * S, 46 * S
stroke = 40 * S
# check mark points on the 1024 grid, centred
p1 = (c - 150 * S, c + 10 * S)
p2 = (c - 40 * S, c + 125 * S)
p3 = (c + 170 * S, c - 120 * S)

rows = []
for j in range(N):
    y = j + 0.5
    row = bytearray([0])  # PNG filter: none
    for i in range(N):
        x = i + 0.5
        bg = cover(rounded_square(x - c, y - c, 470 * S, 200 * S))
        ring = cover(abs(math.hypot(x - c, y - c) - ring_r) - ring_w / 2)
        tick = cover(min(segment(x, y, *p1, *p2), segment(x, y, *p2, *p3)) - stroke)
        g = max(ring, tick)
        r = NAVY[0] * (1 - g) + GOLD[0] * g
        gg = NAVY[1] * (1 - g) + GOLD[1] * g
        b = NAVY[2] * (1 - g) + GOLD[2] * g
        row += bytes((int(r + 0.5), int(gg + 0.5), int(b + 0.5), int(255 * bg + 0.5)))
    rows.append(bytes(row))


def chunk(tag, data):
    return struct.pack('>I', len(data)) + tag + data + struct.pack('>I', zlib.crc32(tag + data) & 0xFFFFFFFF)


png = b'\x89PNG\r\n\x1a\n'
png += chunk(b'IHDR', struct.pack('>IIBBBBB', N, N, 8, 6, 0, 0, 0))
png += chunk(b'IDAT', zlib.compress(b''.join(rows), 9))
png += chunk(b'IEND', b'')
with open(OUT, 'wb') as f:
    f.write(png)
print(f'wrote {OUT} {N}x{N} {len(png)} bytes')
