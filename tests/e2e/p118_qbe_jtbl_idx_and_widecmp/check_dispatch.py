"""Check how amd64 jump tables read their selector.

usage: python3 -E check_dispatch.py EXPECT asm FILE.s
       python3 -E check_dispatch.py EXPECT obj FILE.o   (ELF64 x86-64)
       python3 -E check_dispatch.py EXPECT both FILE.s FILE.o
EXPECT holds `name form entries` lines (forms: gen_il.py); every listed
function has exactly one table, compared against exactly `entries`. A selector
copied onto itself before the compare (a misplaced normalization) is rejected
for `direct` / `live` and must agree between the encoders. `both` additionally requires the two encoders
to agree on (entries, compare register, normalization, index register, home
load, self-copy).
"""
import re
import struct
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
        block = re.split(r'^\S+:\n', m.group(1)[:h.start()], flags=re.M)[-1]
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
    res = {}
    for name in names:
        if name not in syms:
            die(f'{path}: no symbol {name}')
        shndx, value, size = syms[name]
        if not size:
            die(f'{path}: {name} has no size')
        code = d[secs[shndx][4] + value:secs[shndx][4] + value + size]
        hits = list(OBJ.finditer(code))
        if len(hits) != 1:
            die(f'{path}: {name}: {len(hits)} recognized dispatches')
        h = hits[0]
        if h['n'] is not None:
            n, reg = h['n'][0], h['cmod'][0] & 7
        elif h['nw'] is not None:
            n, reg = struct.unpack('<I', h['nw'])[0], h['cmodw'][0] & 7
        else:
            n, reg = struct.unpack('<I', h['nax'])[0], 0
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
        # movl %reg, %reg directly before the compare (89 /r or 8b /r, mod 11).
        pre = code[:h.start() + len(h['slot'] or b'')]
        modrm = 0xc0 | (reg & 7) * 9
        tails = [bytes([0x45, op, modrm]) if reg & 8 else bytes([op, modrm]) for op in (0x89, 0x8b)]
        selfcopy = any(pre.endswith(t) and (reg & 8 or len(pre) == 2 or not 0x40 <= pre[-3] <= 0x4f) for t in tails)
        res[name] = (n, reg, h['norm'] is not None, idx, h['slot'] is not None, bool(selfcopy))
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
    print(f'p118 dispatch {mode}: {len(names)} tables, ' + ', '.join(f'{k} {v}' for k, v in sorted(tally.items())))


main()
