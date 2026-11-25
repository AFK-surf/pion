"""Check how amd64 jump tables read their selector.

usage: python3 -E check_dispatch.py EXPECT asm FILE.s
       python3 -E check_dispatch.py EXPECT obj FILE.o   (ELF64 x86-64)
       python3 -E check_dispatch.py EXPECT both FILE.s FILE.o
EXPECT holds `name form entries` lines (forms: gen_il.py); every listed
function has exactly one table, compared against exactly `entries`. A
misplaced normalization, i.e. `movl %reg, %reg` as the definition of the compare
register that reaches the compare in its block, is rejected for `direct` / `live`
and must agree between the encoders.

Objects are decoded instruction by instruction from the function entry (the
inline table is skipped, the `lea` must address it, and every branch and table
target must be an instruction); with an objdump that knows x86-64 its instruction
addresses, compare immediate, reaching definition and self-copy verdict must be
the same (P118_OBJDUMP=1 requires one,
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


R16 = ['ax', 'cx', 'dx', 'bx', 'sp', 'bp', 'si', 'di'] + [f'r{n}w' for n in range(8, 16)]
R8 = ['al', 'cl', 'dl', 'bl', 'spl', 'bpl', 'sil', 'dil'] + [f'r{n}b' for n in range(8, 16)]
REG = {name: n for names in (R64, R32, R16, R8) for n, name in enumerate(names)}
REG.update(ah=0, ch=1, dh=2, bh=3)
CALLER = {0, 1, 2, 6, 7, 8, 9, 10, 11}


def att_writes(line):
    """General registers (any width) an AT&T instruction may write."""
    line = line.split('#')[0].strip()
    m = re.match(r'(?:(?:lock|rep\w*|data16)\s+)*([a-z]\w*)\s*(.*)$', line)
    if m is None:
        return set()  # directive or blank
    op, args = m[1], re.split(r',(?![^()]*\))', m[2])
    args = [a.strip() for a in args if a.strip()]
    regs = [REG.get(a[1:]) if a.startswith('%') else None for a in args]
    if re.match(r'call', op):
        return set(CALLER)
    if re.match(r'(cmp[bwlq]?$|test|push|j|ret|nop|ucomis|comis|bt[wlq]?$|ud2|hlt|int3|leave)', op):
        return {4, 5} if op.startswith('leave') else set()
    if re.match(r'(cqto|cltd|cqo|cdq)', op):
        return {2}
    if re.match(r'(cltq|cwtl|cdqe|cwde)', op):
        return {0}
    if op == 'syscall':
        return {0, 1, 11}
    if op == 'cpuid':
        return {0, 1, 2, 3}
    if re.match(r'(movs|stos)[bwlq]?$', op) and any('%es:' in a for a in args):
        return {1, 6, 7}
    if re.match(r'i?(mul|div)[bwlq]?$', op) and len(args) == 1:
        return {0, 2}
    if re.match(r'xchg', op) and args == ['%ax', '%ax']:
        return set()  # two-byte nop
    if re.match(r'(xchg|xadd)', op):
        return {g for g in regs if g is not None}
    extra = {0} if re.match(r'cmpxchg', op) else set()
    return extra | ({regs[-1]} if regs and regs[-1] is not None else set())


def att_selfcopy(line, reg):
    return re.match(rf'\s*movl?\s+%{R32[reg]},\s*%{R32[reg]}\s*(?:#.*)?$', line) is not None


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
        # The dispatch block up to the compare.
        block = re.split(r'^(?:\S+:|\t(?:j|ret).*)\n', m.group(1)[:h.start('n')], flags=re.M)[-1].split('\n')[:-1]
        reg = R32.index(h['cmp'])
        last = next((ln for ln in reversed(block) if reg in att_writes(ln)), None)
        selfcopy = last is not None and att_selfcopy(last, reg)
        res[name] = (int(h['n']), R32.index(h['cmp']), h['src'] is not None, R64.index(h['idx']), h['slot'] is not None,
                     selfcopy)
    return res


OBJ = re.compile(
    rb'(?P<slot>\x44\x8b(?:[\x54].|[\x55].|[\x94]\x24....|[\x95]....|\x54\x24.|\x14\x24))?'
    rb'(?P<crex>\x41)?(?:\x83(?P<cmod>[\xf8-\xff])(?P<n>.)|\x81(?P<cmodw>[\xf8-\xff])(?P<nw>....)|\x3d(?P<nax>....))'
    rb'\x0f\x83....\x4c\x8d\x1d(?P<ldisp>....)'
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
    """(instruction starts -> decoded, block starts, dispatch matches)

    Every branch and table target must be an instruction of the function."""
    ins, leaders, targets, hits, p, skip = {}, {0}, set(), {}, 0, None
    while p < len(code):
        h = OBJ.match(code, p)
        if h is not None and h.end() not in hits:
            hits[h.end()] = h
            skip = (h.end(), entries(h), h)
        end, opcode, modrm, rex = ins[p] = insn(code, p)
        if end > len(code):
            die(f'{path}: {name}: instruction at {p:#x} runs past the function')
        short = opcode[0] in range(0x70, 0x80) or opcode[0] == 0xeb
        near = opcode[0] in (0xe9,) or opcode[0] == 0x0f and opcode[1] in range(0x80, 0x90)
        if short:
            targets.add(end + struct.unpack_from('<b', code, end - 1)[0])
        elif near:
            targets.add(end + struct.unpack_from('<i', code, end - 4)[0])
        if short or near or opcode == (0xc3,):
            leaders.add(end)
        p = end
        if skip is not None and p == skip[0]:
            # The inline table, 4-byte aligned in the section.
            table = (value + p + 3 & ~3) - value
            p = table + 4 * skip[1]
            if p > len(code):
                die(f'{path}: {name}: compares against {skip[1]} entries, the table runs past the function')
            base = skip[2].end('ldisp') + struct.unpack('<i', skip[2]['ldisp'])[0]
            if base != table:
                die(f'{path}: {name}: lea addresses {base:#x}, the table is at {table:#x}')
            for k in range(skip[1]):
                targets.add(table + struct.unpack_from('<i', code, table + 4 * k)[0])
            skip = None
    if not targets <= ins.keys():
        die(f'{path}: {name}: jump target {min(targets - ins.keys()):#x} is no instruction')
    return ins, leaders | targets, list(hits.values())


def writes(c, p, opcode, modrm, rex):
    """General registers (any width) the decoded instruction may write."""
    pre = set()
    while c[p] in LEGACY:
        pre.add(c[p])
        p += 1
    op, b = opcode[-1], (rex & 1) * 8
    reg = rm = None
    ext = modrm >> 3 & 7 if modrm is not None else 0
    byte = lambda n: n - 4 if not rex and 4 <= n < 8 else n  # %ah .. %bh
    if modrm is not None:
        reg = ext | (rex & 4) * 2
        rm = (modrm & 7 | b) if modrm >> 6 == 3 else None
    out = lambda *regs: {n for n in regs if n is not None}
    if len(opcode) == 1:
        narrow = not op & 1
        if op in ALU:
            if op >> 3 == 7:
                return set()
            kind = op & 7
            return out(0 if kind >= 4 else reg if kind >= 2 and not narrow else byte(reg) if kind >= 2
                       else rm if not narrow or rm is None else byte(rm))
        if op in (0x63, 0x69, 0x6b, 0x8b, 0x8d):
            return out(reg)
        if op == 0x8a:
            return out(byte(reg))
        if op in (0x80, 0x81, 0x83):
            return set() if ext == 7 else out(byte(rm) if op == 0x80 and rm is not None else rm)
        if op in (0x86, 0x87):
            return out(*(byte(n) if op == 0x86 and n is not None else n for n in (reg, rm)))
        if op in (0x88, 0x89, 0x8f, 0xc0, 0xc1, 0xc6, 0xc7, 0xd0, 0xd1, 0xd2, 0xd3, 0xfe):
            return out(byte(rm) if op != 0x8f and narrow and rm is not None else rm)
        if op == 0x90:
            return {0, 8} if b else set()
        if op == 0x98:
            return {0}
        if op == 0x99:
            return {2}
        if op in range(0x58, 0x60):
            return {op & 7 | b}
        if op in range(0xb0, 0xb8):
            return {byte(op & 7 | b)}
        if op in range(0xb8, 0xc0):
            return {op & 7 | b}
        if op == 0xc9:
            return {4, 5}
        if op == 0xe8 or op == 0xff and ext == 2:
            return set(CALLER)
        if op in (0xf6, 0xf7):
            return set() if ext < 2 else {0, 2} if ext > 3 else out(byte(rm) if narrow and rm is not None else rm)
        if op == 0xff:
            return out(rm) if ext < 2 else set()
        return set()  # push, test, branches, ret, hlt
    if op in range(0x40, 0x50) or op in (0xaf, 0xb6, 0xb7, 0xb8, 0xbc, 0xbd, 0xbe, 0xbf, 0x50, 0xc5, 0xd7, 0x2c, 0x2d):
        return out(reg)
    if op in range(0x90, 0xa0):
        return out(byte(rm) if rm is not None else rm)
    if op in (0xa4, 0xa5, 0xab, 0xac, 0xad, 0xb3, 0xbb):
        return out(rm)
    if op == 0xba:
        return set() if ext == 4 else out(rm)
    if op in (0xb0, 0xb1):
        return out(0, rm)
    if op in (0xc0, 0xc1):
        return out(reg, rm)
    if op in range(0xc8, 0xd0):
        return {op & 7 | b}
    if op == 0x7e and 0x66 in pre:
        return out(rm)
    if op == 0x05:
        return {0, 1, 11}
    if op == 0xa2:
        return {0, 1, 2, 3}
    return set()  # SSE, nop, ud2, branches


def entries(h):
    if h['n'] is not None:
        # cmpl $imm8 sign-extends.
        return struct.unpack('<b', h['n'])[0] & 0xffffffff
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
        # The definition of the compare register reaching the compare in its block.
        cmp_at = h.start() + len(h['slot'] or b'')
        top = max(q for q in leaders if q <= cmp_at)
        block = sorted((p for p in ins if top <= p < cmp_at), reverse=True)
        last = next((p for p in block if reg in writes(code, p, *ins[p][1:])), None)
        selfcopy = False
        if last is not None:
            # 32-bit movl %reg, %reg (89 /r or 8b /r, mod 11).
            _, opcode, modrm, rex = ins[last]
            selfcopy = opcode in ((0x89,), (0x8b,)) and modrm == 0xc0 | (reg & 7) * 9 \
                and rex in ((0x45,) if reg & 8 else (0, 0x40)) and code[last] not in LEGACY
        if dump is not None:
            lines = dump.get(name, {})
            if {q for q in lines if value <= q <= value + cmp_at} != {value + p for p in ins if p <= cmp_at}:
                die(f'{path}: {name}: objdump and the decoder disagree on instruction addresses')
            imm = re.match(rf'cmpl?\s+\$(-?)(0x[0-9a-f]+|\d+),\s*%{R32[reg]}\b', lines[value + cmp_at])
            if imm is None or int(imm[1] + imm[2], 0) & 0xffffffff != n:
                die(f'{path}: {name}: compares against {n}, objdump shows {lines[value + cmp_at]!r}')
            dlast = next((p for p in block if reg in att_writes(lines[value + p])), None)
            if dlast != last:
                die(f'{path}: {name}: objdump and the decoder disagree on the definition of %{R32[reg]}: {dlast} != {last}')
            if last is not None and att_selfcopy(lines[value + last], reg) != selfcopy:
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
