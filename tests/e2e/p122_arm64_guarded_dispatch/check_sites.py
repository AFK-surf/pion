#!/usr/bin/env python3
"""Count indirect dispatch branches per function in QBE output.

usage: check_sites.py EXPECT TARGET FILE.s [FILE.o]
EXPECT lines: `<function> <tables> <arm64_apple sites>`. On arm64_apple every
function must have exactly its listed number of `br` sites; on every other
target exactly one indirect branch per jump table (replicatedispatch is
arm64_apple only). With FILE.o (arm64_apple `--obj` Mach-O), the number of
`br xN` words in each function's __text range must equal the text count.
Functions of FILE.s missing from EXPECT are not checked.
"""
import re
import struct
import sys

BR = {
    'arm64_apple': r'^\tbr\tx\d+$',
    'arm64': r'^\tbr\tx\d+$',
    'amd64_sysv': r'^\tjmpq \*%\w+$',
    'amd64_win': r'^\tjmpq \*%\w+$',
    'amd64_apple': r'^\tjmpq \*%\w+$',
    'rv64': r'^\tjr \w+$',
}


def fail(msg):
    raise SystemExit(f'FAIL: p122 {msg}')


def functions(text):
    out = {}
    for m in re.finditer(r'^_?([A-Za-z_.$][\w.$]*):\n(.*?)^/\* end function (\S+) \*/$', text, re.M | re.S):
        if m[1] != m[3]:
            continue
        out[m[1]] = m[2]
    return out


def macho_counts(path):
    data = open(path, 'rb').read()
    magic, _, _, _, ncmds, _, _, _ = struct.unpack_from('<IiiIIIII', data, 0)
    if magic != 0xfeedfacf:
        fail(f'{path}: not a 64-bit Mach-O object')
    off = 32
    text = None
    sym = None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from('<II', data, off)
        if cmd == 0x19:  # LC_SEGMENT_64
            nsect = struct.unpack_from('<I', data, off + 64)[0]
            for k in range(nsect):
                s = off + 72 + 80 * k
                sect = data[s:s + 16].rstrip(b'\0')
                seg = data[s + 16:s + 32].rstrip(b'\0')
                if sect == b'__text' and seg == b'__TEXT':
                    addr, ssize = struct.unpack_from('<QQ', data, s + 32)
                    foff = struct.unpack_from('<I', data, s + 48)[0]
                    text = (addr, data[foff:foff + ssize], k + 1)
        elif cmd == 0x2:  # LC_SYMTAB
            sym = struct.unpack_from('<IIII', data, off + 8)
        off += size
    if text is None or sym is None:
        fail(f'{path}: no __TEXT,__text or no symbol table')
    addr, body, sect = text
    symoff, nsyms, stroff, _ = sym
    starts = []
    for k in range(nsyms):
        strx, ntype, nsect, _, value = struct.unpack_from('<IBBhQ', data, symoff + 16 * k)
        if ntype & 0xe0 or nsect != sect:
            continue
        name = data[stroff + strx:data.index(b'\0', stroff + strx)].decode()
        starts.append((value - addr, name[1:] if name.startswith('_') else name))
    starts.sort()
    out = {}
    for k, (s, name) in enumerate(starts):
        e = starts[k + 1][0] if k + 1 < len(starts) else len(body)
        n = 0
        for p in range(s - s % 4, e, 4):
            w = struct.unpack_from('<I', body, p)[0]
            if w & 0xfffffc1f == 0xd61f0000:  # br xN
                n += 1
        out[name] = n
    return out


def main():
    expect_path, target, asm = sys.argv[1:4]
    obj = sys.argv[4] if len(sys.argv) > 4 else None
    expect = {}
    for line in open(expect_path):
        name, tables, sites = line.split()
        expect[name] = (int(tables), int(sites))
    fns = functions(open(asm).read())
    pat = re.compile(BR[target], re.M)
    counts = {}
    for name, (tables, sites) in expect.items():
        if name not in fns:
            fail(f'{target}: function {name} not found in {asm}')
        got = len(pat.findall(fns[name]))
        want = sites if target == 'arm64_apple' else tables
        if got != want:
            fail(f'{target}: {name} has {got} indirect branches, want {want}')
        counts[name] = got
    if obj is not None:
        if target != 'arm64_apple':
            fail('--obj check is for arm64_apple')
        oc = macho_counts(obj)
        for name, n in counts.items():
            if oc.get(name) != n:
                fail(f'{obj}: {name} has {oc.get(name)} br words, text has {n}')
    total = sum(counts.values())
    print(f'p122 {target}: {len(counts)} functions, {total} indirect branches as expected'
          + (' (text == --obj)' if obj else ''))


main()
