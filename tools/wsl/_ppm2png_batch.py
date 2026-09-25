#!/usr/bin/env python3
"""批量把目录下所有 PPM 转成 PNG（复用 _ppm2png 的编码器）。

用法：python3 _ppm2png_batch.py <dir>
"""
import sys
import pathlib

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from _ppm2png import read_ppm, write_png  # noqa: E402

d = pathlib.Path(sys.argv[1])
n = 0
for ppm in sorted(d.glob("*.ppm")):
    png = ppm.with_suffix(".png")
    w, h, data = read_ppm(str(ppm))
    write_png(str(png), w, h, data)
    n += 1
print(f"converted {n} ppm -> png")
