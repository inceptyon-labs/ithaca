#!/usr/bin/env python3
"""Finds where the app drew a piece of key art in a capture, for compose.py's `place`: the art's left and top edges
and its width, in capture pixels. It matches edges (gradient magnitude) by normalized cross-correlation, so the app's
dark overlays and fades don't throw it off. Needs numpy and Pillow.

    python3 place.py <capture.png> <art.jpg> <top> <bottom> [min scale] [max scale]

<top> and <bottom> bound a band of the capture where the art shows with little on top of it (no text, no buttons).
"""
import sys

import numpy as np
from PIL import Image

DOWN = 4


def edges(img):
    a = np.asarray(img.convert("L"), dtype=np.float32)
    gy, gx = np.gradient(a)
    return np.hypot(gx, gy)


def ncc(search, tmpl):
    """Normalized cross-correlation of tmpl at every position inside search (valid positions only)."""
    th, tw = tmpl.shape
    t = tmpl - tmpl.mean()
    tnorm = np.sqrt((t * t).sum()) + 1e-6
    H, W = search.shape
    fh, fw = H + th, W + tw
    corr = np.fft.irfft2(np.fft.rfft2(search, (fh, fw)) * np.conj(np.fft.rfft2(t, (fh, fw))), (fh, fw))
    corr = corr[: H - th + 1, : W - tw + 1]
    ii = np.pad(search, ((1, 0), (1, 0))).cumsum(0).cumsum(1)
    ii2 = np.pad(search * search, ((1, 0), (1, 0))).cumsum(0).cumsum(1)

    def box(s):
        return s[th:, tw:] - s[:-th, tw:] - s[th:, :-tw] + s[:-th, :-tw]

    n = th * tw
    var = box(ii2) - box(ii) ** 2 / n
    return corr / (np.sqrt(np.maximum(var, 1e-6)) * tnorm)


def best(cap, art, top, bottom, scales):
    tmpl = edges(cap.crop((0, top, cap.width, bottom)).resize((cap.width // DOWN, (bottom - top) // DOWN)))
    result = (-1, None)
    for s in scales:
        w, h = int(art.width * s / DOWN), int(art.height * s / DOWN)
        if w < tmpl.shape[1] or h < tmpl.shape[0]:
            continue
        score = ncc(edges(art.resize((w, h))), tmpl)
        y, x = np.unravel_index(np.argmax(score), score.shape)
        if score[y, x] > result[0]:
            result = (float(score[y, x]), (s, x, y))
    return result


cap = Image.open(sys.argv[1])
art = Image.open(sys.argv[2])
top, bottom = int(sys.argv[3]), int(sys.argv[4])
lo = float(sys.argv[5]) if len(sys.argv) > 5 else 0.5
hi = float(sys.argv[6]) if len(sys.argv) > 6 else 4.0
score, (s, x, y) = best(cap, art, top, bottom, np.geomspace(lo, hi, 40))
score, (s, x, y) = best(cap, art, top, bottom, np.linspace(s * 0.96, s * 1.04, 21))
left, art_top = -x * DOWN, top - y * DOWN
print(f"place=({left}, {art_top}, {round(art.width * s)})  score {score:.3f}")
