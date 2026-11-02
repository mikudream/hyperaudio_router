#!/usr/bin/env python3
"""重定位 DolbyRouter 的 mFlags 偏移（AudioTrack::mFlags），用于换机型/换系统。

背景
----
DolbyRouter 在 createTrack_l() 入口把 AudioTrack::mFlags 里的 FAST|PRIMARY 清掉，
让目标应用的音轨回落到普通混音轨（挂 DAP）。它把 mFlags 的结构体偏移写死在
zygisk/jni/src/abi.h 的 kOffAudioTrackFlags 里，默认 0x378 是
小米平板 6 / Android 15 的值。换机型或系统版本后该偏移几乎必然不同。

没有 NDK、无法重编译时，可以直接改 .so 里那两条指令的立即数：
    ldr w8, [x0, #<off>]
    and w8, w8, #0xfffffff9
    str w8, [x0, #<off>]
LDR/STR（无符号偏移、32 位访问）的 imm12 = 偏移/4，因此只能表示 4 字节对齐的
偏移，且长度不变 —— 补丁只改动 imm12 字段，不需要重定位，也不改变文件大小。

用法
----
    python patch_mflags_offset.py <输入.so> <输出.so> <原偏移> <新偏移>

    # 本机（REDMI K90 Pro Max / myron / Android 17）
    python patch_mflags_offset.py arm64-v8a.so arm64-v8a.myron.so 0x378 0x3c0

验证
----
脚本会打印补丁前后反汇编，并统计改动字节数（应只有 2 个字节）。
装到设备后按 README 的 AudioProbe 对照法确认。
"""
import re
import sys
import struct
import hashlib

from elftools.elf.elffile import ELFFile
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM


def find_flag_code(data, elf):
    """.text 里找 `ldr wN,[xR,#off]` + `and wN,wN,#0xffffffXX` + `str wN,[xR,#off]`
    这三条连续指令，返回 [(ldr_va, str_va, op_str), ...]。"""
    sec = elf.get_section_by_name('.text')
    base, off, size = sec['sh_addr'], sec['sh_offset'], sec['sh_size']
    code = data[off:off + size]
    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    insns = list(md.disasm(code, base))

    def disp(op_str):
        m = re.search(r'#(0x[0-9a-fA-F]+|\d+)', op_str.split('[')[-1]) if '[' in op_str else None
        return int(m.group(1), 0) if m else None

    hits = []
    for i in range(len(insns) - 2):
        a, b, c = insns[i], insns[i + 1], insns[i + 2]
        if a.mnemonic != 'ldr' or c.mnemonic != 'str':
            continue
        if b.mnemonic != 'and' or 'ffffff' not in b.op_str:
            continue
        da, dc = disp(a.op_str), disp(c.op_str)
        if da is None or da != dc:
            continue
        hits.append((a.address, c.address, a.op_str))
    return hits, (sec['sh_offset'], sec['sh_addr'])


def main():
    if len(sys.argv) != 5:
        print(__doc__)
        return 1
    src, dst, old_s, new_s = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
    OLD, NEW = int(old_s, 16), int(new_s, 16)
    if OLD % 4 or NEW % 4:
        print("偏移必须 4 字节对齐")
        return 1
    if not (0 < OLD <= 0xFFFF and 0 < NEW <= 0xFFFF):
        print("偏移超出 LDR/STR 无符号立即数范围")
        return 1

    data = bytearray(open(src, 'rb').read())
    f = open(src, 'rb')
    elf = ELFFile(f)
    hits, (text_off, text_va) = find_flag_code(bytes(data), elf)
    if not hits:
        print("未找到清 FAST|PRIMARY 的指令序列，可能不是 DolbyRouter 的 .so")
        return 1

    print(f"找到 {len(hits)} 处候选序列：")
    for ldr_va, str_va, op in hits:
        print(f"  ldr @{ldr_va:#x}  str @{str_va:#x}  ({op})")

    new_imm12 = NEW >> 2
    changed = 0
    md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
    for ldr_va, str_va, op in hits:
        for va, form in ((ldr_va, 0xB9400000), (str_va, 0xB9000000)):
            o = text_off + (va - text_va)
            word = struct.unpack_from('<I', data, o)[0]
            if (word & 0xFFC00000) != form:
                continue
            if ((word >> 10) & 0xFFF) != (OLD >> 2):
                print(f"  跳过 {va:#x}：imm12 不是 {OLD:#x}")
                continue
            struct.pack_into('<I', data, o, (word & ~(0xFFF << 10)) | (new_imm12 << 10))
            changed += 1

    if changed == 0:
        print(f"没有需要改的指令（当前偏移可能已经是 {NEW:#x}）")
        return 1

    open(dst, 'wb').write(data)
    print(f"\n改了 {changed} 条指令。复核反汇编：")
    sec = elf.get_section_by_name('.text')
    for ins in md.disasm(bytes(data[sec['sh_offset']:sec['sh_offset'] + sec['sh_size']]),
                         sec['sh_addr']):
        if any(ins.address in (a, b) for a, b, _ in hits):
            print(f"  {ins.address:#x}: {ins.mnemonic:<7} {ins.op_str}")

    a, b = open(src, 'rb').read(), bytes(data)
    diff = [i for i in range(len(a)) if a[i] != b[i]]
    print(f"\n变化字节: {len(diff)} 处 {[hex(i) for i in diff]}")
    print(f"原 md5: {hashlib.md5(a).hexdigest()}")
    print(f"新 md5: {hashlib.md5(b).hexdigest()}")
    print(f"大小: {len(a)} -> {len(b)}")
    return 0


if __name__ == '__main__':
    sys.exit(main())
