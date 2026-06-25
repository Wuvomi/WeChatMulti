#!/usr/bin/env python3
# locate_gate1.py — 在 loader(Contents/MacOS/WeChat)的 arm64 slice 里,按特征码
# 定位第①门(mach bootstrap 单例分支)的那条 `cbz w0, <relaunch>`,输出其
# fat 文件偏移,供安装脚本就地 patch 成无条件 `b`。
#
# 不硬编码任何 build 偏移。用 lipo 现取 arm64 slice 起点,再在 slice 内扫特征码。
#
# 特征码(来自 4.1.11 build,与具体偏移解耦):
#   单例检查函数返回布尔到 w0,存栈后立即条件分支:
#       str w0, [sp, #0x70]      ; e0 73 00 b9
#       cbz w0, <relaunch+_exit> ; 32-bit CBZ, Rt = w0
#   即连续 8 字节:  E0 73 00 B9  <cbz w0,#imm>
#   其中 cbz w0 的判定(ARM64 CBZ 编码):
#       bit31 = 0 (32-bit, CBZ 而非 CBNZ -> bit24=0)
#       bits[30:25] = 0b011010  -> 字节[3] == 0x34
#       bits[4:0] (Rt) == 0      -> w0
#   patch: 把该 cbz 改成等价目标的无条件 b(保留 imm19 的位移,转成 b 的 imm26)。
#
# 用法: locate_gate1.py <loader_path>
# 输出(便于脚本解析): KEY=VALUE 行
#   ARM64_SLICE_OFF=<dec>
#   GATE1_SLICE_OFF=<hex>
#   GATE1_FAT_OFF=<hex>
#   GATE1_ORIG=<hex bytes of the cbz word>
#   GATE1_PATCH=<hex bytes of replacement b word>

import sys, struct, subprocess, re

def arm64_slice_offset(path):
    out = subprocess.check_output(["lipo", "-detailed_info", path], text=True)
    # 找到 "architecture arm64" 段落里的 offset
    blocks = re.split(r"architecture ", out)
    for b in blocks:
        if b.startswith("arm64"):
            m = re.search(r"offset (\d+)", b)
            if m:
                return int(m.group(1))
    # thin arm64?
    f = subprocess.check_output(["file", path], text=True)
    if "arm64" in f and "universal" not in f:
        return 0
    raise RuntimeError("找不到 arm64 slice offset")

def is_cbz_w0(word):
    # 32-bit CBZ Wt: opcode bits — byte[3]==0x34, Rt(bits4:0)==0
    b3 = (word >> 24) & 0xFF
    rt = word & 0x1F
    return b3 == 0x34 and rt == 0

def cbz_to_b(word):
    # CBZ imm19 在 bits[23:5]。目标 = PC + (sext(imm19)<<2)。
    imm19 = (word >> 5) & 0x7FFFF
    if imm19 & (1 << 18):
        imm19 -= (1 << 19)  # sign extend
    # 无条件 B: opcode 0b000101 << 26 | imm26. imm26 = 同样的(目标-PC)>>2。
    imm26 = imm19 & 0x3FFFFFF
    b_word = (0b000101 << 26) | imm26
    return b_word & 0xFFFFFFFF

def is_b(word):
    # 无条件 B: bits[31:26] == 0b000101
    return (word >> 26) == 0b000101

def b_to_cbz_w0(word):
    # 已 patch 状态:从无条件 b 反推原 cbz w0(同样位移,转回 imm19)。
    imm26 = word & 0x3FFFFFF
    if imm26 & (1 << 25):
        imm26 -= (1 << 26)  # sign extend
    imm19 = imm26 & 0x7FFFF
    return (0x34 << 24) | (imm19 << 5)  # cbz w0(Rt=0)

def main():
    if len(sys.argv) < 2:
        print("usage: locate_gate1.py <loader_path>", file=sys.stderr); sys.exit(2)
    path = sys.argv[1]
    arm = arm64_slice_offset(path)
    with open(path, "rb") as f:
        f.seek(arm)
        # 读整个 arm64 slice(到文件尾或下一个 slice;简单起见读到 EOF)
        blob = f.read()

    SIG = bytes.fromhex("e07300b9")  # str w0, [sp, #0x70]
    cbz_hits, b_hits = [], []
    i = 0
    while True:
        j = blob.find(SIG, i)
        if j < 0:
            break
        nxt = blob[j+4:j+8]
        if len(nxt) == 4:
            word = struct.unpack("<I", nxt)[0]
            if is_cbz_w0(word):
                cbz_hits.append((j+4, word))   # 干净(未patch)
            elif is_b(word):
                b_hits.append((j+4, word))     # 已patch(cbz 已被改成 b)
        i = j + 4

    # 优先未patch的 cbz(全新安装);没有则取已patch的 b(重装幂等)。
    if cbz_hits:
        slice_off, word = cbz_hits[0]
        orig, patched = word, cbz_to_b(word)
        if len(cbz_hits) > 1:
            print("WARN: cbz 命中 %d 处,取第一处" % len(cbz_hits), file=sys.stderr)
    elif b_hits:
        slice_off, word = b_hits[0]
        orig, patched = b_to_cbz_w0(word), word   # 已patch:当前即patch,反推原cbz
        print("INFO: 门①已是 patched 状态(b),重装将跳过 patch", file=sys.stderr)
    else:
        print("NO_MATCH", file=sys.stderr); sys.exit(1)
    fat_off = arm + slice_off

    print("ARM64_SLICE_OFF=%d" % arm)
    print("GATE1_SLICE_OFF=0x%x" % slice_off)
    print("GATE1_FAT_OFF=0x%x" % fat_off)
    print("GATE1_ORIG=%08x" % orig)
    print("GATE1_PATCH=%08x" % patched)
    # 也给小端字节串,便于直接写盘
    print("GATE1_ORIG_LE=%s" % struct.pack("<I", orig).hex())
    print("GATE1_PATCH_LE=%s" % struct.pack("<I", patched).hex())

if __name__ == "__main__":
    main()
