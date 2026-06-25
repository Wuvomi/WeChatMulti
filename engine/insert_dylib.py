#!/usr/bin/env python3
# insert_dylib.py — 给一个 Mach-O(支持 fat)在每个 arch slice 里追加一条
# LC_LOAD_DYLIB,使其在被 dlopen/加载时一并加载指定的 dylib。
#
# 用法: insert_dylib.py <dylib_path> <macho_in> [macho_out]
#   dylib_path  例 @rpath/WeChatMultiEngine.dylib
#   不指定 out 则原地修改(会先校验有足够的 header 余量)。
#
# 设计要点(为何能成功):
#   - LC_LOAD_DYLIB 必须放在已有 load commands 之后、且不能覆盖到第一个段的
#     文件数据。Mach-O header 与第一段数据之间通常有 padding(__TEXT 段开头
#     的对齐空洞)。我们在原 ncmds 尾部就地插入新命令,并把后续命令整体不动
#     (因为我们追加在最末尾),只需保证 sizeofcmds + 新命令 <= 首段文件偏移。
#   - 更新 mach_header 的 ncmds 与 sizeofcmds。
#   - 不重新签名(调用方负责后续 codesign)。

import sys, struct

MH_MAGIC_64 = 0xFEEDFACF
MH_CIGAM_64 = 0xCFFAEDFE
FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA
LC_LOAD_DYLIB = 0x0C
LC_SEGMENT_64 = 0x19

def align(x, a):
    return (x + (a - 1)) & ~(a - 1)

def build_dylib_cmd(path):
    # struct dylib_command: cmd, cmdsize, name.offset, timestamp, current_ver, compat_ver
    name = path.encode() + b"\x00"
    # name 跟在 24 字节固定头后,按 8 对齐整条命令
    cmdsize = align(24 + len(name), 8)
    payload = struct.pack("<IIIIII",
                          LC_LOAD_DYLIB,
                          cmdsize,
                          24,            # name offset = sizeof fixed part
                          0,             # timestamp
                          0,             # current_version
                          0)             # compatibility_version
    payload += name
    payload += b"\x00" * (cmdsize - len(payload))
    return payload

def first_segment_fileoff(data, slice_off, be):
    # 返回最小的非零 __TEXT/段文件起点之外的可用空间;实际我们要的是
    # "load commands 区之后到第一段实际文件数据起点的余量"。
    end = "<" if not be else ">"
    magic, cputype, cpusub, filetype, ncmds, sizeofcmds, flags, _ = \
        struct.unpack_from(end + "IiiIIIII", data, slice_off)
    cmds_start = slice_off + 32
    off = cmds_start
    # 我们要的"余量上限" = 第一个 section 的文件数据起点(__text 等),因为
    # load commands 之后到首个 section 之间是 header padding,可写新命令。
    # 用 section.offset(非 0 的最小值)才正确;段 fileoff 对 __TEXT 是 0(段含 header)。
    min_secoff = None
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from(end + "II", data, off)
        if cmd == LC_SEGMENT_64:
            nsects = struct.unpack_from(end + "I", data, off + 64)[0]
            sec = off + 72  # segment_command_64 固定头 72 字节
            for _s in range(nsects):
                # section_64: sectname16, segname16, addr8, size8, offset4(@ +48)
                sec_offset = struct.unpack_from(end + "I", data, sec + 48)[0]
                if sec_offset != 0:
                    if min_secoff is None or sec_offset < min_secoff:
                        min_secoff = sec_offset
                sec += 80  # sizeof section_64
        off += cmdsize
    return ncmds, sizeofcmds, cmds_start, min_secoff

def patch_slice(data, slice_off, dylib_path):
    be = data[slice_off:slice_off+4] in (b"\xfe\xed\xfa\xcf",)  # big-endian magic bytes
    # 实测 macOS arm64/x86_64 都是 little-endian;保留判断但默认小端
    le_magic = struct.unpack_from("<I", data, slice_off)[0]
    if le_magic not in (MH_MAGIC_64,):
        raise RuntimeError("仅支持 64 位小端 Mach-O slice, magic=0x%x" % le_magic)
    end = "<"
    magic, cputype, cpusub, filetype, ncmds, sizeofcmds, flags, reserved = \
        struct.unpack_from(end + "IiiIIIII", data, slice_off)
    _, _, cmds_start, min_secoff = first_segment_fileoff(data, slice_off, False)

    cmd = build_dylib_cmd(dylib_path)
    insert_at = cmds_start + sizeofcmds
    new_sizeofcmds = sizeofcmds + len(cmd)

    # 余量校验: header(32) + new_sizeofcmds 必须 <= 第一个 section 文件数据起点
    if min_secoff is not None and (32 + new_sizeofcmds) > min_secoff:
        raise RuntimeError(
            "header 余量不足: 需要 %d, 仅有 %d (无法就地插入 LC_LOAD_DYLIB)"
            % (32 + new_sizeofcmds, min_secoff))

    # 就地写入:把新命令字节覆盖到 load command 区尾部的 padding 上。
    data[insert_at:insert_at+len(cmd)] = cmd
    # 更新 ncmds, sizeofcmds
    struct.pack_into(end + "II", data, slice_off + 16, ncmds + 1, new_sizeofcmds)
    return True

def main():
    if len(sys.argv) < 3:
        print("usage: insert_dylib.py <dylib_path> <macho_in> [macho_out]", file=sys.stderr)
        sys.exit(2)
    dylib_path = sys.argv[1]
    macho_in = sys.argv[2]
    macho_out = sys.argv[3] if len(sys.argv) > 3 else macho_in

    with open(macho_in, "rb") as f:
        data = bytearray(f.read())

    magic = struct.unpack_from(">I", data, 0)[0]
    if magic in (FAT_MAGIC, FAT_CIGAM):
        nfat = struct.unpack_from(">I", data, 4)[0]
        offs = []
        for i in range(nfat):
            base = 8 + i*20
            cputype, cpusub, offset, size, align_ = struct.unpack_from(">iiIII", data, base)
            offs.append(offset)
        for off in offs:
            patch_slice(data, off, dylib_path)
            print("[insert_dylib] patched slice @0x%x" % off)
    else:
        patch_slice(data, 0, dylib_path)
        print("[insert_dylib] patched thin macho")

    with open(macho_out, "wb") as f:
        f.write(data)
    print("[insert_dylib] wrote %s (+LC_LOAD_DYLIB %s)" % (macho_out, dylib_path))

if __name__ == "__main__":
    main()
