#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
山河烬 崩溃捕手（直连 GDB remote 协议，单 socket 常驻）

为什么不用 gdb-multiarch：
  - mGBA 的 GDB stub 是"单连接、断开即卡死"的
  - gdb 批处理模式下 continue/interrupt 不好控制
直接用 socket 说 GDB remote 协议，最稳。

用法:
  python3 shanhe-crash-catcher.py                 # 默认端口 2345
  SHANHE_POLL=0.3 python3 shanhe-crash-catcher.py

产出:
  /tmp/shanhe-crash/watch.log       运行日志（PC 采样）
  /tmp/shanhe-crash/crash-site.txt  崩溃现场（若捕获）
"""
import socket, time, os, sys

PORT      = int(os.environ.get("SHANHE_GDB_PORT", "2345"))
HOST      = os.environ.get("SHANHE_GDB_HOST", "localhost")
LOGDIR    = os.environ.get("SHANHE_LOGDIR", "/tmp/shanhe-crash")
POLL      = float(os.environ.get("SHANHE_POLL", "0.4"))
MAXITER   = int(os.environ.get("SHANHE_MAXITER", "2400"))

os.makedirs(LOGDIR, exist_ok=True)
LOG  = os.path.join(LOGDIR, "watch.log")
DUMP = os.path.join(LOGDIR, "crash-site.txt")
_fh  = open(LOG, "a")

def log(s):
    line = str(s)
    _fh.write(line + "\n"); _fh.flush()
    print(line, flush=True)

REG_NAMES = ["r0","r1","r2","r3","r4","r5","r6","r7",
             "r8","r9","r10","r11","r12","sp","lr","pc"]

def legal(pc):
    return (pc <= 0x00003FFF) or \
           (0x02000000 <= pc <= 0x0203FFFF) or \
           (0x03000000 <= pc <= 0x03007FFF) or \
           (0x08000000 <= pc <= 0x0DFFFFFF)

class GdbRemote:
    def __init__(self, host, port):
        self.s = socket.create_connection((host, port), timeout=10)
        self.s.settimeout(10)
        self.buf = b""

    def _recv_byte(self):
        while not self.buf:
            d = self.s.recv(4096)
            if not d:
                raise EOFError("connection closed")
            self.buf += d
        b = self.buf[:1]; self.buf = self.buf[1:]
        return b

    def send(self, data):
        if isinstance(data, str):
            data = data.encode()
        csum = sum(data) & 0xFF
        self.s.sendall(b"$" + data + b"#" + ("%02x" % csum).encode())

    def recv_packet(self, timeout=10):
        self.s.settimeout(timeout)
        # 跳过 + / - / 其它杂字节，直到 '$'
        while True:
            b = self._recv_byte()
            if b == b"$":
                break
        data = b""
        while True:
            b = self._recv_byte()
            if b == b"#":
                cks = self.buf[:2]; self.buf = self.buf[2:]
                break
            data += b
        try:
            self.s.sendall(b"+")
        except Exception:
            pass
        return data.decode(errors="replace")

    def cmd(self, c, timeout=10):
        self.send(c)
        return self.recv_packet(timeout)

    def interrupt(self):
        """Ctrl-C 中断运行中的目标"""
        self.s.sendall(b"\x03")

    def read_regs(self):
        """g 包：读全部寄存器 -> dict"""
        r = self.cmd("g", timeout=10)
        # ARM: r0-r15 每个 4 字节小端 -> 8 hex chars
        vals = {}
        for i, name in enumerate(REG_NAMES):
            h = r[i*8:(i+1)*8]
            if len(h) < 8:
                return None
            try:
                # 小端
                b = bytes.fromhex(h)
                vals[name] = int.from_bytes(b, "little")
            except Exception:
                return None
        return vals

def main():
    log("=" * 60)
    log("会话开始 %s  -> %s:%d" % (time.strftime("%Y-%m-%d %H:%M:%S"), HOST, PORT))
    g = GdbRemote(HOST, PORT)
    log("socket 已连接")

    # 初始状态
    try:
        st = g.cmd("?", timeout=10)
        log("初始状态包: %s" % st)
    except Exception as e:
        log("读初始状态失败: %s" % e)

    regs = g.read_regs()
    if regs:
        log("初始 PC=0x%08X LR=0x%08X SP=0x%08X" % (regs["pc"], regs["lr"], regs["sp"]))

    # 让游戏跑起来
    g.send("c")
    time.sleep(0.3)
    log("已发送 continue，游戏开始运行。开始监视…")

    bad = None
    miss = 0
    for i in range(MAXITER):
        time.sleep(POLL)
        # 中断（带重试：崩溃弹窗可能短暂阻塞 stub）
        ok = False
        for attempt in range(4):
            try:
                g.interrupt()
                stop = g.recv_packet(timeout=5)
                ok = True
                break
            except Exception as e:
                if attempt == 3:
                    log("[%d] 中断持续无响应(%s)，继续重试下一轮" % (i, e))
                time.sleep(0.4)
        if not ok:
            miss += 1
            if miss > 8:
                log("[%d] 连续 %d 次无响应，判定 mGBA 已停止响应，退出" % (i, miss))
                break
            continue
        try:
            regs = g.read_regs()
        except Exception:
            regs = None
        if not regs:
            log("[%d] 寄存器读取失败" % i)
            try:
                g.send("c")
            except Exception:
                pass
            continue
        miss = 0
        pc, lr, sp = regs["pc"], regs["lr"], regs["sp"]
        if not legal(pc):
            log("[%d] !!! 非法 PC = 0x%08X (LR=0x%08X SP=0x%08X) !!!" % (i, pc, lr, sp))
            bad = regs
            break
        if i % 10 == 0:
            log("[%d] PC=0x%08X LR=0x%08X SP=0x%08X (运行中)" % (i, pc, lr, sp))
        # 继续
        try:
            g.send("c")
        except Exception as e:
            log("[%d] continue 失败: %s" % (i, e)); break
        time.sleep(0.05)

    if bad:
        out = []
        out.append("=" * 60)
        out.append("山河烬 崩溃现场  %s" % time.strftime("%Y-%m-%d %H:%M:%S"))
        out.append("=" * 60)
        out.append("PC  = 0x%08X   <-- 跳到的非法地址" % bad["pc"])
        out.append("LR  = 0x%08X   <-- 调用者/返回地址（谁跳的！）" % bad["lr"])
        out.append("SP  = 0x%08X" % bad["sp"])
        out.append("")
        for n in REG_NAMES:
            out.append("  %-4s = 0x%08X" % (n, bad[n]))
        # 读栈
        out.append("")
        out.append("--- 栈内容（SP 起 48 字）---")
        sp = bad["sp"]
        for off in range(0, 48*4, 4*4):
            try:
                rep = g.cmd("m%x,%x" % (sp + off, 4*4), timeout=5)
                raw = bytes.fromhex(rep)
                words = [int.from_bytes(raw[k:k+4], "little") for k in range(0, len(raw), 4)]
                out.append("  0x%08X: " % (sp + off) + " ".join("%08X" % w for w in words))
            except Exception as e:
                out.append("  (读 0x%08X 失败: %s)" % (sp + off, e)); break
        txt = "\n".join(out)
        open(DUMP, "w").write(txt)
        log(txt)
        log(">>> 现场已写入 %s" % DUMP)
    else:
        log("监视结束，未捕获非法 PC。")

    try:
        g.send("D")
        time.sleep(0.2)
        log("已发送 detach")
    except Exception as e:
        log("detach 失败: %s" % e)
    try:
        g.s.close()
    except Exception:
        pass

main()
