"""P128 structural checks (ELF64 objects / executables and Wasm32 modules).

  check.py elf <obj.o>        -- `.shstrtab` suffix sharing and section symbols
                                 for private literals (QBE amd64 ELF writer)
  check.py objcmp <a.o> <b.o> -- a direct and a GAS object agree: allocated
                                 sections other than `.text` byte for byte with
                                 the same relocation targets, and every `.text`
                                 section refers to the same literals in the
                                 same order with the same relocation types
  check.py litsym <o> section|named
                              -- `pion_cstr_0` via its section symbol (S + A
                                 only) or by name (also loaded via the GOT)
  check.py wasm <mod.wasm>    -- no `__pion_map_hash`, no unreferenced function
"""
import re
import struct
import sys


def fail(msg):
    print('FAIL: p128 check.py: ' + msg, file=sys.stderr)
    sys.exit(1)


def cstr(tab, off):
    end = tab.find(b'\0', off)
    if end < 0:
        fail('unterminated string at %d' % off)
    return tab[off:end]


# ---------------------------------------------------------------- ELF64 ----

SHT_RELA, SHT_NOBITS, SHT_SYMTAB = 4, 8, 2
SHF_ALLOC = 2
STT_OBJECT, STT_SECTION = 1, 3
LITERAL = re.compile(rb'pion_str_[0-9]+_hdr|pion_cstr_[0-9]+')


def elf(data, what):
    if len(data) < 64 or data[:4] != b'\x7fELF' or data[4] != 2 or data[5] != 1:
        fail('%s is not a little-endian ELF64 file' % what)
    shoff = struct.unpack_from('<Q', data, 0x28)[0]
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', data, 0x3A)
    if shentsize != 64 or shnum == 0:
        fail('%s: bad section header table' % what)
    secs = []
    for i in range(shnum):
        (name, typ, flags, addr, off, size, link, info, align,
         entsize) = struct.unpack_from('<IIQQQQIIQQ', data, shoff + i * 64)
        secs.append(dict(name_off=name, type=typ, flags=flags, off=off, size=size,
                         link=link, info=info, entsize=entsize))
    sh = secs[shstrndx]
    shstr = data[sh['off']:sh['off'] + sh['size']]
    for s in secs:
        s['name'] = cstr(shstr, s['name_off'])
        s['data'] = b'' if s['type'] == SHT_NOBITS else data[s['off']:s['off'] + s['size']]
    return secs, shstr


def check_elf(path):
    data = open(path, 'rb').read()
    secs, shstr = elf(data, path)
    rela = [s for s in secs if s['type'] == SHT_RELA]
    if not rela:
        fail('%s has no relocation sections' % path)
    for r in rela:
        target = secs[r['info']]
        if r['name'] != b'.rela' + target['name']:
            fail('%s: %r relocates %r' % (path, r['name'], target['name']))
        # The target's name is the tail of `.rela<name>` in `.shstrtab`.
        if target['name_off'] != r['name_off'] + 5:
            fail('%s: %r at %d is not the suffix of %r at %d' % (
                path, target['name'], target['name_off'], r['name'], r['name_off']))
    if shstr.count(b'.rela') != len(rela):
        fail('%s: .shstrtab holds %d `.rela` names for %d RELA sections'
             % (path, shstr.count(b'.rela'), len(rela)))
    names = [s['name'] for s in secs[1:]]
    if len(set(names)) != len(names):
        fail('%s: duplicate section names %r' % (path, names))
    # Every name is stored once: nothing in `.shstrtab` but the (shared) names.
    if len(shstr) != 1 + sum(len(n) + 1 for n in names if not any(
            r['name'] == b'.rela' + n for r in rela)):
        fail('%s: .shstrtab is %d bytes, names need fewer' % (path, len(shstr)))

    symtab = [s for s in secs if s['type'] == SHT_SYMTAB]
    if len(symtab) != 1:
        fail('%s: %d symbol tables' % (path, len(symtab)))
    st = symtab[0]
    strtab = secs[st['link']]['data']
    syms = []
    for i in range(st['size'] // 24):
        name, info, other, shndx, value, size = struct.unpack_from('<IBBHQQ', st['data'], i * 24)
        syms.append((cstr(strtab, name), info >> 4, info & 15, shndx, value, size))
    named = [s for s in syms if LITERAL.fullmatch(s[0])]
    if named:
        fail('%s: private literals still have named symbols: %r' % (path, named[:4]))
    if LITERAL.search(strtab):
        fail('%s: .strtab still spells a private literal name' % path)
    lit_secs = {}
    for i, s in enumerate(secs):
        m = re.fullmatch(rb'\.(?:ro)?data\.(pion_str_[0-9]+_hdr|pion_cstr_[0-9]+)', s['name'])
        if m:
            lit_secs[i] = m.group(1)
    kinds = {k[:9] for k in lit_secs.values()}
    if kinds != {b'pion_str_', b'pion_cstr'}:
        fail('%s: want both literal kinds, found sections %r' % (path, sorted(lit_secs.values())))
    sec_syms = {s[3]: idx for idx, s in enumerate(syms) if s[2] == STT_SECTION}
    used = set()
    for r in rela:
        for i in range(r['size'] // 24):
            _, info, _ = struct.unpack_from('<QQq', r['data'], i * 24)
            used.add(info >> 32)
    for i in lit_secs:
        idx = sec_syms.get(i)
        if idx is None or syms[idx][1] != 0 or syms[idx][4] != 0:
            fail('%s: literal section %r has no local section symbol' % (path, secs[i]['name']))
        if idx not in used:
            fail('%s: literal section %r is never relocated against' % (path, secs[i]['name']))
    print('p128 elf %s: %d RELA names shared, %d literal sections via STT_SECTION, '
          '0 named literal symbols' % (path.rsplit('/', 1)[-1], len(rela), len(lit_secs)))


def relocs(path):
    """Allocated sections and their relocations with symbolic targets:
    (section, offset) for local definitions, the name for anything else."""
    secs, _ = elf(open(path, 'rb').read(), path)
    st = [s for s in secs if s['type'] == SHT_SYMTAB][0]
    strtab = secs[st['link']]['data']
    syms = []
    for i in range(st['size'] // 24):
        name, info, other, shndx, value, size = struct.unpack_from('<IBBHQQ', st['data'], i * 24)
        bind, typ = info >> 4, info & 15
        if typ == STT_SECTION:
            syms.append((secs[shndx]['name'], 0))
        elif bind == 0 and 0 < shndx < len(secs):
            syms.append((secs[shndx]['name'], value))
        else:
            syms.append((cstr(strtab, name), 0))
    out = {}
    for s in secs:
        if s['flags'] & SHF_ALLOC and s['name'] != b'.note.GNU-stack':
            out[s['name']] = [s['type'], s['flags'], s['size'], s['data'], []]
    for r in secs:
        if r['type'] != SHT_RELA:
            continue
        target = secs[r['info']]['name']
        for i in range(r['size'] // 24):
            off, info, addend = struct.unpack_from('<QQq', r['data'], i * 24)
            sec, value = syms[info >> 32]
            out[target][4].append((off, info & 0xFFFFFFFF, sec, value + addend))
    return out


def check_objcmp(a, b):
    ra, rb = relocs(a), relocs(b)
    lit = re.compile(rb'\.(?:ro)?data\.(pion_str_[0-9]+_hdr|pion_cstr_[0-9]+)')
    lits = [n for n in ra if lit.fullmatch(n)]
    if len(lits) < 2:
        fail('%s has %d literal sections' % (a, len(lits)))
    names_a = sorted(n for n, v in ra.items() if v[2] or v[4])
    names_b = sorted(n for n, v in rb.items() if v[2] or v[4])
    if names_a != names_b:
        fail('allocated sections differ: %r vs %r' % (names_a, names_b))
    nrefs = 0
    for n in names_a:
        va, vb = ra[n], rb[n]
        if not n.startswith(b'.text'):
            if va[:4] != vb[:4] or sorted(va[4]) != sorted(vb[4]):
                fail('section %r differs between %s and %s' % (n, a, b))
            continue
        # The two encoders place instructions differently inside a function,
        # so offsets are not compared; the function's literal references, in
        # order, must agree in relocation type and resolved target.
        seq_a = [(t, sec, val) for _, t, sec, val in sorted(va[4]) if lit.fullmatch(sec)]
        seq_b = [(t, sec, val) for _, t, sec, val in sorted(vb[4]) if lit.fullmatch(sec)]
        if seq_a != seq_b:
            fail('%r: literal references differ: %r vs %r' % (n, seq_a[:6], seq_b[:6]))
        nrefs += len(seq_a)
    if nrefs == 0:
        fail('%s: .text never refers to a literal' % a)
    print('p128 objcmp: %d sections, %d literal sections identical with their relocations; '
          '%d .text literal references agree per function, in order and type' % (
              len(names_a), len(lits), nrefs))


R_X86_64_GOTPCREL = 9


def check_litsym(path, want):
    """How `pion_cstr_0` is referenced: `section` (local STT_SECTION symbol,
    no name) or `named` (a local STT_OBJECT `pion_cstr_0` at offset 0, used by
    a GOTPCREL relocation)."""
    data = open(path, 'rb').read()
    secs, _ = elf(data, path)
    st = [s for s in secs if s['type'] == SHT_SYMTAB][0]
    strtab = secs[st['link']]['data']
    syms = []
    for i in range(st['size'] // 24):
        name, info, other, shndx, value, size = struct.unpack_from('<IBBHQQ', st['data'], i * 24)
        syms.append((cstr(strtab, name), info >> 4, info & 15, shndx, value))
    lit = [i for i, s in enumerate(secs) if s['name'] in (b'.rodata.pion_cstr_0', b'.data.pion_cstr_0')]
    if len(lit) != 1:
        fail('%s: no .rodata.pion_cstr_0 or .data.pion_cstr_0 section' % path)
    named = [i for i, s in enumerate(syms) if s[0] == b'pion_cstr_0']
    sect = [i for i, s in enumerate(syms) if s[2] == STT_SECTION and s[3] == lit[0]]
    used = {}
    for r in secs:
        if r['type'] == SHT_RELA:
            for j in range(r['size'] // 24):
                _, info, _ = struct.unpack_from('<QQq', r['data'], j * 24)
                used.setdefault(info >> 32, set()).add(info & 0xFFFFFFFF)
    if want == 'section':
        if named or not sect or sect[0] not in used:
            fail('%s: pion_cstr_0 is not referenced through its section symbol' % path)
        if R_X86_64_GOTPCREL in used[sect[0]]:
            fail('%s: GOTPCREL against a section symbol' % path)
    else:
        if len(named) != 1:
            fail('%s: pion_cstr_0 lost its name' % path)
        s = syms[named[0]]
        if s[1] != 0 or s[2] != STT_OBJECT or s[3] != lit[0] or s[4] != 0:
            fail('%s: pion_cstr_0 is not a local object at offset 0: %r' % (path, s))
        if R_X86_64_GOTPCREL not in used.get(named[0], set()):
            fail('%s: no GOTPCREL against pion_cstr_0' % path)
        for i in sect:
            if R_X86_64_GOTPCREL in used.get(i, set()):
                fail('%s: GOTPCREL against the section symbol' % path)
    print('p128 litsym %s: pion_cstr_0 referenced via its %s symbol' % (
        path.rsplit('/', 1)[-1], 'section' if want == 'section' else 'named'))


# ---------------------------------------------------------------- Wasm32 ---

class Reader:
    def __init__(self, data, pos=0, end=None):
        self.d, self.p, self.end = data, pos, len(data) if end is None else end

    def byte(self):
        if self.p >= self.end:
            fail('wasm: truncated')
        b = self.d[self.p]
        self.p += 1
        return b

    def uleb(self):
        r = shift = 0
        while True:
            b = self.byte()
            r |= (b & 0x7F) << shift
            shift += 7
            if b < 0x80:
                return r

    def sleb(self):
        r = shift = 0
        while True:
            b = self.byte()
            r |= (b & 0x7F) << shift
            shift += 7
            if b < 0x80:
                if b & 0x40:
                    r -= 1 << shift
                return r

    def take(self, n):
        if self.p + n > self.end:
            fail('wasm: truncated')
        v = self.d[self.p:self.p + n]
        self.p += n
        return v

    def name(self):
        return self.take(self.uleb()).decode()


def blocktype(r):
    b = r.d[r.p]
    if b == 0x40 or b in (0x7F, 0x7E, 0x7D, 0x7C, 0x7B, 0x70, 0x6F):
        r.p += 1
    else:
        r.sleb()


def memarg(r):
    r.uleb()
    r.uleb()


def const_expr(r, refs):
    while True:
        op = r.byte()
        if op == 0x0B:
            return
        if op in (0x41, 0x42):
            r.sleb()
        elif op == 0x44:
            r.take(8)
        elif op == 0x43:
            r.take(4)
        elif op == 0x23:
            r.uleb()
        elif op == 0xD2:
            refs.add(r.uleb())
        elif op == 0xD0:
            r.byte()
        else:
            fail('wasm: opcode 0x%02x in a constant expression' % op)


NO_IMM = set(range(0x45, 0xC5)) | {0x00, 0x01, 0x0F, 0x1A, 0x1B, 0x0B, 0x05, 0xD1}


def code_calls(r, end):
    """Direct callees and `ref.func` targets of one function body."""
    out = set()
    for _ in range(r.uleb()):
        r.uleb()
        r.byte()
    while r.p < end:
        op = r.byte()
        if op in NO_IMM:
            continue
        if op in (0x02, 0x03, 0x04):
            blocktype(r)
        elif op in (0x0C, 0x0D, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26):
            r.uleb()
        elif op == 0x0E:
            for _ in range(r.uleb() + 1):
                r.uleb()
        elif op in (0x10, 0x12):
            out.add(r.uleb())
        elif op in (0x11, 0x13):
            r.uleb()
            r.uleb()
        elif op == 0x1C:
            for _ in range(r.uleb()):
                r.byte()
        elif 0x28 <= op <= 0x3E:
            memarg(r)
        elif op in (0x3F, 0x40):
            r.byte()
        elif op == 0x41 or op == 0x42:
            r.sleb()
        elif op == 0x43:
            r.take(4)
        elif op == 0x44:
            r.take(8)
        elif op == 0xD0:
            r.byte()
        elif op == 0xD2:
            out.add(r.uleb())
        elif op == 0xFC:
            sub = r.uleb()
            if sub <= 7:
                pass
            elif sub in (8, 10, 12, 14):
                r.uleb()
                r.uleb()
            elif sub in (9, 11, 13, 15, 16, 17):
                r.uleb()
            else:
                fail('wasm: unknown 0xFC %d' % sub)
        elif op == 0xFD:
            sub = r.uleb()
            if sub <= 11 or sub in (92, 93):
                memarg(r)
            elif sub == 12 or sub == 13:
                r.take(16)
            elif 21 <= sub <= 34:
                r.byte()
            elif 84 <= sub <= 91:
                memarg(r)
                r.byte()
            else:
                pass
        elif op == 0xFE:
            sub = r.uleb()
            if sub == 3:
                r.byte()
            else:
                memarg(r)
        else:
            fail('wasm: unknown opcode 0x%02x at %d' % (op, r.p - 1))
    if r.d[end - 1] != 0x0B:
        fail('wasm: body does not end with `end`')
    return out


def check_wasm(path):
    data = open(path, 'rb').read()
    if data[:8] != b'\0asm\x01\0\0\0':
        fail('%s is not a Wasm module' % path)
    r = Reader(data, 8)
    n_imp = 0
    n_def = 0
    roots = set()
    bodies = []
    names = {}
    while r.p < len(data):
        sid = r.byte()
        size = r.uleb()
        end = r.p + size
        s = Reader(data, r.p, end)
        if sid == 2:
            for _ in range(s.uleb()):
                s.name()
                s.name()
                kind = s.byte()
                if kind == 0:
                    s.uleb()
                    n_imp += 1
                elif kind == 1:
                    s.byte()
                    lim = s.byte()
                    s.uleb()
                    if lim & 1:
                        s.uleb()
                elif kind == 2:
                    lim = s.byte()
                    s.uleb()
                    if lim & 1:
                        s.uleb()
                elif kind == 3:
                    s.byte()
                    s.byte()
                else:
                    fail('wasm: import kind %d' % kind)
        elif sid == 3:
            n_def = s.uleb()
        elif sid == 7:
            for _ in range(s.uleb()):
                s.name()
                kind = s.byte()
                idx = s.uleb()
                if kind == 0:
                    roots.add(idx)
        elif sid == 8:
            roots.add(s.uleb())
        elif sid == 9:
            for _ in range(s.uleb()):
                flags = s.uleb()
                if flags in (2, 6):
                    s.uleb()
                if flags in (0, 2, 4, 6):
                    const_expr(s, set())
                if flags in (1, 2, 3, 5, 6, 7):
                    s.byte()
                if flags < 4:
                    for _ in range(s.uleb()):
                        roots.add(s.uleb())
                elif flags < 8:
                    for _ in range(s.uleb()):
                        const_expr(s, roots)
                else:
                    fail('wasm: element segment flags %d' % flags)
        elif sid == 10:
            count = s.uleb()
            if count != n_def:
                fail('wasm: %d bodies for %d functions' % (count, n_def))
            for _ in range(count):
                bsize = s.uleb()
                bend = s.p + bsize
                bodies.append(code_calls(Reader(data, s.p, bend), bend))
                s.p = bend
        elif sid == 0:
            if s.name() == 'name':
                while s.p < end:
                    sub = s.byte()
                    ssize = s.uleb()
                    send = s.p + ssize
                    if sub == 1:
                        for _ in range(s.uleb()):
                            idx = s.uleb()
                            names[idx] = s.name()
                    s.p = send
        r.p = end
    if not bodies:
        fail('%s defines no functions' % path)
    if not names:
        fail('%s has no function name section (build with --wasm-names)' % path)
    fn_names = set(names.values())
    if '__pion_map_hash' in fn_names:
        fail('%s still emits __pion_map_hash' % path)
    if '__pion_wymix' not in fn_names:
        fail('%s does not use the Map hash path (no __pion_wymix): %r' % (path, sorted(fn_names)))
    seen = set()
    work = list(roots)
    while work:
        f = work.pop()
        if f in seen:
            continue
        seen.add(f)
        if f >= n_imp:
            work.extend(bodies[f - n_imp])
    dead = [names.get(i, '#%d' % i) for i in range(n_imp, n_imp + n_def) if i not in seen]
    if dead:
        fail('%s has unreferenced function bodies: %r' % (path, dead))
    print('p128 wasm %s: %d imports, %d bodies all reachable, no __pion_map_hash' % (
        path.rsplit('/', 1)[-1], n_imp, n_def))


if __name__ == '__main__':
    cmd = sys.argv[1] if len(sys.argv) > 1 else ''
    if cmd == 'elf' and len(sys.argv) == 3:
        check_elf(sys.argv[2])
    elif cmd == 'objcmp' and len(sys.argv) == 4:
        check_objcmp(sys.argv[2], sys.argv[3])
    elif cmd == 'litsym' and len(sys.argv) == 4 and sys.argv[3] in ('section', 'named'):
        check_litsym(sys.argv[2], sys.argv[3])
    elif cmd == 'wasm' and len(sys.argv) == 3:
        check_wasm(sys.argv[2])
    else:
        fail('usage: check.py elf <o> | objcmp <a.o> <b.o> | litsym <o> section|named | wasm <wasm>')
