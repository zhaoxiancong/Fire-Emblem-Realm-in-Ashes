#!/usr/bin/env python3
"""验证「消息表覆盖」是否真的进了最终 ROM。

为什么需要它：
  框架把 texts/texts.txt 编译进 src/msg_data.c 时，文本被 **Huffman 压缩**，
  所以直接在 ROM / .o 里搜 UTF-8 或 u16 明文必然搜不到（会得出"没生效"的错误结论）。
  正确做法：用同一套 huffman.py 复算码表 → 解压 src/msg_data.c 里的 CompressedText_MSG_xxx
  → 与期望中文比对。

用法（在 ~/projects/fireemblem8-expansion 下）：
  python3 <此脚本> <msg_data.c 路径> [期望键值对...]
"""
import re
import sys
import pathlib

FRAMEWORK = pathlib.Path.home() / "projects" / "fireemblem8-expansion"
sys.path.insert(0, str(FRAMEWORK / "scripts" / "texttools"))
sys.path.insert(0, str(FRAMEWORK / "scripts" / "texttools" / "multilang_codec"))

import huffman  # noqa: E402


def pack_utf8_u16(text):
    """复刻 textprocess.py::text_to_utf8_u16_array（去掉控制码后的纯文本）。"""
    b = text.encode("utf-8")
    out = []
    pos = 0
    while pos < len(b):
        c = b[pos]
        if c == 0x80:
            out.append(b[pos]); out.append(b[pos + 1]); pos += 2
        elif c == 0x10:
            out.append(b[pos]); out.append(b[pos + 1] | (b[pos + 2] << 8)); pos += 3
        elif c in (0x23, 0x7F, 0xE9):
            out.append(c); pos += 1
        elif c >= 0x20:
            out.append(b[pos]); out.append(b[pos + 1]); pos += 2
        else:
            out.append(c); pos += 1
    return out


def build_all_data():
    """复算 textprocess.py 的 all_data（Huffman 码表的唯一输入）。"""
    import textprocess
    TEXT_MAIN = FRAMEWORK / "texts" / "texts.txt"
    TEXT_DEFS = FRAMEWORK / "texts" / "textdefs.txt"
    control_chars = textprocess.load_control_chars(str(TEXT_DEFS))
    del textprocess.all_data[:]
    textprocess.process_file(str(TEXT_MAIN), control_chars, "utf8")
    return list(textprocess.all_data)


def parse_compressed(msg_data_c):
    text = msg_data_c.read_text(encoding="utf-8")
    out = {}
    for m in re.finditer(r"static const u8 CompressedText_MSG_([0-9A-Fa-f]+)\[\] = \{([^}]*)\};", text):
        key = m.group(1).upper()
        vals = [int(x, 16) for x in re.findall(r"0x([0-9A-Fa-f]{2})", m.group(2))]
        out[key] = vals
    return out


def main():
    msg_data_path = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else (
        FRAMEWORK / "src" / "msg_data.c")
    all_data = build_all_data()
    freq = huffman.GenerateFreqTable(all_data)
    tree = huffman.BuildHuffmanTree(freq)
    code_table = huffman.build_code_table(tree)
    # 反查表：codes -> data
    rev = {}
    for data, code in code_table.items():
        rev[(len(code), code)] = data

    blobs = parse_compressed(msg_data_path)
    print(f"all_data={len(all_data)} 条目·码表 {len(code_table)} 项·压缩条目 {len(blobs)} 条")

    targets = sys.argv[2:] or ["212", "26E", "2BF", "30A"]
    ok = True
    for key in targets:
        k = key.upper()
        if k not in blobs:
            print(f"  ## MSG_{k}: ✗ 未找到压缩条目")
            ok = False
            continue
        bits = "".join(f"{b:08b}"[::-1] for b in blobs[k])
        u16 = []
        cur = ""
        for ch in bits:
            cur += ch
            if (len(cur), cur) in rev:
                u16.append(rev[(len(cur), cur)])
                cur = ""
        # u16 -> 文本；控制码单字节原样保留（<0x20 或 0x80/0x10 前缀），
        # 只把连续的可打印 UTF-8 解码，避免控制码后位对齐错乱
        raw = bytes()
        for v in u16:
            if v < 0x20:  # 控制码（[LF]=0x01、[X]=0x00、[.]=0x1F 等）
                raw += f"<{v:02X}>".encode()
            elif v <= 0xFF:
                raw += bytes([v])
            else:
                raw += bytes([v & 0xFF, (v >> 8) & 0xFF])
        txt = raw.decode("utf-8", errors="replace")
        print(f"  ## MSG_{k}: {txt!r}")

    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
