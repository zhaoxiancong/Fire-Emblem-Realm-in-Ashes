#!/usr/bin/env python3
"""PPM(P6) → PNG 转换（无第三方依赖）。

为什么需要：headless libmgba 驱动直接吐 PPM（115215 字节 = 240x160x3 + 头），
本机没有 ImageMagick，用 zlib+struct 手写最小 PNG 编码器即可。
color_t 是 BGR555，驱动已按 R/G/B 输出，这里不再换通道。
"""
import sys
import struct
import zlib


def read_ppm(p):
    with open(p, "rb") as f:
        magic = f.readline().strip()
        if magic != b"P6":
            raise ValueError(f"not P6: {magic}")
        dims = f.readline().split()
        while dims and dims[0].startswith(b"#"):
            dims = f.readline().split()
        w, h = int(dims[0]), int(dims[1])
        f.readline()
        data = f.read(w * h * 3)
    return w, h, data


def write_png(path, w, h, rgb):
    def chunk(tag, data):
        c = tag + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    raw = b""
    i = 0
    for _ in range(h):
        raw += b"\x00" + rgb[i:i + w * 3]
        i += w * 3
    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(raw, 9))
    png += chunk(b"IEND", b"")
    with open(path, "wb") as f:
        f.write(png)


if __name__ == "__main__":
    src, dst = sys.argv[1], sys.argv[2]
    w, h, d = read_ppm(src)
    write_png(dst, w, h, d)
    print(f"ok {dst} ({w}x{h})")
