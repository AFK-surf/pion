"""Check how amd64 jump tables read their selector.

usage: python3 -E check_dispatch.py EXPECT asm FILE.s
       python3 -E check_dispatch.py EXPECT obj FILE.o   (ELF64 x86-64)
       python3 -E check_dispatch.py EXPECT both FILE.s FILE.o
EXPECT holds `name form entries` lines (forms: gen_il.py); every listed
function has exactly one table, compared against exactly `entries`. A selector
copied onto itself before the compare (a misplaced normalization) is rejected
for `direct` / `live` and must agree between the encoders.

Objects are decoded instruction by instruction from the function entry (the
inline table is skipped); with an objdump that knows x86-64 its instruction
addresses and self-copy verdict must be the same (P118_OBJDUMP=1 requires one,
for hosts whose toolchain has it). `both` additionally requires the two encoders
to agree on (entries, compare register, normalization, index register, home
load, self-copy).
"""
import os
import re
import shutil
import struct
import subprocess
import sys

R64 = ['rax', 'rcx', 'rdx', 'rbx', 'rsp', 'rbp', 'rsi', 'rdi'] + [f'r{n}' for n in range(8, 16)]
R32 = ['eax', 'ecx', 'edx', 'ebx', 'esp', 'ebp', 'esi', 'edi'] + [f'r{n}d' for n in range(8, 16)]


def die(msg):
    raise SystemExit(f'FAIL: p118 dispatch: {msg}')


ASM = re.compile(
    r'(?P<slot>\tmovl -?\d*\(%r[bs]p\), %r10d\n)?'
    r'\tcmpl \$(?P<n>\d+), %(?P<cmp>\w+)\n\tjae \S+\n\tleaq \S+\(%rip\), %r11\n'
    r'(?:\tmovl %(?P<src>\w+), %r10d\n)?'
    r'\tmovslq \(%r11,%(?P<idx>\w+),4\), %r10\n\taddq %r10, %r11\n\tjmpq \*%r11\n')


def parse_asm(path, names):
    text = open(path).read()
    res = {}
    for name in names:
        m = re.search(r'^_?' + re.escape(name) + r':\n(.*?)^/\* end function ' + re.escape(name) + r' \*/', text, re.M | re.S)
        if m is None:
            die(f'{path}: no function {name}')
        hits = list(ASM.finditer(m.group(1)))
        if len(hits) != 1 or m.group(1).count('\tjmpq *') != 1:
            die(f'{path}: {name}: {len(hits)} recognized dispatches, {m.group(1).count("jmpq *")} indirect jumps')
        h = hits[0]
        if h['cmp'] not in R32 or h['idx'] not in R64:
            die(f'{path}: {name}: unexpected registers {h.groupdict()}')
        if h['src'] is not None and h['src'] != h['cmp']:
            die(f'{path}: {name}: normalizes {h["src"]}, compares {h["cmp"]}')
        # Everything of the dispatch block before the compare.
        block = re.split(r'^(?:\S+:|\t(?:j|ret).*)\n', m.group(1)[:h.start()], flags=re.M)[-1]
        selfcopy = re.search(rf'^\tmovl %{h["cmp"]}, %{h["cmp"]}$', block, re.M) is not None
        res[name] = (int(h['n']), R32.index(h['cmp']), h['src'] is not None, R64.index(h['idx']), h['slot'] is not None,
                     selfcopy)
    return res


OBJ = re.compile(
    rb'(?P<slot>\x44\x8b(?:[\x54].|[\x55].|[\x94]\x24....|[\x95]....|\x54\x24.|\x14\x24))?'
    rb'(?P<crex>\x41)?(?:\x83(?P<cmod>[\xf8-\xff])(?P<n>.)|\x81(?P<cmodw>[\xf8-\xff])(?P<nw>....)|\x3d(?P<nax>....))'
    rb'\x0f\x83....\x4c\x8d\x1d....'
    rb'(?P<norm>(?P<nrex>[\x41\x45])\x89(?P<nmod>.))?'
    rb'(?P<irex>[\x4d\x4f])\x63\x14(?P<sib>.)\x4d\x01\xd3\x41\xff\xe3', re.S)


objdump_used = False
LEGACY = {0x26, 0x2e, 0x36, 0x3e, 0x64, 0x65, 0x66, 0xf0, 0xf2, 0xf3}
NOARG = set(range(0x50, 0x60)) | {0x90, 0x98, 0x99, 0xc3, 0xc9, 0xcc, 0xf4}
IMM8 = {0x6a, 0xa8, 0xeb} | set(range(0x70, 0x80)) | set(range(0xb0, 0xb8))
IMM32 = {0x68, 0xa9, 0xe8, 0xe9}
MODRM = {0x63, 0x8d, 0x8f, 0xfe, 0xff} | set(range(0x84, 0x8c)) | set(range(0xd0, 0xd4))
MODRM_IMM8 = {0x6b, 0x80, 0x83, 0xc0, 0xc1, 0xc6}
MODRM_IMM32 = {0x69, 0x81, 0xc7}
ALU = range(0x40)  # add / or / adc / sbb / and / sub / xor / cmp


def insn(c, p):
    """(end, opcode bytes, modrm or None, rex) of the instruction at c[p]."""
    start, osz, rex, imm, modrm = p, 4, 0, 0, None
    while c[p] in LEGACY:
        osz = 2 if c[p] == 0x66 else osz
        p += 1
    if c[p] & 0xf0 == 0x40:
        rex = c[p]
        p += 1
    op = c[p]
    p += 1
    if op == 0x0f:
        op2 = c[p]
        p += 1
        has = True
        if op2 in (0x38, 0x3a):
            p += 1
            imm = 1 if op2 == 0x3a else 0
        elif op2 in range(0x80, 0x90):
            has, imm = False, 4
        elif op2 in (0x05, 0x0b, 0xa2) or op2 in range(0xc8, 0xd0):
            has = False
        elif op2 in (0x70, 0x71, 0x72, 0x73, 0xa4, 0xac, 0xba, 0xc2, 0xc4, 0xc5, 0xc6):
            imm = 1
        opcode = (0x0f, op2)
    else:
        opcode, has = (op,), False
        if op in ALU and op & 7 < 4 or op in MODRM:
            has = True
        elif op in ALU and op & 7 == 4 or op in IMM8:
            imm = 1
        elif op in ALU and op & 7 == 5 or op in IMM32:
            imm = osz if op in ALU or op in (0x68, 0xa9) else 4
        elif op in MODRM_IMM8:
            has, imm = True, 1
        elif op in MODRM_IMM32:
            has, imm = True, osz
        elif op in (0xf6, 0xf7):
            has = True
            if c[p] >> 3 & 7 < 2:
                imm = 1 if op == 0xf6 else osz
        elif op in range(0xb8, 0xc0):
            imm = 8 if rex & 8 else osz
        elif op not in NOARG:
            die(f'unknown opcode {op:#x} at {start:#x} in {c.hex()}')
    if has:
        modrm = c[p]
        p += 1
        mod, rm = modrm >> 6, modrm & 7
        if mod != 3:
            base = rm
            if rm == 4:
                base = c[p] & 7
                p += 1
            p += 1 if mod == 1 else 4 if mod == 2 or base == 5 else 0
    return p + imm, opcode, modrm, rex


def decode(path, name, code, value):
    """(instruction starts -> decoded, block starts, dispatch matches)"""
    ins, leaders, hits, p, skip = {}, {0}, {}, 0, None
    while p < len(code):
        h = OBJ.match(code, p)
        if h is not None and h.end() not in hits:
            hits[h.end()] = h
            skip = (h.end(), entries(h))
        end, opcode, modrm, rex = ins[p] = insn(code, p)
        if end > len(code):
            die(f'{path}: {name}: instruction at {p:#x} runs past the function')
        short = opcode[0] in range(0x70, 0x80) or opcode[0] == 0xeb
        near = opcode[0] in (0xe9,) or opcode[0] == 0x0f and opcode[1] in range(0x80, 0x90)
        if short:
            leaders.add(end + struct.unpack_from('<b', code, end - 1)[0])
        elif near:
            leaders.add(end + struct.unpack_from('<i', code, end - 4)[0])
        if short or near or opcode == (0xc3,):
            leaders.add(end)
        p = end
        if skip is not None and p == skip[0]:
            # The inline table, 4-byte aligned in the section.
            table = (value + p + 3 & ~3) - value
            p = table + 4 * skip[1]
            for k in range(skip[1]):
                leaders.add(table + struct.unpack_from('<i', code, table + 4 * k)[0])
            skip = None
    if not leaders - {len(code)} <= ins.keys():
        die(f'{path}: {name}: jump target between instructions')
    return ins, leaders, list(hits.values())


def entries(h):
    if h['n'] is not None:
        return h['n'][0]
    return struct.unpack('<I', h['nw'] if h['nw'] is not None else h['nax'])[0]


def objdump(path):
    """function -> {address: text}, or None without an x86-64 objdump"""
    for tool in ('objdump', 'llvm-objdump'):
        exe = shutil.which(tool)
        if exe is None:
            continue
        r = subprocess.run([exe, '-d', '--no-show-raw-insn', path], capture_output=True, text=True)
        res, cur = {}, None
        for ln in r.stdout.split('\n'):
            m = re.match(r'[0-9a-f]+ <([^>]+)>:$', ln)
            if m is not None:
                cur = res.setdefault(m[1], {})
                continue
            m = re.match(r'\s*([0-9a-f]+):\s+(\S.*)$', ln)
            if m is not None and cur is not None:
                cur[int(m[1], 16)] = m[2]
        if r.returncode == 0 and any(res.values()):
            return res
    if os.environ.get('P118_OBJDUMP') == '1':
        die(f'{path}: no objdump disassembles x86-64')
    return None


def parse_obj(path, names):
    d = open(path, 'rb').read()
    if d[:6] != b'\x7fELF\x02\x01' or struct.unpack_from('<H', d, 18)[0] != 62:
        die(f'{path}: not an ELF64 x86-64 object')
    shoff = struct.unpack_from('<Q', d, 40)[0]
    shnum = struct.unpack_from('<H', d, 60)[0]
    secs = [struct.unpack_from('<IIQQQQIIQQ', d, shoff + 64 * k) for k in range(shnum)]
    syms = {}
    for s in secs:
        if s[1] != 2:
            continue
        strtab = secs[s[6]]
        for off in range(s[4], s[4] + s[5], 24):
            nm, info, _, shndx, value, size = struct.unpack_from('<IBBHQQ', d, off)
            end = d.index(b'\0', strtab[4] + nm)
            syms[d[strtab[4] + nm:end].decode()] = (shndx, value, size)
    global objdump_used
    dump = objdump(path)
    objdump_used = dump is not None
    res = {}
    for name in names:
        if name not in syms:
            die(f'{path}: no symbol {name}')
        shndx, value, size = syms[name]
        if not size:
            die(f'{path}: {name} has no size')
        code = d[secs[shndx][4] + value:secs[shndx][4] + value + size]
        ins, leaders, hits = decode(path, name, code, value)
        if len(hits) != 1:
            die(f'{path}: {name}: {len(hits)} recognized dispatches')
        h = hits[0]
        n, cmod = entries(h), h['cmod'] or h['cmodw']
        reg = cmod[0] & 7 if cmod else 0
        reg |= 8 if h['crex'] else 0
        sib = h['sib'][0]
        if sib >> 6 != 2 or sib & 7 != 3:
            die(f'{path}: {name}: table load SIB {sib:#x}')
        idx = (sib >> 3 & 7) | (8 if h['irex'] == b'\x4f' else 0)
        if h['norm'] is not None:
            # movl %reg, %r10d: rm = r10 (REX.B, mod 11, rm 010), reg = compare register.
            mod = h['nmod'][0]
            src = (mod >> 3 & 7) | (8 if h['nrex'] == b'\x45' else 0)
            if mod & 0xc7 != 0xc2 or src != reg:
                die(f'{path}: {name}: unexpected normalization {h["norm"].hex()}')
        # 32-bit movl %reg, %reg (89 /r or 8b /r, mod 11) in the dispatch block.
        cmp_at = h.start() + len(h['slot'] or b'')
        block = [p for p in ins if max(q for q in leaders if q <= cmp_at) <= p < cmp_at]
        rexes = (0x45,) if reg & 8 else (0, 0x40)
        selfcopy = any(ins[p][1] in ((0x89,), (0x8b,)) and ins[p][2] == 0xc0 | (reg & 7) * 9 and ins[p][3] in rexes
                       and not set(code[p:p + 1]) & LEGACY for p in block)
        if dump is not None:
            lines = dump.get(name, {})
            want = {value + p for p in ins if p <= cmp_at}
            if {q for q in lines if value <= q <= value + cmp_at} != want:
                die(f'{path}: {name}: objdump and the decoder disagree on instruction addresses')
            same = re.compile(rf'movl?\s+%{R32[reg]},\s*%{R32[reg]}\b')
            if selfcopy != any(same.match(lines[value + p]) for p in block):
                die(f'{path}: {name}: objdump and the decoder disagree on a self-copy')
        res[name] = (n, reg, h['norm'] is not None, idx, h['slot'] is not None, selfcopy)
    return res


def form(r):
    n, reg, norm, idx, slot, selfcopy = r
    if selfcopy and not norm:
        return 'bad'
    if slot:
        return 'slot' if reg == 10 and not norm and idx == 10 else 'bad'
    if norm:
        return ('norm' if reg == 10 else 'livenorm') if idx == 10 and reg != 11 else 'bad'
    if idx != reg or reg in (4, 11):
        return 'bad'
    return 'direct' if reg == 10 else 'live'


def main():
    expect = [ln.split() for ln in open(sys.argv[1]).read().split('\n') if ln.strip()]
    if any(len(e) != 3 for e in expect):
        die('malformed expectation line')
    names = [e[0] for e in expect]
    if not names or len(set(names)) != len(names):
        die('bad expectation file')
    mode, files = sys.argv[2], sys.argv[3:]
    got = []
    if mode in ('asm', 'both'):
        got.append(parse_asm(files[0], names))
    if mode in ('obj', 'both'):
        got.append(parse_obj(files[-1], names))
    tally, wrong = {}, []
    for name, want, entries in expect:
        for g in got:
            f = form(g[name])
            if g[name][0] != int(entries):
                wrong.append(f'{name} compares against {g[name][0]}, want {entries} entries')
            if f != want:
                wrong.append(f'{name} is {f} {g[name]}, want {want}')
        if len(got) == 2 and got[0][name] != got[1][name]:
            wrong.append(f'{name}: text {got[0][name]} != --obj {got[1][name]}')
        tally[f] = tally.get(f, 0) + 1
    if wrong:
        die(f'{files}: ' + '; '.join(wrong))
    tool = f', {len(names)} cross-checked with objdump' if objdump_used else ''
    print(f'p118 dispatch {mode}: {len(names)} tables, ' + ', '.join(f'{k} {v}' for k, v in sorted(tally.items())) + tool)


main()
