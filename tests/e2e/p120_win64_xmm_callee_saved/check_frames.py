"""Structural check of Win64 frames in `qbe -t amd64_win` text.

usage: python3 -E check_frames.py WIN.s EXPECT.txt [--seh] [--all-nosave] [--report OUT]

With --seh (text of `qbe --seh -t amd64_win`) every .seh_* directive below
is required; without it the same layout must carry none of them.

A framed function (one with pushes, a frame, saved xmm or %rbp) must be

    .seh_proc NAME
    endbr64
    [movq %rcx/%rdx/%r8/%r9, 0x8..0x20(%rsp)]              vararg homes
    [pushq %rbp; .seh_pushreg %rbp]
    {pushq %R; .seh_pushreg %R}                            GPRs
    [probe loop on %r10 / %r11 (frames >= 4096)]
    [subq $F, %rsp; .seh_stackalloc F; [orq $0, (%rsp)]]   orq iff F >= 4000
    [movq %rsp, %rbp; .seh_setframe %rbp, 0]               iff %rbp pushed
    {movups %xmmN, OFF(%rsp); .seh_savexmm %xmmN, OFF}
    .seh_endprologue
    ... body ...
    .seh_endproc                                           last line

with (8 + 8 * pushes + F) % 16 == 0 (%rsp 16-byte aligned after the
prologue), xmm save offsets 16-byte aligned, strictly increasing, pairwise
disjoint 16-byte cells inside [0, F); the saved set equal to the xmm6..xmm15
the body uses (nothing missing, nothing redundant); no body access to the
frame base overlapping a save cell (access widths from the mnemonic,
implicit zero and indexed displacements); before every `ret`: the same
register / offset restores from the frame base, then `leaq F(%rbp), %rsp`
(rbp frames; the only way out after a dynamic `subq %R, %rsp`) or
`addq $F, %rsp` (equal to the prologue's F), the pops mirroring the pushes,
`popq %rbp`. A frameless function has none of it and touches no xmm6..15.
EXPECT.txt tokens per function: save6-14, save15, nosave, rsp, rbp, chkstk,
div15 / swap15 / copy15 (the xmm15 scratch form). --report writes
`name base npush nclob F nxmm` per function. Exits 1 on the first violation.
"""
import re
import sys

HI = set(range(6, 16))
GPR = {'rbx', 'r12', 'r13', 'r14', 'r15', 'rsi', 'rdi'}
XRE = re.compile(r'%xmm(\d+)\b')
SAVE = re.compile(r'^movups %xmm(\d+), (\d+)\(%rsp\)$')
LOAD = re.compile(r'^movups (-?\d+)\(%(rsp|rbp)\), %xmm(\d+)$')
MEM = re.compile(r'(-?(?:0x[0-9a-f]+|\d+))?\(%(rsp|rbp)(?:,%\w+,\d)?\)')


def fail(fn, msg):
    print(f'FAIL: check_frames {fn}: {msg}')
    sys.exit(1)


def functions(path):
    cur, body = None, []
    for raw in open(path):
        line = raw.strip()
        m = re.match(r'^([A-Za-z_][\w.]*):$', line)
        if cur is None and m and not line.startswith('L'):
            cur, body = m.group(1), []
            continue
        if cur is not None:
            if line.startswith('/* end function'):
                yield cur, body
                cur = None
            elif line.startswith('/* end data'):
                cur = None
            elif line and not line.startswith('/*'):
                body.append(line)


def width(op):
    if op.endswith(('ups', 'aps', 'dqu', 'dqa')):
        return 16
    if op.endswith('sd') or op in ('ucomisd', 'comisd'):
        return 8
    if op.endswith('ss') or op in ('ucomiss', 'comiss'):
        return 4
    m = re.match(r'^mov[sz]([bwl])[wlq]$', op)
    if m:
        return {'b': 1, 'w': 2, 'l': 4}[m.group(1)]
    if op.startswith('cvt'):
        return 8 if op.endswith('q') or op.endswith('sd') else 4
    return {'b': 1, 'w': 2, 'l': 4, 'q': 8}.get(op[-1], 8)


def accesses(line, base):
    op = line.split()[0]
    w = width(op)
    for disp, b in MEM.findall(line):
        if b != base:
            continue
        d = int(disp, 0) if disp else 0
        yield d, d + w


SEH = False


def check(fn, ins, need):
    def at(k):
        return ins[k] if k < len(ins) else ''

    def seh(k, text, msg):
        # the directive at k with --seh (k + 1), none without (k)
        if not SEH:
            return k
        if at(k) != text:
            fail(fn, msg)
        return k + 1

    if not SEH:
        for line in ins:
            if line.startswith('.seh_'):
                fail(fn, f'{line!r} without --seh')
    k = 0
    framed = at(0) == f'.seh_proc {fn}'
    if framed:
        k += 1
    if at(k) != 'endbr64':
        fail(fn, 'no endbr64')
    k += 1
    vararg = False
    while re.match(r'^movq %(rcx|rdx|r8|r9), 0x[0-9a-f]+\(%rsp\)$', at(k)):
        vararg = True
        k += 1
    base, pushes = 'rsp', []
    if (framed or not SEH) and at(k) == 'pushq %rbp':
        base = 'rbp'
        k = seh(k + 1, '.seh_pushreg %rbp', 'pushq %rbp without .seh_pushreg')
    while re.match(r'^pushq %\w+$', at(k)):
        r = at(k).split('%')[1]
        if r not in GPR:
            fail(fn, f'push of {r}')
        pushes.append(r)
        k = seh(k + 1, f'.seh_pushreg %{r}', f'pushq %{r} without .seh_pushreg')
    fsz, chk = 0, False
    m = re.match(r'^leaq -(\d+)\(%rsp\), %r10$', at(k))
    if m:
        chk = True
        want = ['movq %rsp, %r11', None, 'subq $4096, %r11', 'cmpq %r10, %r11',
                None, 'orq $0, (%r11)', None, None]
        for j, w in enumerate(want):
            if w is not None and at(k + 1 + j) != w:
                fail(fn, f'bad stack probe: {at(k + 1 + j)!r}')
        probe = int(m.group(1))
        k += 9
        if not re.match(rf'^subq \${probe}, %rsp$', at(k)):
            fail(fn, f'probe of {probe} not followed by the allocation')
    m = re.match(r'^subq \$(\d+), %rsp$', at(k))
    if m:
        fsz = int(m.group(1))
        k = seh(k + 1, f'.seh_stackalloc {fsz}', 'subq without .seh_stackalloc')
        if at(k) == 'orq $0, (%rsp)':
            k += 1
        elif fsz >= 4000:
            fail(fn, f'frame {fsz} without its last-page probe')
    if fsz >= 4096 and not chk:
        fail(fn, f'frame {fsz} without stack probe')
    if base == 'rbp':
        if at(k) != 'movq %rsp, %rbp':
            fail(fn, 'rbp frame without movq %rsp, %rbp')
        k = seh(k + 1, '.seh_setframe %rbp, 0', 'movq %rsp, %rbp without .seh_setframe')
    saves = []
    while SAVE.match(at(k)):
        r, off = (int(x) for x in SAVE.match(at(k)).groups())
        saves.append((r, off))
        k = seh(k + 1, f'.seh_savexmm %xmm{r}, {off}',
                f'xmm{r} save without matching .seh_savexmm')
    if not SEH:
        framed = bool(base == 'rbp' or pushes or fsz or saves)
        body = ins[k:]
    elif framed:
        if at(k) != '.seh_endprologue':
            fail(fn, f'no .seh_endprologue (got {at(k)!r})')
        k += 1
        if ins[-1] != '.seh_endproc':
            fail(fn, 'no .seh_endproc at the end')
        body = ins[k:-1]
    else:
        body = ins[k:]
    for line in body:
        if line.startswith('.seh_'):
            fail(fn, f'stray {line!r}')
    npush = len(pushes) + (base == 'rbp')
    if not framed:
        if vararg:
            fail(fn, 'vararg without frame')
        if pushes or fsz or saves or base == 'rbp':
            fail(fn, 'frame without .seh_proc')
    elif (8 + 8 * npush + fsz) % 16:
        fail(fn, f'%rsp misaligned after prologue: {npush} pushes + {fsz}')
    regs = [r for r, _ in saves]
    if regs != sorted(set(regs)):
        fail(fn, f'save order / duplicates {regs}')
    offs = [o for _, o in saves]
    for a, b in zip(offs, offs[1:]):
        if b < a + 16:
            fail(fn, f'xmm save cells overlap or are unordered: {offs}')
    for r, o in saves:
        if r not in HI:
            fail(fn, f'saved volatile xmm{r}')
        if o % 16:
            fail(fn, f'xmm{r} save offset {o} not 16-byte aligned')
        if not (0 <= o and o + 16 <= fsz):
            fail(fn, f'xmm{r} save {o} outside [0, {fsz})')
    used = set()
    for line in body:
        if LOAD.match(line):
            continue
        used.update(int(x) for x in XRE.findall(line))
    used &= HI
    if set(regs) != used:
        fail(fn, f'saved {sorted(regs)} but body uses {sorted(used)}')
    cells = [(o, o + 16) for _, o in saves]
    dyn = False
    for line in body:
        if LOAD.match(line):
            continue
        if re.match(r'^subq %\w+, %rsp$', line):
            dyn = True
        if base == 'rsp' and re.match(r'^(sub|add)q .*, %rsp$', line) \
                and line != f'addq ${fsz}, %rsp':
            fail(fn, f'%rsp moved in an %rsp frame: {line!r}')
        for lo, hi in accesses(line, base):
            for clo, chi in cells:
                if lo < chi and clo < hi:
                    fail(fn, f'body access {line!r} overlaps the xmm save area')
    if dyn and base != 'rbp':
        fail(fn, 'dynamic allocation without %rbp')
    rets = [i for i, l in enumerate(body) if l == 'ret']
    if not rets:
        fail(fn, 'no ret')
    for i in rets:
        j = i - 1
        if base == 'rbp':
            if body[j] != 'popq %rbp':
                fail(fn, 'ret without popq %rbp')
            j -= 1
        pops = []
        while j >= 0 and re.match(r'^popq %\w+$', body[j]):
            pops.append(body[j].split('%')[1])
            j -= 1
        if pops != pushes:
            fail(fn, f'pops {pops} do not mirror pushes {pushes}')
        if base == 'rbp':
            if body[j] != f'leaq {fsz}(%rbp), %rsp':
                fail(fn, f'epilogue {body[j]!r} is not leaq {fsz}(%rbp), %rsp')
            j -= 1
        elif fsz:
            if body[j] != f'addq ${fsz}, %rsp':
                fail(fn, f'epilogue {body[j]!r} does not free {fsz} bytes')
            j -= 1
        loads = []
        while j >= 0 and LOAD.match(body[j]):
            off, b, r = LOAD.match(body[j]).groups()
            if b != base:
                fail(fn, f'restore relative to %{b} in a %{base} frame')
            loads.append((int(r), int(off)))
            j -= 1
        if sorted(loads) != sorted(saves):
            fail(fn, f'restore before ret #{rets.index(i)} {sorted(loads)} '
                     f'!= saves {sorted(saves)}')
    for line in body:
        if line.startswith('movups') and not LOAD.match(line):
            if set(int(x) for x in XRE.findall(line)) & HI:
                fail(fn, f'stray {line!r}')
    nload = sum(1 for l in body if LOAD.match(l))
    if nload != len(saves) * len(rets):
        fail(fn, f'{nload} restores for {len(saves)} saves x {len(rets)} rets')
    for w in need:
        if w == 'save6-14' and not set(range(6, 15)) <= set(regs):
            fail(fn, f'expected xmm6..xmm14 saved, got {regs}')
        elif w == 'save15' and 15 not in regs:
            fail(fn, 'expected xmm15 saved')
        elif w == 'nosave' and regs:
            fail(fn, f'expected no xmm save, got {regs}')
        elif w in ('rsp', 'rbp') and base != w:
            fail(fn, f'expected %{w} frame, got %{base}')
        elif w == 'chkstk' and not chk:
            fail(fn, 'expected stack probe')
        elif w == 'div15':
            ok = any(re.match(r'^movsd %xmm(\d+), %xmm15$', body[i])
                     and body[i + 2] == 'divsd %xmm15, ' + body[i].split(',')[0][6:]
                     for i in range(len(body) - 2))
            if not ok:
                fail(fn, 'no Odiv xmm15 form')
        elif w == 'swap15':
            ok = False
            for i in range(len(body) - 2):
                a = re.match(r'^movsd %xmm(\d+), %xmm15$', body[i])
                b = re.match(r'^movsd %xmm(\d+), %xmm(\d+)$', body[i + 1])
                c = re.match(r'^movsd %xmm15, %xmm(\d+)$', body[i + 2])
                if a and b and c and b.group(2) == a.group(1) and c.group(1) == b.group(1):
                    ok = True
            if not ok:
                fail(fn, 'no floating-point swap through xmm15')
        elif w == 'copy15':
            ok = any(re.match(r'^movsd -?\d+\(%r[bs]p\), %xmm15$', body[i])
                     and re.match(r'^movsd %xmm15, -?\d+\(%r[bs]p\)$', body[i + 1])
                     for i in range(len(body) - 1))
            if not ok:
                fail(fn, 'no slot-to-slot copy through xmm15')
    return f'{fn} {base if framed else "none"} {npush} {len(pushes)} {fsz} {len(saves)}'


def main():
    args = sys.argv[1:]
    report = None
    if '--report' in args:
        report = args[args.index('--report') + 1]
        del args[args.index('--report'):args.index('--report') + 2]
    path = args[0]
    allno = '--all-nosave' in args
    global SEH
    SEH = '--seh' in args
    args = [a for a in args if a != '--seh']
    need = {}
    if len(args) > 1 and args[1] != '--all-nosave':
        for line in open(args[1]):
            p = line.split()
            if p:
                need[p[0]] = p[1:]
    rows = []
    for fn, ins in functions(path):
        rows.append(check(fn, ins, ['nosave'] if allno else need.get(fn, [])))
        need.pop(fn, None)
    if need:
        fail(' '.join(need), 'missing from the assembly')
    if not rows:
        fail(path, 'no function')
    if report:
        open(report, 'w').write('\n'.join(rows) + '\n')
    print(f'check_frames: {len(rows)} functions OK')


main()
