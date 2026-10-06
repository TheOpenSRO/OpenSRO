#!/usr/bin/env python3
"""Round 693: measure how two rendered frames differ -- the same view drawn by
two renderers (Forward+ and Compatibility), or by two builds.

  frame_ab.py <a.png> <b.png> [--box x,y,w,h ...] [--label NAME]

Prints one line per region (the whole frame, then each --box):

  AB <label> <region> a_mean=(r,g,b) b_mean=(r,g,b) a_luma=p5/p50/p95 b_luma=p5/p50/p95
     dmean=<mean |a-b| over channels, 0..255> d8=<fraction of pixels with any channel
     |a-b| > 8> d32=<... > 32> dluma=<b mean luma - a mean luma> white_a/white_b=<fraction
     with every channel >= 230> black_a/black_b=<every channel <= 12> d2=<... > 2>
     dmax=<the largest channel difference> (round 747: d2 and dmax hold a "no change" claim)

Luma is Rec. 601 (0.299 R + 0.587 G + 0.114 B) on the 8-bit values as stored.
These are numbers about pixels, not a judgement of the look: a large d32 says
where to look next, and which object or effect it is has to be measured
separately (hide it, tint it, read its material).

Needs numpy and ImageMagick's `convert` (both on the render box; it has no
PIL). Frames of different sizes are refused."""
import subprocess, sys
import numpy as np

def load(path):
    w, h = map(int, subprocess.check_output(['identify', '-format', '%w %h', path]).split())
    raw = subprocess.check_output(['convert', path, '-alpha', 'off', '-depth', '8', 'rgb:-'])
    return np.frombuffer(raw, dtype=np.uint8).reshape(h, w, 3).astype(np.int16)

def luma(img):
    return 0.299 * img[..., 0] + 0.587 * img[..., 1] + 0.114 * img[..., 2]

def stats(label, region, a, b):
    la, lb = luma(a), luma(b)
    d = np.abs(a - b)
    dmax = d.max(axis=2)
    pa = np.percentile(la, [5, 50, 95]); pb = np.percentile(lb, [5, 50, 95])
    wa = float(np.mean(np.all(a >= 230, axis=2))); wb = float(np.mean(np.all(b >= 230, axis=2)))
    ka = float(np.mean(np.all(a <= 12, axis=2))); kb = float(np.mean(np.all(b <= 12, axis=2)))
    ma = a.reshape(-1, 3).mean(axis=0); mb = b.reshape(-1, 3).mean(axis=0)
    print("AB %s %s a_mean=(%.1f,%.1f,%.1f) b_mean=(%.1f,%.1f,%.1f) a_luma=%.0f/%.0f/%.0f b_luma=%.0f/%.0f/%.0f "
          "dmean=%.2f d8=%.3f d32=%.3f dluma=%+.2f white_a=%.3f white_b=%.3f black_a=%.3f black_b=%.3f "
          "d2=%.5f dmax=%d" % (
              label, region, ma[0], ma[1], ma[2], mb[0], mb[1], mb[2], pa[0], pa[1], pa[2], pb[0], pb[1], pb[2],
              float(d.mean()), float(np.mean(dmax > 8)), float(np.mean(dmax > 32)), float(lb.mean() - la.mean()),
              wa, wb, ka, kb, float(np.mean(dmax > 2)), int(dmax.max())))

def main(argv):
    if len(argv) < 2:
        print(__doc__); return 2
    pa, pb = argv[0], argv[1]
    boxes, label, i = [], "frame", 2
    while i < len(argv):
        if argv[i] == '--box':
            boxes.append(tuple(int(v) for v in argv[i + 1].split(','))); i += 2
        elif argv[i] == '--label':
            label = argv[i + 1]; i += 2
        else:
            print("unknown argument %s" % argv[i]); return 2
    a, b = load(pa), load(pb)
    if a.shape != b.shape:
        print("AB %s sizes differ: %s vs %s" % (label, a.shape, b.shape)); return 1
    stats(label, "whole", a, b)
    for (x, y, w, h) in boxes:
        stats(label, "box%d,%d,%d,%d" % (x, y, w, h), a[y:y + h, x:x + w], b[y:y + h, x:x + w])
    return 0

if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
