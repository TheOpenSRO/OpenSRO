#!/usr/bin/env python3
"""Round 673: count a name plate's own pixels in a movie frame, at the screen
point the client's `QA PLATE` line says the plate projects to.

  plate_pixels.py <dir with log.txt and fNNNNNNNN.png> [--white]

The directory is a movie run (--write-movie <dir>/f.png) with OPENSRO_QA_SHOTS
and OPENSRO_QA_PLATES=1 set (World3D._qa_plates_report). The frame read for a
shot is the announced one + 2, inside its hold. Pure Python: the render box has
no PIL.

A plate pixel is one of the plate's cream fill, NAME_PLATE_COLOUR (1.0, 0.94,
0.72) = (255, 240, 184): R >= 225, G >= 205, 140 <= B <= 215, R - B >= 30 --
with its black outline next to it within 3 px (sand and stone can be cream,
but not cream beside black). The box is 140 x 22 px centred on the point."""
import re, struct, sys, zlib, os

def read_png(path):
    data = open(path, 'rb').read()
    assert data[:8] == b'\x89PNG\r\n\x1a\n'
    pos, idat, w = 8, b'', 0
    while pos < len(data):
        n, = struct.unpack('>I', data[pos:pos+4]); t = data[pos+4:pos+8]; body = data[pos+8:pos+8+n]
        if t == b'IHDR':
            w, h, depth, ctype = struct.unpack('>IIBB', body[:10])
            ch = {2: 3, 6: 4}[ctype]
        elif t == b'IDAT':
            idat += body
        pos += 12 + n
    raw = zlib.decompress(idat)
    stride = w * ch
    rows, prev = [], bytearray(stride)
    i = 0
    for _ in range(h):
        f = raw[i]; line = bytearray(raw[i+1:i+1+stride]); i += 1 + stride
        if f == 1:
            for x in range(ch, stride): line[x] = (line[x] + line[x-ch]) & 255
        elif f == 2:
            for x in range(stride): line[x] = (line[x] + prev[x]) & 255
        elif f == 3:
            for x in range(stride): line[x] = (line[x] + ((line[x-ch] if x >= ch else 0) + prev[x]) // 2) & 255
        elif f == 4:
            for x in range(stride):
                a = line[x-ch] if x >= ch else 0; b = prev[x]; c = prev[x-ch] if x >= ch else 0
                p = a + b - c; pa, pb, pc = abs(p-a), abs(p-b), abs(p-c)
                line[x] = (line[x] + (a if pa <= pb and pa <= pc else (b if pb <= pc else c))) & 255
        rows.append(line); prev = line
    return w, h, ch, rows

def px(img, x, y):
    w, h, ch, rows = img
    r = rows[y]; return r[x*ch], r[x*ch+1], r[x*ch+2]

def cream(p):
    r, g, b = p
    return r >= 225 and g >= 205 and 140 <= b <= 215 and r - b >= 30

def white(p):
    return min(p) >= 235

def dark(p):
    return max(p) < 60

def count(img, cx, cy, hw=70, hh=11):
    w, h = img[0], img[1]
    n = 0
    for y in range(max(0, cy-hh), min(h, cy+hh)):
        for x in range(max(0, cx-hw), min(w, cx+hw)):
            q = px(img, x, y)
            if WHITE_LOOK:
                if white(q):
                    n += 1
                continue
            if cream(q):
                near = False
                for dy in (-3, -2, -1, 0, 1, 2, 3):
                    for dx in (-3, 0, 3):
                        yy, xx = y+dy, x+dx
                        if 0 <= yy < h and 0 <= xx < w and dark(px(img, xx, yy)):
                            near = True; break
                    if near: break
                if near: n += 1
    return n

d = sys.argv[1]
# --white: the round-673 monster look (white glyphs on a translucent box, no
# outline): a plate pixel is any pixel at least 235 in every channel.
WHITE_LOOK = '--white' in sys.argv
log = open(os.path.join(d, 'log.txt'), errors='replace').read()
frames = {m.group(1): int(m.group(2)) for m in re.finditer(r'QA SHOT (\S+) frame (\d+)', log)}
pat = re.compile(r'QA PLATE (\S+) (monster|player) (\d+) cam=([\d.]+) player=([\d.]+) screen=(-?\d+),(-?\d+) ahead=(\w+) shown=(\w+) range_end=(\d+) text=(\S+)')
cache = {}
for m in pat.finditer(log):
    shot, kind, eid, cam, pl, sx, sy, ahead, shown, rend, text = m.groups()
    sx, sy = int(sx), int(sy)
    fr = frames.get(shot)
    fn = os.path.join(d, 'f%08d.png' % (fr + 2)) if fr is not None else None
    if fn is None or not os.path.exists(fn):
        print(shot, kind, eid, 'no frame'); continue
    if fn not in cache:
        cache = {fn: read_png(fn)}
    img = cache[fn]
    on = ahead == 'yes' and 0 <= sx < img[0] and 0 <= sy < img[1]
    n = count(img, sx, sy) if on else -1
    print('%-7s %s %-6s cam=%6.1f player=%6.1f screen=%5d,%4d %-9s plate_px=%4s  %s' % (
        shot, kind, eid, float(cam), float(pl), sx, sy, 'on-screen' if on else 'off', n if on else '-', text))
