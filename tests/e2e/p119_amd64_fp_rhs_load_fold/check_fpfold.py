#!/usr/bin/env python3
"""P119 structure and encoder-consistency checker for fold.ssa.

  check_fpfold.py asm LABEL FILE.s     QBE AT&T text (amd64_sysv or amd64_win)
  check_fpfold.py dis LABEL FILE.dis   `objdump -d --no-show-raw-insn` (GNU or
                                       LLVM) of an amd64 ELF object
  check_fpfold.py elfeq A.o B.o        the executable sections of two x86-64
                                       ELF objects are byte-identical, with
                                       equal relocations (targets resolved to
                                       section + offset or a global symbol) and
                                       equal bytes in every section they reach
  check_fpfold.py pion LABEL FILE.s SPEC...
                                       SPEC = FUNCTION:MNEMONIC[,...]:MIN (FUNCTION
                                       `*` = the whole file): at least MIN of each
                                       mnemonic with a non-stack, non-%rip memory
                                       source (a folded load) in that function of a
                                       QBE text

Both listings are parsed one instruction per line (QBE prints one per line;
objdump decodes the real instruction boundaries), operands are split at
top-level commas, and every function of fold.ssa must be present exactly once.

Expectations per function (the name encodes them):
  p_<op><k>_<shape>  exactly one <op>s<k> (subss/subsd/divss/divsd) and it has
                     a memory source that is not %rip-relative, of the
                     addressing shape <shape>; no movss/movsd reads that same
                     memory operand (no leftover load of the folded value).
                     ptr: (%base); off: 24(%base); idx: 8(%base,%index,W);
                     slot: 16(%rsp|%rbp,%index,W).
  p_<op><k>_hp       additionally: the destination register is written last
                     (through register copies) by a movss/movsd from a stack
                     slot, i.e. the left operand comes back from its spill slot.
  n_*                no scalar FP arithmetic (add/sub/mul/div) has a non-%rip
                     memory operand.
Everywhere: no instruction has two memory operands.
"""
import re
import struct
import sys

OPS = ('sub', 'div')
KS = ('s', 'd')
SHAPES = ('ptr', 'off', 'idx', 'slot', 'hp')
POSITIVE = [f'p_{op}{k}_{sh}' for op in OPS for k in KS for sh in SHAPES]
NEGATIVE = ['n_side0_subd', 'n_side0_divs', 'n_self_subd', 'n_multi_divs',
            'n_store_subd', 'n_store_divs', 'n_call_divd', 'n_call_subs',
            'n_width_sd', 'n_width_ds', 'n_const_subd', 'n_const_divs']
FUNCS = POSITIVE + NEGATIVE
FPARITH = re.compile(r'^(add|sub|mul|div)s[sd]$')
FPMOVE = re.compile(r'^(movs[sd]|movap[sd]|movup[sd])$')
STACK = re.compile(r'\(%(rsp|rbp)[,)]')


class Fail(Exception):
    pass


def split_ops(s):
    out, depth, cur = [], 0, ''
    for ch in s:
        if ch == '(':
            depth += 1
        elif ch == ')':
            depth -= 1
        if ch == ',' and depth == 0:
            out.append(cur)
            cur = ''
        else:
            cur += ch
    if cur:
        out.append(cur)
    return out


def norm(mnem, rest):
    rest = rest.split('#')[0]
    rest = re.sub(r'<[^>]*>', '', rest)
    rest = re.sub(r'\s+', '', rest).replace('"', '')
    return mnem.lower(), split_ops(rest) if rest else []


def parse_asm(text):
    """QBE AT&T text: `name:` ... `/* end function name */`."""
    funcs, cur = {}, None
    for ln in text.split('\n'):
        m = re.match(r'^([A-Za-z_][\w.$]*):\s*$', ln)
        if m and m.group(1).lstrip('_') in FUNCS:
            name = m.group(1).lstrip('_')
            if name in funcs:
                raise Fail(f'{name} defined twice')
            cur = name
            funcs[cur] = []
            continue
        if re.match(r'^/\* end function', ln):
            cur = None
            continue
        if cur is None or not ln.startswith('\t'):
            continue
        body = ln.strip()
        if not body or body.startswith('.') or body.endswith(':'):
            continue
        parts = body.split(None, 1)
        funcs[cur].append(norm(parts[0], parts[1] if len(parts) > 1 else ''))
    return funcs


def parse_dis(text):
    """GNU or LLVM objdump -d --no-show-raw-insn."""
    funcs, cur = {}, None
    for ln in text.split('\n'):
        m = re.match(r'^[0-9a-f]+ <([^>]+)>:', ln)
        if m:
            name = m.group(1).lstrip('_')
            cur = name if name in FUNCS else None
            if cur is not None:
                if cur in funcs:
                    raise Fail(f'{cur} disassembled twice')
                funcs[cur] = []
            continue
        m = re.match(r'^\s*[0-9a-f]+:\s+(.*?)\s*$', ln)
        if not m or cur is None:
            continue
        body = m.group(1)
        if not body or body.startswith('R_X86_64'):
            continue
        parts = body.split(None, 1)
        mnem = parts[0]
        rest = parts[1] if len(parts) > 1 else ''
        # Prefixes objdump prints in front of a mnemonic.
        while mnem in ('rep', 'repz', 'repnz', 'notrack', 'bnd', 'data16', 'cs', 'ds') and rest:
            parts = rest.split(None, 1)
            mnem, rest = parts[0], parts[1] if len(parts) > 1 else ''
        funcs[cur].append(norm(mnem, rest))
    return funcs


def is_mem(o):
    return '(' in o


def is_rip(o):
    return '(%rip)' in o


def addr_shape(o):
    """disp, base, index, scale of an AT&T memory operand."""
    m = re.fullmatch(r'(-?(?:0x[0-9a-f]+|\d+))?\((%\w+)?(?:,(%\w+)(?:,(\d))?)?\)', o)
    if not m:
        raise Fail(f'unparsed memory operand {o}')
    disp = int(m.group(1), 0) if m.group(1) else 0
    return disp, m.group(2), m.group(3), int(m.group(4) or 1)


def last_writer(ins, idx, reg):
    """The instruction that last wrote `reg` before ins[idx], following
    register-to-register FP moves to their source."""
    seen = 0
    j = idx - 1
    while j >= 0 and seen < 64:
        mn, ops = ins[j]
        if ops and ops[-1] == reg:
            if FPMOVE.match(mn) and len(ops) == 2 and not is_mem(ops[0]):
                reg = ops[0]
                seen += 1
                j -= 1
                continue
            return ins[j]
        j -= 1
    return None


def check_funcs(label, funcs):
    missing = [f for f in FUNCS if f not in funcs]
    if missing:
        raise Fail(f'{label}: functions missing: {missing}')
    errors = []
    for fn in FUNCS:
        ins = funcs[fn]
        for mn, ops in ins:
            if sum(1 for o in ops if is_mem(o)) > 1 and not mn.startswith('lea'):
                errors.append(f'{fn}: two memory operands in {mn} {",".join(ops)}')
        if fn.startswith('n_'):
            for mn, ops in ins:
                if FPARITH.match(mn) and any(is_mem(o) and not is_rip(o) for o in ops):
                    errors.append(f'{fn}: folded although it must not: {mn} {",".join(ops)}')
            continue
        _, opk, shape = fn.split('_')
        want = opk[:-1] + 's' + opk[-1]
        hits = [(i, mn, ops) for i, (mn, ops) in enumerate(ins) if mn == want]
        if len(hits) != 1:
            errors.append(f'{fn}: {len(hits)} {want} instructions, want 1')
            continue
        i, mn, ops = hits[0]
        if len(ops) != 2 or not is_mem(ops[0]) or is_rip(ops[0]) or not ops[1].startswith('%xmm'):
            errors.append(f'{fn}: not folded: {mn} {",".join(ops)}')
            continue
        src, dst = ops
        for mn2, ops2 in ins[:i]:
            if mn2 in ('movss', 'movsd') and ops2 and ops2[0] == src:
                errors.append(f'{fn}: {src} is still loaded by {mn2} {",".join(ops2)} before {want}')
        disp, base, index, scale = addr_shape(src)
        w = 4 if opk.endswith('s') else 8
        ok = {
            'ptr': disp == 0 and base and not index,
            'off': disp == 24 and base and not index,
            'idx': disp == 8 and base and index and scale == w,
            'slot': disp == 16 and base in ('%rsp', '%rbp') and index and scale == w,
            'hp': disp == 0 and base and not index and base not in ('%rsp', '%rbp'),
        }[shape]
        if not ok:
            errors.append(f'{fn}: memory source {src} is not the {shape} addressing shape')
        if shape == 'hp':
            wr = last_writer(ins, i, dst)
            if not wr or wr[0] not in ('movss', 'movsd') or not wr[1] or not STACK.search(wr[1][0]):
                errors.append(f'{fn}: {dst} of {want} does not come from a stack slot (last writer {wr})')
    if errors:
        raise Fail(f'{label}:\n  ' + '\n  '.join(errors))
    npos = len(POSITIVE)
    print(f'p119 {label}: {npos} functions folded (4 shapes + high XMM pressure x '
          f'subss/subsd/divss/divsd), {len(NEGATIVE)} negative controls not folded, '
          f'no instruction with two memory operands')


# ---- ELF64 x86-64 relocatable objects ----

def elf(path):
    data = open(path, 'rb').read()
    if data[:4] != b'\x7fELF' or data[4] != 2 or data[5] != 1:
        raise Fail(f'{path}: not a little-endian ELF64 object')
    shoff, = struct.unpack_from('<Q', data, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from('<HHH', data, 0x3a)
    secs = []
    for k in range(shnum):
        name, typ, flags, _, off, size, link, info, _, entsize = struct.unpack_from(
            '<IIQQQQIIQQ', data, shoff + k * shentsize)
        secs.append(dict(name=name, type=typ, flags=flags, off=off, size=size,
                         link=link, info=info, entsize=entsize))
    strtab = secs[shstrndx]

    def cstr(off):
        return data[off:data.index(b'\0', off)].decode()
    for s in secs:
        s['name'] = cstr(strtab['off'] + s['name'])
        s['data'] = data[s['off']:s['off'] + s['size']] if s['type'] != 8 else b'\0' * s['size']
    syms = []
    for s in secs:
        if s['type'] == 2:  # SHT_SYMTAB
            st = secs[s['link']]
            for k in range(s['size'] // 24):
                nm, info, _, shndx, value, _ = struct.unpack_from('<IBBHQQ', data, s['off'] + 24 * k)
                syms.append(dict(name=cstr(st['off'] + nm), bind=info >> 4, type=info & 15,
                                 shndx=shndx, value=value))
    return secs, syms


def relocs(secs, syms, target):
    """Relocations against section index `target`, as comparable tuples."""
    out = []
    for s in secs:
        if s['type'] == 4 and s['info'] == target:  # SHT_RELA
            for k in range(s['size'] // 24):
                off, info, add = struct.unpack_from('<QQq', s['data'], 24 * k)
                sym = syms[info >> 32]
                if sym['bind'] == 0 and 0 < sym['shndx'] < len(secs):
                    tgt = ('section', secs[sym['shndx']]['name'], sym['value'] + add)
                else:
                    tgt = ('symbol', sym['name'], add)
                out.append((off, info & 0xffffffff, tgt))
    return sorted(out)


def elfeq(a, b):
    sa, ya = elf(a)
    sb, yb = elf(b)
    xa = {s['name']: (k, s) for k, s in enumerate(sa) if s['flags'] & 4}
    xb = {s['name']: (k, s) for k, s in enumerate(sb) if s['flags'] & 4}
    errors = []
    if sorted(xa) != sorted(xb):
        errors.append(f'executable sections differ: {sorted(set(xa) ^ set(xb))}')
    reached = set()
    nrel = nbytes = 0
    for name in sorted(set(xa) & set(xb)):
        ka, s1 = xa[name]
        kb, s2 = xb[name]
        if s1['data'] != s2['data']:
            pos = next((i for i in range(min(len(s1['data']), len(s2['data'])))
                        if s1['data'][i] != s2['data'][i]), min(len(s1['data']), len(s2['data'])))
            errors.append(f'{name}: bytes differ at offset {pos:#x} '
                          f'({len(s1["data"])} vs {len(s2["data"])} bytes)')
        ra, rb = relocs(sa, ya, ka), relocs(sb, yb, kb)
        if ra != rb:
            errors.append(f'{name}: relocations differ\n    {ra}\n    {rb}')
        nrel += len(ra)
        nbytes += len(s1['data'])
        for _, _, t in ra:
            if t[0] == 'section':
                reached.add(t[1])
    for name in sorted(reached):
        da = [s['data'] for s in sa if s['name'] == name]
        db = [s['data'] for s in sb if s['name'] == name]
        if da != db:
            errors.append(f'{name}: referenced data differs')
    if errors:
        raise Fail(f'--obj != text ({a} vs {b}):\n  ' + '\n  '.join(errors))
    print(f'p119 --obj == text: {len(xa)} executable sections ({nbytes} bytes, {nrel} relocations, '
          f'{len(reached)} referenced data sections) identical')


def pion(label, path, specs):
    funcs, cur = {}, None
    for ln in open(path).read().split('\n'):
        m = re.match(r'^([A-Za-z_][\w.$]*):\s*$', ln)
        if m:
            cur = m.group(1).lstrip('_')
            funcs.setdefault(cur, [])
            continue
        if cur is None or not ln.startswith('\t'):
            continue
        body = ln.strip()
        if not body or body.startswith('.'):
            continue
        parts = body.split(None, 1)
        funcs[cur].append(norm(parts[0], parts[1] if len(parts) > 1 else ''))
    errors, report = [], []
    for spec in specs:
        fn, mnems, least = spec.split(':')
        if fn != '*' and fn not in funcs:
            errors.append(f'{fn}: not in the assembly')
            continue
        body = [i for f in funcs.values() for i in f] if fn == '*' else funcs[fn]
        for mn in mnems.split(','):
            n = sum(1 for m, ops in body if m == mn and ops and is_mem(ops[0])
                    and not is_rip(ops[0]) and not STACK.search(ops[0]))
            report.append(f'{fn} {mn} x{n}')
            if n < int(least):
                errors.append(f'{fn}: {n} folded {mn}, want at least {least}')
    if errors:
        raise Fail(f'{label}:\n  ' + '\n  '.join(errors))
    print(f'p119 {label}: folded right-operand loads: ' + ', '.join(report))


def main(argv):
    try:
        if len(argv) == 4 and argv[1] in ('asm', 'dis'):
            text = open(argv[3]).read()
            check_funcs(argv[2], parse_asm(text) if argv[1] == 'asm' else parse_dis(text))
        elif len(argv) == 4 and argv[1] == 'elfeq':
            elfeq(argv[2], argv[3])
        elif len(argv) >= 5 and argv[1] == 'pion':
            pion(argv[2], argv[3], argv[4:])
        else:
            raise Fail(__doc__)
    except Fail as e:
        print(f'FAIL: p119 {e}', file=sys.stderr)
        return 1
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
