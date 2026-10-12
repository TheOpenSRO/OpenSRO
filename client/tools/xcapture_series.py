#!/usr/bin/env python3
"""Round 785: what a player saw, grab by grab -- the series from xcapture.sh.

  xcapture_series.py <dir> <ref> [--from UNIX] [--to UNIX]

<dir> holds xcapture.sh's grabs (c<unix ns>.xwd); <ref> is one image of the
loading screen (a grab or a PNG, the same size). One line per grab:

  <unix s> luma=<mean Rec.601 luma> black=<fraction every channel <= 12>
      LS=<fraction of pixels within 8 of the reference> -> screen|world|black

LS near 1 is the loading screen (its caption and gauge move a few percent); a
world view is far below. A grab is "black" when 90 % of it is black. Needs
numpy and ImageMagick's convert (both on the render box)."""
import os, subprocess, sys
import numpy as np


def load(path):
    w, h = map(int, subprocess.check_output(['identify', '-format', '%w %h', path]).split())
    raw = subprocess.check_output(['convert', path, '-alpha', 'off', '-depth', '8', 'rgb:-'])
    return np.frombuffer(raw, dtype=np.uint8).reshape(h, w, 3).astype(np.int16)


def main():
    args = sys.argv[1:]
    lo = hi = None
    if '--from' in args:
        i = args.index('--from'); lo = float(args[i + 1]); del args[i:i + 2]
    if '--to' in args:
        i = args.index('--to'); hi = float(args[i + 1]); del args[i:i + 2]
    d, ref_path = args[0], args[1]
    ref = load(ref_path)
    names = sorted(n for n in os.listdir(d) if n.startswith('c') and n.endswith('.xwd'))
    for n in names:
        t = int(n[1:-4]) / 1e9
        if (lo is not None and t < lo) or (hi is not None and t > hi):
            continue
        p = os.path.join(d, n)
        if os.path.getsize(p) == 0:
            continue
        try:
            im = load(p)
        except subprocess.CalledProcessError:
            print('%.3f unreadable' % t)
            continue
        if im.shape != ref.shape:
            print('%.3f size %s differs from the reference %s' % (t, im.shape, ref.shape))
            continue
        luma = (0.299 * im[..., 0] + 0.587 * im[..., 1] + 0.114 * im[..., 2]).mean()
        black = float(np.mean(np.all(im <= 12, axis=2)))
        ls = float(np.mean(np.abs(im - ref).max(axis=2) <= 8))
        kind = 'black' if black >= 0.9 else ('screen' if ls >= 0.85 else 'world')
        print('%.3f luma=%.1f black=%.3f LS=%.3f -> %s' % (t, luma, black, ls, kind))


if __name__ == '__main__':
    main()
